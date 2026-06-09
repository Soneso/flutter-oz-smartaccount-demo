/// Business logic for the context-rules screen.
///
/// [ContextRuleFlow] is the single entry point for all context-rule
/// read, modification, and edit operations. The [ContextRulesScreen] and
/// [ContextRuleBuilderScreen] delegate every SDK interaction here; screens
/// must not call into the SDK directly.
///
/// Operations:
/// - [listContextRules]            — fetch all on-chain context rules.
/// - [removeContextRule]           — remove one rule (single- or multi-signer).
/// - [loadAvailableSigners]        — extract signers for the removal picker.
/// - [isSinglePasskeyRemoval]      — decide single vs multi-signer removal path.
/// - [registerDelegatedKeypairs]   — register delegated key material.
/// - [registerEd25519Keypairs]     — register Ed25519 secret material.
/// - [buildSelectedSigners]        — convert [SignerInfo] choices to SDK types.
/// - [classifyRemovalError]        — map raw exceptions to user-facing strings.
/// - [addContextRule]              — submit a new context rule.
/// - [loadAvailablePasskeySigners] — discover reusable passkey signers.
/// - [registerPasskeySigner]       — drive WebAuthn registration ceremony.
/// - [resolveAbsoluteLedger]       — convert a ledger offset to an absolute number.
/// - [loadParsedContextRule]       — load a single on-chain rule for editing.
/// - [readPolicyParams]            — read on-chain policy parameters.
/// - [resolveEditDiffExpiry]       — resolve edit-diff expiry offset to absolute.
/// - [submitContextRuleEdits]      — apply an [ContextRuleEditDiff] sequentially.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../config/demo_config.dart' as config;
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import '../util/keypair_registration.dart';
import '../util/policy_params_decoder.dart';
import '../util/policy_type.dart';
import '../util/selected_signer_builder.dart';
import 'context_rule_builder_types.dart'
    show ContextRuleResult, FlowPolicyEntry;
import 'context_rule_edit_types.dart';
import 'context_rule_edit_types.dart' as edit_types;
import 'context_rule_flow_adapters.dart';
import 'transfer_flow.dart'
    show Ed25519SignerIdentity, SignerInfo, SignerKind, TransferFlow;

export 'context_rule_edit_types.dart';
export 'context_rule_flow_adapters.dart';

part 'context_rule_edit_orchestrator.dart';

// ---------------------------------------------------------------------------
// ContextRuleFlow
// ---------------------------------------------------------------------------

/// Result of loading the signer list for the removal flow.
///
/// The flow distinguishes "no signers available" (legitimate, empty list)
/// from "failed to load signers" (network or parse error) so the screen can
/// surface an error card instead of silently falling back to the
/// single-signer path.
final class LoadAvailableSignersResult {
  /// Constructs a successful result with the loaded [signers] list.
  const LoadAvailableSignersResult.success(this.signers)
      : error = null,
        isSuccess = true;

  /// Constructs a failure result carrying the classified [error].
  const LoadAvailableSignersResult.failure(this.error)
      : signers = const <SignerInfo>[],
        isSuccess = false;

  /// True when the signers list was loaded successfully.
  final bool isSuccess;

  /// The signers list. Empty when [isSuccess] is false.
  final List<SignerInfo> signers;

  /// The classified error. Null when [isSuccess] is true.
  final DemoError? error;
}

/// Business logic for the context-rules screen.
///
/// Construct once per screen instance. The [ContextRulesScreen] holds one
/// [ContextRuleFlow] for its lifetime.
///
/// Thread safety:
/// [_isRemoving] guards against concurrent in-flight removal calls.
final class ContextRuleFlow {
  /// Constructs a flow with injected dependencies.
  ///
  /// [environment] is required for builder-screen flow methods that need to
  /// reach kit-level singletons (WebAuthn provider, verifier addresses,
  /// Soroban server). Tests that only exercise the read / removal paths may
  /// leave it null.
  ContextRuleFlow({
    required DemoStateNotifier demoState,
    required ActivityLogNotifier activityLog,
    required ContextRuleFlowManagerType contextRuleManager,
    ContextRuleBuilderEnvironmentType? environment,
    Random? secureRandom,
  })  : _demoState = demoState,
        _activityLog = activityLog,
        _contextRuleManager = contextRuleManager,
        _environment = environment,
        _secureRandom = secureRandom ?? Random.secure();

  final DemoStateNotifier _demoState;
  final ActivityLogNotifier _activityLog;
  final ContextRuleFlowManagerType _contextRuleManager;
  final ContextRuleBuilderEnvironmentType? _environment;
  final Random _secureRandom;

  // ---- Re-entrancy guard ----

  bool _isRemoving = false;
  bool _isSubmittingRule = false;
  bool _isSubmittingEdits = false;

  // -------------------------------------------------------------------------
  // Public: listContextRules
  // -------------------------------------------------------------------------

  /// Fetches all active on-chain context rules for the connected account.
  ///
  /// Logs progress and result. Returns an empty list when the wallet is not
  /// connected.
  ///
  /// Throws any SDK exception on network or on-chain failure.
  Future<List<OZParsedContextRule>> listContextRules() async {
    if (!_demoState.currentState.isConnected) {
      return const <OZParsedContextRule>[];
    }

    _activityLog.info('Loading context rules...');
    final rules = await _contextRuleManager.listContextRules();
    final sorted = List<OZParsedContextRule>.from(rules)
      ..sort((a, b) => a.id.compareTo(b.id));
    _activityLog.success('${sorted.length} context rule(s) loaded');
    return sorted;
  }

  // -------------------------------------------------------------------------
  // Public: removeContextRule
  // -------------------------------------------------------------------------

  /// Removes the context rule with [ruleId].
  ///
  /// [selectedSigners] is empty for the single-signer (passkey) path, or
  /// populated from the signer picker for the multi-signer path.
  ///
  /// [currentRuleCount] is the number of rules the caller currently
  /// observes; when it is `<= 1` the flow refuses to remove (defense in
  /// depth against a stale screen-level guard) and throws a
  /// [DemoError] tagged [DemoErrorCategory.validation].
  ///
  /// On success, returns the [OZTransactionResult] from the SDK so the screen
  /// can display the hash. On failure, throws a [DemoError] whose
  /// [DemoError.message] is sanitised for UI display; the raw underlying
  /// error is retained in [DemoError.cause] for diagnostics only.
  ///
  /// Throws [StateError] when a removal is already in progress.
  Future<OZTransactionResult> removeContextRule({
    required int ruleId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
    int? currentRuleCount,
  }) async {
    if (currentRuleCount != null && currentRuleCount <= 1) {
      throw const DemoError(
        message: 'Cannot remove the last context rule.',
        category: DemoErrorCategory.validation,
      );
    }
    if (_isRemoving) {
      throw StateError('A removal is already in progress.');
    }
    _isRemoving = true;
    try {
      _activityLog.info('Removing context rule (requires authorization)...');
      final result = await _contextRuleManager.removeContextRule(
        id: ruleId,
        selectedSigners: selectedSigners,
      );
      if (!result.success) {
        // Surface the SDK error verbatim. The simulation re-error and the
        // diagnostic event log it carries are the only signal the user has
        // for why the on-chain authorization rejected the removal.
        throw DemoError(
          message: result.error ?? 'Unknown error',
          category: DemoErrorCategory.onChain,
          cause: result.error,
        );
      }
      final hash = result.hash ?? '';
      _activityLog.success(
        'Context rule removed. Hash: ${truncateAddress(hash)}',
      );
      return result;
    } finally {
      _isRemoving = false;
    }
  }

  // -------------------------------------------------------------------------
  // Public: loadAvailableSigners
  // -------------------------------------------------------------------------

  /// Loads all available signers from the connected account's context rules.
  ///
  /// Returns a [LoadAvailableSignersResult] so callers can distinguish "no
  /// signers found" (a legitimate empty list) from "load failed" (network
  /// or parse error). On error, the failure result carries a sanitised
  /// [DemoError] suitable for display.
  Future<LoadAvailableSignersResult> loadAvailableSigners() async {
    final state = _demoState.currentState;
    if (!state.isConnected) {
      return const LoadAvailableSignersResult.success(<SignerInfo>[]);
    }
    try {
      final rules = await _contextRuleManager.listContextRules();
      final signers =
          _extractSigners(rules, connectedCredentialId: state.credentialId);
      return LoadAvailableSignersResult.success(signers);
    } catch (e) {
      final classified =
          classifyError(e, context: 'Failed to load available signers');
      _activityLog.error(classified.message);
      return LoadAvailableSignersResult.failure(classified);
    }
  }

  // -------------------------------------------------------------------------
  // Public: isSinglePasskeyRemoval
  // -------------------------------------------------------------------------

  /// Returns true when [selectedSigners] represents a single connected
  /// passkey, which routes the removal to the fast single-signer path
  /// (passkey only, no explicit signer list) versus the multi-signer path.
  bool isSinglePasskeyRemoval(List<OZSelectedSigner> selectedSigners) {
    if (selectedSigners.length != 1) return false;
    final first = selectedSigners.first;
    if (first is! OZSelectedSignerPasskey) return false;
    return first.credentialIdBytes == null;
  }

  // -------------------------------------------------------------------------
  // Public: registerDelegatedKeypairs
  // -------------------------------------------------------------------------

  /// Registers delegated signer keypairs as in-memory keypairs on the
  /// kit-owned external signer manager.
  ///
  /// Calls [OZExternalSignerManager.addFromSecret] for each entry with a
  /// non-empty seed. No-ops silently when the kit is not initialised.
  ///
  /// If any [addFromSecret] call fails, every signer registered on the manager
  /// is removed via [OZExternalSignerManager.removeAll] before rethrowing so
  /// the manager is never left in a partial state.
  ///
  /// Throws the original exception after cleanup — callers must not proceed
  /// after an error is thrown.
  Future<void> registerDelegatedKeypairs(
    Map<String, String> delegatedKeyPairs,
  ) async {
    final manager = _demoState.externalSigners;
    if (manager == null) return;

    try {
      for (final entry in delegatedKeyPairs.entries) {
        final seed = entry.value;
        if (seed.isNotEmpty) {
          await manager.addFromSecret(seed);
        }
      }
    } catch (e) {
      await manager.removeAll();
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Public: registerEd25519Keypairs
  // -------------------------------------------------------------------------

  /// Registers Ed25519 signer keypairs into the kit-owned manager's in-process
  /// registry so the multi-signer pipeline can sign with them.
  ///
  /// The keys are kept entirely in-process; [DemoEd25519Adapter] is NOT
  /// consulted for keys registered here. This is the in-process custody path.
  ///
  /// Throws on registration failure after rolling back successfully registered
  /// entries — callers must not proceed after an error is thrown.
  Future<void> registerEd25519Keypairs(
    Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
  ) {
    return KeypairRegistration.registerEd25519Keypairs(
      _demoState.externalSigners,
      ed25519Secrets,
    );
  }

  /// Removes every signer the flow registered on the kit-owned manager.
  ///
  /// Calls [OZExternalSignerManager.removeAll], which clears all in-memory
  /// keypair and Ed25519 signers, disconnects every external wallet
  /// connection, and clears the persisted wallet connections from storage.
  /// No-ops silently when the kit is not initialised.
  Future<void> clearDelegatedKeypairs() async {
    await _demoState.externalSigners?.removeAll();
  }

  /// Runs [body] and guarantees [clearDelegatedKeypairs] is called even if
  /// [body] throws. Failures from [clearDelegatedKeypairs] are swallowed so
  /// the cleanup never masks an in-flight error from [body].
  ///
  /// Call this AFTER `await registerDelegatedKeypairs(...)` has completed
  /// successfully. The wrapper does not register anything itself; that
  /// stays at the call site so the call site can classify register-time
  /// failures with its own context before invoking the body.
  Future<R> withCleanupOfDelegatedKeypairs<R>(
    Future<R> Function() body,
  ) async {
    try {
      return await body();
    } finally {
      try {
        await clearDelegatedKeypairs();
      } catch (_) {
        // Swallow cleanup failures — they must never mask body errors.
      }
    }
  }

  /// Registers all multi-signer signing material, runs [body], then clears
  /// the registered material in a `finally`.
  ///
  /// Registers the delegated G-address keypairs via [registerDelegatedKeypairs]
  /// and the Ed25519 secrets via [registerEd25519Keypairs] (the in-process
  /// custody path), then runs [body] and returns its value. Both registrations
  /// run inside the guarded region so a failure during Ed25519 registration
  /// still clears the delegated keypairs that were registered first; nothing
  /// leaks on success, failure, or cancellation.
  ///
  /// Registration failures propagate to the caller after cleanup so the call
  /// site can classify them with its own context. [body] is invoked only when
  /// both registrations succeed.
  Future<R> withMultiSignerRegistration<R>({
    required Map<String, String> delegatedKeyPairs,
    required Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
    required Future<R> Function() body,
  }) {
    return withCleanupOfDelegatedKeypairs(() async {
      await registerDelegatedKeypairs(delegatedKeyPairs);
      await registerEd25519Keypairs(ed25519Secrets);
      return body();
    });
  }

  // -------------------------------------------------------------------------
  // Public: buildSelectedSigners
  // -------------------------------------------------------------------------

  /// Converts [SignerInfo] choices into [OZSelectedSigner] entries.
  ///
  /// Delegates to [SelectedSignerBuilder.fromInfos], threading the kit's
  /// storage adapter so passkey signers carry their stored authenticator
  /// transports (enabling cross-device authentication).
  Future<List<OZSelectedSigner>> buildSelectedSigners(
    List<SignerInfo> signers,
  ) =>
      SelectedSignerBuilder.fromInfos(signers, storage: _demoState.storage);

  // -------------------------------------------------------------------------
  // Public: validateDelegatedSecret
  // -------------------------------------------------------------------------

  /// Validates a delegated signer secret seed against its registered address.
  ///
  /// Returns null when valid. Returns an error string on failure.
  String? validateDelegatedSecret(String address, String seed) {
    if (seed.isEmpty) {
      return 'Secret key is required for this signer.';
    }
    if (!StrKey.isValidStellarSecretSeed(seed)) {
      return 'Must be a valid Stellar secret key (S...).';
    }
    try {
      final kp = KeyPair.fromSecretSeed(seed);
      if (kp.accountId != address) {
        return "Secret key does not match this signer's address.";
      }
    } catch (_) {
      return 'Must be a valid Stellar secret key (S...).';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Public: validateEd25519Secret
  // -------------------------------------------------------------------------

  /// Validates a hex-encoded Ed25519 secret seed against [expectedPublicKey].
  ///
  /// Delegates to [TransferFlow.validateEd25519Secret] so the identical
  /// validation logic is not duplicated across flows.
  static ({Uint8List? rawSeed, String? error}) validateEd25519Secret(
    Uint8List expectedPublicKey,
    String hexInput,
  ) =>
      TransferFlow.validateEd25519Secret(expectedPublicKey, hexInput);

  // -------------------------------------------------------------------------
  // Public: classifyRemovalError
  // -------------------------------------------------------------------------

  /// Maps a raw exception to a user-facing error message.
  ///
  /// [WebAuthnCancelled]       → "Passkey authentication cancelled" (logs info).
  /// [StateError]              → in-progress guard message.
  /// [DemoError] (validation)  → surface its message verbatim; for the
  ///                             last-rule case this reads as
  ///                             "Cannot remove the last context rule on
  ///                             this account. Add another rule first."
  /// All other [DemoError]s    → surface the sanitised message verbatim
  ///                             with the standard "Removal failed:" prefix
  ///                             so the entry distinguishes itself in the
  ///                             activity log.
  /// All other errors          → sanitised via [classifyError].
  String classifyRemovalError(Object error) {
    if (error is WebAuthnCancelled) {
      _activityLog.info('Passkey authentication cancelled');
      return 'Passkey authentication cancelled';
    }
    if (error is StateError) {
      _activityLog.error('Removal already in progress');
      return 'A removal is already in progress. Please wait.';
    }
    if (error is DemoError) {
      _activityLog.error('Removal failed: ${error.message}');
      if (error.category == DemoErrorCategory.validation) {
        // Validation messages are already user-friendly; for the last-rule
        // guard the message is short and self-explanatory, so we render it
        // without the "Removal failed:" prefix to avoid sounding like a
        // hard failure.
        return error.message;
      }
      return 'Removal failed: ${error.message}';
    }
    final classified = classifyError(error);
    _activityLog.error('Removal failed: ${classified.message}');
    return 'Removal failed: ${classified.message}';
  }

  // -------------------------------------------------------------------------
  // Public: addContextRule (builder submission)
  // -------------------------------------------------------------------------

  /// Submits a new context rule with the supplied configuration.
  ///
  /// Converts the staged signer/policy lists into the manager's accepted
  /// shape and routes through either the single-passkey path
  /// ([selectedSigners] empty) or the multi-signer path
  /// ([selectedSigners] non-empty).
  ///
  /// Returns a [ContextRuleResult] whose [ContextRuleResult.success] is
  /// true when the transaction is confirmed. On failure, [error] carries
  /// a sanitised user-facing string suitable for direct display.
  ///
  /// Throws [StateError] when another submission is already in flight.
  Future<ContextRuleResult> addContextRule({
    required OZContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    required List<FlowPolicyEntry> policies,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) async {
    if (_isSubmittingRule) {
      throw StateError('A context-rule submission is already in progress.');
    }
    _isSubmittingRule = true;

    try {
      _activityLog.info('Submitting new context rule...');

      // Encode the staged policy list into the {address: scVal} map shape
      // the manager expects. The toScVal() call here is the single SCVal
      // conversion point for the create path. Entries with null install
      // params are unreachable in the builder (every add-form configures
      // params up front), but we skip them defensively.
      final policiesMap = <String, XdrSCVal>{};
      for (final entry in policies) {
        final params = entry.installParams;
        if (params != null) {
          policiesMap[entry.address] = params.toScVal();
        }
      }

      final OZTransactionResult result;
      try {
        result = await _contextRuleManager.addContextRule(
          contextType: contextType,
          name: name,
          validUntil: validUntil,
          signers: signers,
          policies: policiesMap,
          selectedSigners: selectedSigners,
        );
      } on WebAuthnCancelled {
        _activityLog.info('Passkey authentication cancelled');
        return const ContextRuleResult(
          success: false,
          error: 'Passkey authentication cancelled',
        );
      } catch (e) {
        final classified =
            classifyError(e, context: 'Failed to create context rule');
        _activityLog.error(classified.message);
        return ContextRuleResult(
          success: false,
          error: classified.message,
        );
      }

      if (!result.success) {
        final message =
            'Failed to create context rule: ${result.error ?? "Unknown error"}';
        _activityLog.error(message);
        return ContextRuleResult(
          success: false,
          error: message,
        );
      }

      final hash = result.hash ?? '';
      _activityLog.success(
        'Context rule created successfully. Hash: ${truncateAddress(hash)}',
      );
      return ContextRuleResult(success: true, hash: hash);
    } finally {
      _isSubmittingRule = false;
    }
  }

  // -------------------------------------------------------------------------
  // Public: loadAvailablePasskeySigners
  // -------------------------------------------------------------------------

  /// Loads passkey ([OZExternalSigner]) entries from every existing context
  /// rule on the connected account, deduplicated by signer identity.
  ///
  /// [excludeCredentialId] filters out the entry whose Base64URL credential
  /// ID matches — typically the wallet owner's own passkey, which is
  /// already authoritative on the Default rule and adds no signing power
  /// when attached to a new rule.
  ///
  /// Only WebAuthn signers whose verifier address matches the configured
  /// WebAuthn verifier are returned; Ed25519 / generic external signers
  /// are not surfaced through this picker.
  Future<List<OZExternalSigner>> loadAvailablePasskeySigners({
    String? excludeCredentialId,
  }) async {
    final env = _requireEnvironment('loadAvailablePasskeySigners');
    final rules = await _contextRuleManager.listContextRules();
    final webauthnVerifier = env.webauthnVerifierAddress;

    final seen = <String>{};
    final passkeys = <OZExternalSigner>[];
    for (final rule in rules) {
      for (final signer in rule.signers) {
        if (signer is! OZExternalSigner) continue;
        if (signer.verifierAddress != webauthnVerifier) continue;

        final credentialId =
            OZSmartAccountBuilders.getCredentialIdStringFromSigner(signer);
        if (excludeCredentialId != null &&
            credentialId != null &&
            credentialId == excludeCredentialId) {
          continue;
        }

        if (!seen.add(signer.uniqueKey)) continue;
        passkeys.add(signer);
      }
    }
    return passkeys;
  }

  // -------------------------------------------------------------------------
  // Public: registerPasskeySigner
  // -------------------------------------------------------------------------

  /// Drives a WebAuthn registration ceremony for the given [name] and
  /// returns a constructed [OZExternalSigner] (WebAuthn) ready for use in
  /// `addContextRule`.
  ///
  /// Throws [WebAuthnCancelled] when the user dismisses the platform
  /// prompt. Throws [DemoError] (category [DemoErrorCategory.unexpected])
  /// when no WebAuthn provider is configured on the kit.
  Future<OZSmartAccountSigner> registerPasskeySigner(String name) async {
    final env = _requireEnvironment('registerPasskeySigner');
    final provider = env.webauthnProvider;
    if (provider == null) {
      throw const DemoError(
        message: 'No passkey provider is available on this device.',
        category: DemoErrorCategory.unexpected,
      );
    }

    final challenge = _randomBytes(32);
    final userId = _randomBytes(16);

    _activityLog.info('Starting passkey registration...');

    final registration = await provider.register(
      challenge: challenge,
      userId: userId,
      userName: name,
    );

    return OZExternalSigner.webAuthn(
      verifierAddress: env.webauthnVerifierAddress,
      publicKey: registration.publicKey,
      credentialId: registration.credentialId,
    );
  }

  // -------------------------------------------------------------------------
  // Public: buildDelegatedSigner / buildEd25519Signer
  // -------------------------------------------------------------------------

  /// Constructs an [OZDelegatedSigner] from a Stellar G-address.
  ///
  /// Throws [SmartAccountValidationException] when the address is not a valid
  /// G-address or C-address. Callers should validate the surface format
  /// (`G` + 56-char base32) before invoking so the user-visible error
  /// message remains friendly.
  OZSmartAccountSigner buildDelegatedSigner(String address) {
    return OZDelegatedSigner(address);
  }

  /// Constructs an Ed25519 [OZExternalSigner] from a 32-byte public key.
  ///
  /// Throws [SmartAccountValidationException] when [publicKey] is not exactly 32
  /// bytes. The verifier address is taken from the builder environment.
  OZSmartAccountSigner buildEd25519Signer(Uint8List publicKey) {
    final env = _requireEnvironment('buildEd25519Signer');
    return OZExternalSigner.ed25519(
      verifierAddress: env.ed25519VerifierAddress,
      publicKey: publicKey,
    );
  }

  // -------------------------------------------------------------------------
  // Public: context-type builders
  // -------------------------------------------------------------------------

  /// Builds the `Default` context-type marker. Matches operations that do
  /// not match any more-specific rule.
  OZContextRuleType buildDefaultContextType() => const OZContextRuleTypeDefault();

  /// Builds a `CallContract` context type targeting [contractAddress].
  ///
  /// The address is trimmed of surrounding whitespace before construction.
  /// Caller-side input validation should run before invoking this method.
  OZContextRuleType buildCallContractContextType(String contractAddress) {
    return OZContextRuleTypeCallContract(contractAddress.trim());
  }

  /// Builds a `CreateContract` context type targeting deployments that use
  /// [wasmHash] as the WASM source hash.
  OZContextRuleType buildCreateContractContextType(Uint8List wasmHash) {
    return OZContextRuleTypeCreateContract(wasmHash);
  }

  // -------------------------------------------------------------------------
  // Public: resolveAbsoluteLedger
  // -------------------------------------------------------------------------

  /// Converts a ledger [offset] (number of ledgers in the future) to an
  /// absolute ledger sequence by reading the current ledger from the
  /// Soroban RPC and adding [offset].
  ///
  /// Returns null when [offset] is zero (no expiry). Throws on RPC
  /// failure or when the network does not report a current ledger.
  Future<int?> resolveAbsoluteLedger(int offset) async {
    if (offset <= 0) return null;
    final env = _requireEnvironment('resolveAbsoluteLedger');
    final current = await env.getCurrentLedger();
    return current + offset;
  }

  // -------------------------------------------------------------------------
  // Public: resolveSpendingLimitDecimals
  // -------------------------------------------------------------------------

  /// Resolves the decimal scale for a spending-limit policy's guarded token.
  ///
  /// A spending-limit policy applies to the rule's call-contract target, so
  /// [guardedToken] is that contract address, or null for default /
  /// create-contract rules. The native token and non-token rules resolve to
  /// [nativeTokenDecimals] without a network call; a custom guarded token's
  /// `decimals()` value is fetched on-chain.
  ///
  /// A malformed address is reported by the existing field validation; this
  /// method returns [nativeTokenDecimals] for it so a later valid entry
  /// re-triggers resolution. Throws when the on-chain `decimals()` read
  /// fails so the caller can disable the spending-limit Add button rather
  /// than scaling an amount with the wrong precision.
  Future<int> resolveSpendingLimitDecimals(String? guardedToken) async {
    final trimmed = guardedToken?.trim();
    if (trimmed == null ||
        trimmed.isEmpty ||
        trimmed == config.nativeTokenContract ||
        !isValidContractAddress(trimmed)) {
      return nativeTokenDecimals;
    }
    final env = _requireEnvironment('resolveSpendingLimitDecimals');
    return env.fetchTokenDecimals(trimmed);
  }

  // -------------------------------------------------------------------------
  // Public: ed25519VerifierAddress
  // -------------------------------------------------------------------------

  /// Returns the configured Ed25519 verifier C-address.
  ///
  /// Used by the builder UI to show the truncated verifier in the
  /// Ed25519 add-form helper text. Returns null when no kit / no
  /// environment is configured.
  String? get ed25519VerifierAddress => _environment?.ed25519VerifierAddress;

  /// Returns the configured WebAuthn verifier C-address. Null when no
  /// environment is configured.
  String? get webauthnVerifierAddress =>
      _environment?.webauthnVerifierAddress;

  // -------------------------------------------------------------------------
  // Public: classifyAddRuleError
  // -------------------------------------------------------------------------

  /// Maps a raw exception from the add-rule pipeline to a user-facing
  /// message and emits the matching activity-log entry.
  ///
  /// [WebAuthnCancelled]       → "Passkey authentication cancelled" (info).
  /// [StateError]              → in-progress guard message.
  /// [DemoError] (validation)  → surface its message verbatim.
  /// All other [DemoError]s    → "Transaction failed:" prefix + message.
  /// All other errors          → sanitised via [classifyError] with a
  ///                             "Transaction failed:" prefix.
  String classifyAddRuleError(Object error) {
    if (error is WebAuthnCancelled) {
      _activityLog.info('Passkey authentication cancelled');
      return 'Passkey authentication cancelled';
    }
    if (error is StateError) {
      _activityLog.error('Submission already in progress');
      return 'A submission is already in progress. Please wait.';
    }
    if (error is DemoError) {
      _activityLog.error('Transaction failed: ${error.message}');
      if (error.category == DemoErrorCategory.validation) {
        // Validation messages are already user-friendly; render them
        // without the "Transaction failed:" prefix to avoid sounding
        // like a hard failure to the user.
        return error.message;
      }
      return 'Transaction failed: ${error.message}';
    }
    final classified = classifyError(error);
    _activityLog.error('Transaction failed: ${classified.message}');
    return 'Transaction failed: ${classified.message}';
  }

  // -------------------------------------------------------------------------
  // Public: loadParsedContextRule
  // -------------------------------------------------------------------------

  /// Loads a single context rule by [ruleId].
  ///
  /// Fetches all on-chain rules and returns the entry whose ID matches.
  /// Throws [DemoError] (category [DemoErrorCategory.validation]) when no
  /// rule with that ID exists.
  Future<OZParsedContextRule> loadParsedContextRule(int ruleId) async {
    final rules = await _contextRuleManager.listContextRules();
    for (final rule in rules) {
      if (rule.id == ruleId) return rule;
    }
    throw DemoError(
      message: 'Context rule #$ruleId not found.',
      category: DemoErrorCategory.validation,
    );
  }

  // -------------------------------------------------------------------------
  // Public: readPolicyParams
  // -------------------------------------------------------------------------

  /// Reads the on-chain installation parameters for a policy entry.
  ///
  /// The policy stores per-(account, rule) parameters under the storage key
  /// `Vec([Symbol("AccountContext"), Address(account), U32(ruleId)])`. The
  /// returned [PolicyParams] is shaped per the policy type discovered from
  /// [policyAddress].
  ///
  /// [guardedToken] is the call-contract target of the rule, or null for
  /// default / create-contract rules. For spending-limit policies the guarded
  /// token's decimal scale is resolved and used to format the stored base-units
  /// amount back to a human decimal string. A failed decimal resolution returns
  /// null so the screen omits the inline editor rather than pre-populating
  /// with a mis-scaled value — mirror iOS behaviour.
  ///
  /// Returns null when the entry is missing or cannot be parsed. Errors are
  /// logged at info level so the screen can continue and show empty
  /// pre-populated form fields rather than failing the entire edit load.
  Future<PolicyParams?> readPolicyParams({
    required String policyAddress,
    required int ruleId,
    String? guardedToken,
  }) async {
    final state = _demoState.currentState;
    final smartAccount = state.contractId;
    if (smartAccount == null) return null;

    final env = _requireEnvironment('readPolicyParams');
    final known = config.knownPolicies.where((p) => p.address == policyAddress);
    if (known.isEmpty) return null;
    final policyType = known.first.type;

    try {
      final storageKey = XdrSCVal.forVec(<XdrSCVal>[
        XdrSCVal.forSymbol('AccountContext'),
        XdrSCVal.forAddress(Address.forContractId(smartAccount).toXdr()),
        XdrSCVal.forU32(ruleId),
      ]);

      final value = await env.readContractDataValue(
        contractAddress: policyAddress,
        storageKey: storageKey,
      );
      if (value == null) return null;

      switch (policyType) {
        case PolicyType.threshold:
          return parseThresholdParams(value);
        case PolicyType.spendingLimit:
          // Resolve the guarded token's decimals before formatting the stored
          // base-units value. A failed resolution returns null so the inline
          // editor is omitted rather than pre-populating with a wrong scale.
          final int decimals;
          try {
            decimals = await resolveSpendingLimitDecimals(guardedToken);
          } catch (e) {
            _activityLog.info(
              'Could not resolve token decimals for spending-limit policy: '
              '${classifyError(e).message}',
            );
            return null;
          }
          return parseSpendingLimitParams(value, decimals: decimals);
        case PolicyType.weightedThreshold:
          return parseWeightedThresholdParams(value);
        default:
          return null;
      }
    } catch (e) {
      _activityLog.info(
        'Could not read $policyType policy params: ${classifyError(e).message}',
      );
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Public: resolveEditDiffExpiry
  // -------------------------------------------------------------------------

  /// Resolves the [ContextRuleEditDiff] expiry field from a ledger offset
  /// into an absolute ledger sequence.
  ///
  /// The screen records the user's selected duration as an offset; the
  /// flow converts it to an absolute ledger by adding the current ledger
  /// sequence so the on-chain `update_context_rule_valid_until` call
  /// receives a value the contract accepts. A `null` or non-positive
  /// offset is treated as "clear expiry".
  ///
  /// When the diff has no expiry change ([ContextRuleEditDiff.expiryChanged]
  /// is false), the diff is returned unchanged.
  Future<ContextRuleEditDiff> resolveEditDiffExpiry(
    ContextRuleEditDiff diff,
  ) async {
    if (!diff.expiryChanged) return diff;
    final offset = diff.newExpiry;
    if (offset == null || offset <= 0) {
      return diff.copyWith(clearNewExpiry: true);
    }
    final absolute = await resolveAbsoluteLedger(offset);
    return diff.copyWith(newExpiry: absolute);
  }

  // -------------------------------------------------------------------------
  // Public: submitContextRuleEdits
  // -------------------------------------------------------------------------

  /// Applies an [ContextRuleEditDiff] sequentially to on-chain state.
  ///
  /// Each diff member translates to one (or two, for non-threshold policy
  /// modifications) on-chain transactions. The orchestrator runs them in
  /// the canonical edit order:
  ///
  ///   1. name update
  ///   2. removed signers
  ///   3. new signers
  ///   4. (auth-context guard) if new signers were added and there are
  ///      pending policy or expiry changes, the remaining operations are
  ///      skipped and reported via [ContextRuleEditResult.partialDueToAuthGuard].
  ///   5. removed policies
  ///   6. new policies
  ///   7. modified policies (threshold-only → `set_threshold`; otherwise
  ///      `removePolicy + addPolicy`)
  ///   8. expiry update
  ///
  /// On per-step failure, execution stops and the failure is captured in
  /// the returned [ContextRuleEditResult]. [onProgress] is invoked before
  /// each step with a user-facing message; the screen typically threads
  /// this into a spinner label.
  ///
  /// Throws [StateError] when another edit submission is already in
  /// flight.
  Future<ContextRuleEditResult> submitContextRuleEdits({
    required ContextRuleEditDiff diff,
    required List<OZSelectedSigner> selectedSigners,
    required void Function(String) onProgress,
  }) async {
    if (_isSubmittingEdits) {
      throw StateError('An edit submission is already in progress.');
    }
    _isSubmittingEdits = true;

    final ruleId = diff.ruleId;
    final totalOps = diff.totalOperations;
    final hashes = <String>[];
    var completed = 0;

    void progress() => onProgress('Updating rule #$ruleId...');

    Future<ContextRuleEditResult?> step({
      required String stepName,
      required Future<OZTransactionResult> Function() call,
      ContextRuleEditResult? Function()? precondition,
    }) async {
      progress();
      final outcome = await _runStep(
        stepName: stepName,
        totalOps: totalOps,
        priorCompleted: completed,
        hashes: hashes,
        precondition: precondition,
        call: call,
      );
      completed = outcome.completed;
      return outcome.failure;
    }

    try {
      if (diff.isEmpty) return _emptyDiffSuccessResult();

      // Step 1: name update.
      if (diff.nameChanged) {
        final f = await step(
          stepName: 'Updating rule name',
          call: () => _contextRuleManager.updateContextRuleName(
            ruleId: ruleId,
            name: diff.newName ?? '',
            selectedSigners: selectedSigners,
          ),
        );
        if (f != null) return f;
      }

      // Step 2: remove existing signers.
      for (var i = 0; i < diff.removedSigners.length; i++) {
        final entry = diff.removedSigners[i];
        final sn = 'Removing signer ${i + 1} of ${diff.removedSigners.length}';
        final f = await step(
          stepName: sn,
          precondition: () => _requireOnChainId(
              entry.onChainId, sn, 'Signer is missing its on-chain ID.',
              completed: completed, totalOps: totalOps, hashes: hashes),
          call: () => _contextRuleManager.removeSignerFromRule(
            ruleId: ruleId,
            signerId: entry.onChainId!,
            selectedSigners: selectedSigners,
          ),
        );
        if (f != null) return f;
      }

      // Step 3: add new signers.
      for (var i = 0; i < diff.newSigners.length; i++) {
        final entry = diff.newSigners[i];
        final f = await step(
          stepName: 'Adding signer ${i + 1} of ${diff.newSigners.length}',
          call: () => _dispatchAddSigner(
              ruleId: ruleId, entry: entry, selectedSigners: selectedSigners),
        );
        if (f != null) return f;
      }

      // Step 4: auth-context guard. Adding signers invalidates the auth
      // context for subsequent policy / expiry calls, so the orchestrator
      // pauses here and reports a partial-success result. The screen reloads
      // from chain so the user can resubmit the remaining diff.
      if (diff.newSigners.isNotEmpty && _hasPolicyOrExpiryWork(diff)) {
        return _authGuardPartialResult(
            completed: completed, totalOps: totalOps, hashes: hashes);
      }

      // Step 5: remove policies.
      for (var i = 0; i < diff.removedPolicies.length; i++) {
        final entry = diff.removedPolicies[i];
        final sn = 'Removing policy ${i + 1} of '
            '${diff.removedPolicies.length}';
        final f = await step(
          stepName: sn,
          precondition: () => _requireOnChainId(
              entry.onChainId, sn, 'Policy is missing its on-chain ID.',
              completed: completed, totalOps: totalOps, hashes: hashes),
          call: () => _contextRuleManager.removePolicyFromRule(
            ruleId: ruleId,
            policyId: entry.onChainId!,
            selectedSigners: selectedSigners,
          ),
        );
        if (f != null) return f;
      }

      // Step 6: add new policies.
      for (var i = 0; i < diff.newPolicies.length; i++) {
        final entry = diff.newPolicies[i];
        final sn = 'Adding policy ${i + 1} of ${diff.newPolicies.length}';
        final f = await step(
          stepName: sn,
          precondition: () => _requireInstallSpec(entry.installSpec, sn,
              completed: completed, totalOps: totalOps, hashes: hashes),
          call: () => _dispatchAddPolicy(
            ruleId: ruleId,
            policyAddress: entry.address,
            spec: entry.installSpec!,
            selectedSigners: selectedSigners,
          ),
        );
        if (f != null) return f;
      }

      // Step 7: modified policies. Threshold-only changes use the policy's
      // set_threshold entry point (one tx); other changes use remove + re-add
      // (two txs that share a combined pre-flight on the iteration).
      for (var i = 0; i < diff.modifiedPolicies.length; i++) {
        final entry = diff.modifiedPolicies[i];
        final base =
            'Updating policy ${i + 1} of ${diff.modifiedPolicies.length}';

        if (entry.info?.type == PolicyType.threshold) {
          final threshold = _extractThresholdFromSpec(entry.installSpec);
          final f = await step(
            stepName: base,
            precondition: () => threshold == null
                ? _editFailure(
                    completedOps: completed,
                    totalOps: totalOps,
                    failedStep: base,
                    rawError: 'Policy is missing the updated threshold value.',
                    hashes: hashes)
                : null,
            call: () => _contextRuleManager.setPolicyThreshold(
              ruleId: ruleId,
              policyAddress: entry.address,
              newThreshold: threshold!,
              selectedSigners: selectedSigners,
            ),
          );
          if (f != null) return f;
          continue;
        }

        // Non-threshold: combined pre-flight skips the whole iteration when
        // either input is null, then remove + re-add as two sequential steps.
        final removeStep = '$base (remove)';
        final readdStep = '$base (re-add)';
        final preflight = _modifiedPolicyDualPreflight(
            entry: entry,
            removeStep: removeStep,
            readdStep: readdStep,
            completed: completed,
            totalOps: totalOps,
            hashes: hashes);
        if (preflight != null) return preflight;

        final fRemove = await step(
          stepName: removeStep,
          call: () => _contextRuleManager.removePolicyFromRule(
            ruleId: ruleId,
            policyId: entry.onChainId!,
            selectedSigners: selectedSigners,
          ),
        );
        if (fRemove != null) return fRemove;

        final fAdd = await step(
          stepName: readdStep,
          call: () => _dispatchAddPolicy(
            ruleId: ruleId,
            policyAddress: entry.address,
            spec: entry.installSpec!,
            selectedSigners: selectedSigners,
          ),
        );
        if (fAdd != null) return fAdd;
      }

      // Step 8: expiry update.
      if (diff.expiryChanged) {
        final f = await step(
          stepName: 'Updating expiration',
          call: () => _contextRuleManager.updateContextRuleValidUntil(
            ruleId: ruleId,
            validUntil: diff.newExpiry,
            selectedSigners: selectedSigners,
          ),
        );
        if (f != null) return f;
      }

      _activityLog.success(
        'All $completed edit operation(s) completed successfully',
      );
      return ContextRuleEditResult(
        success: true,
        completedOperations: completed,
        totalOperations: totalOps,
        partialDueToAuthGuard: false,
        authGuardMessage: null,
        error: null,
        failedStep: null,
        transactionHashes: List<String>.unmodifiable(hashes),
      );
    } finally {
      _isSubmittingEdits = false;
    }
  }

  // -------------------------------------------------------------------------
  // Public: classifyEditError
  // -------------------------------------------------------------------------

  /// Maps a thrown error from the edit-submission path to a user-facing
  /// message, mirroring the conventions of [classifyAddRuleError].
  ///
  /// [WebAuthnCancelled]       → "Passkey authentication cancelled" (info).
  /// [StateError]              → in-progress guard message.
  /// [DemoError] (validation)  → surface its message verbatim.
  /// All other [DemoError]s    → "Edit failed:" prefix + message.
  /// All other errors          → sanitised via [classifyError] with the
  ///                             "Edit failed:" prefix.
  String classifyEditError(Object error) {
    if (error is WebAuthnCancelled) {
      _activityLog.info('Passkey authentication cancelled');
      return 'Passkey authentication cancelled';
    }
    if (error is StateError) {
      _activityLog.error('Edit already in progress');
      return 'An edit submission is already in progress. Please wait.';
    }
    if (error is DemoError) {
      _activityLog.error('Edit failed: ${error.message}');
      if (error.category == DemoErrorCategory.validation) {
        return error.message;
      }
      return 'Edit failed: ${error.message}';
    }
    final classified = classifyError(error);
    _activityLog.error('Edit failed: ${classified.message}');
    return 'Edit failed: ${classified.message}';
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Returns the bound environment or throws when it is missing.
  ContextRuleBuilderEnvironmentType _requireEnvironment(String operation) {
    final env = _environment;
    if (env == null) {
      throw StateError(
        'ContextRuleFlow environment is required for operation: $operation',
      );
    }
    return env;
  }

  /// Generates [length] cryptographically random bytes for WebAuthn
  /// challenge and user-id values. Uses [Random.secure] by default;
  /// tests may inject a seeded [Random] for determinism.
  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _secureRandom.nextInt(256);
    }
    return bytes;
  }

  /// Extracts deduplicated [SignerInfo] entries from the given rule list.
  List<SignerInfo> _extractSigners(
    List<OZParsedContextRule> rules, {
    String? connectedCredentialId,
  }) {
    final seen = <String>{};
    final signers = <SignerInfo>[];

    for (final rule in rules) {
      for (final signer in rule.signers) {
        final key = signer.uniqueKey;
        if (!seen.add(key)) continue;

        if (signer is OZExternalSigner) {
          final credentialId =
              OZSmartAccountBuilders.getCredentialIdStringFromSigner(signer);
          if (credentialId != null) {
            final isConnected = connectedCredentialId != null &&
                credentialId == connectedCredentialId;
            signers.add(SignerInfo(
              displayLabel: truncateCredentialId(credentialId),
              address: '',
              kind: SignerKind.passkey,
              isConnectedCredential: isConnected,
              credentialId: credentialId,
              rawSigner: signer,
            ));
          } else {
            // Ed25519 signers are identified by their public key, not the
            // verifier contract address. Show a short hex preview of keyData.
            final keyHex = bytesToHex(signer.keyData);
            final keyPreview = keyHex.length > 8 ? keyHex.substring(0, 8) : keyHex;
            signers.add(SignerInfo(
              displayLabel: 'key:$keyPreview...',
              address: signer.verifierAddress,
              kind: SignerKind.ed25519,
              isConnectedCredential: false,
              rawSigner: signer,
            ));
          }
        } else if (signer is OZDelegatedSigner) {
          final address = signer.address;
          signers.add(SignerInfo(
            displayLabel: truncateAddress(address),
            address: address,
            kind: SignerKind.delegated,
            isConnectedCredential: false,
            rawSigner: signer,
          ));
        }
      }
    }

    return signers;
  }
}

// ---------------------------------------------------------------------------
// Util constants
// ---------------------------------------------------------------------------

/// Average number of ledgers closed per hour on the Stellar network
/// (approximately five seconds per ledger). Mirrors
/// `Util.ledgersPerHour` from the Stellar Flutter SDK.
const int ledgersPerHour = Util.ledgersPerHour;

/// Average number of ledgers closed per day on the Stellar network
/// (approximately five seconds per ledger). Mirrors
/// `Util.ledgersPerDay` from the Stellar Flutter SDK.
const int ledgersPerDay = Util.ledgersPerDay;
