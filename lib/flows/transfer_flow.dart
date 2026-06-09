/// Business logic for token transfers from a smart account.
///
/// [TransferFlow] is the single entry point for all transfer operations.
/// The [TransferScreen] delegates every SDK interaction here; screens must
/// not call into the SDK directly.
///
/// Three transfer variants:
/// - Single-signer simple ([transfer]): one passkey, direct SDK call.
/// - Single-signer smart-account auth ([transfer]): same API; context rules
///   handled transparently by the SDK.
/// - Multi-signer ([multiSignerTransfer]): explicit signer list; caller must
///   register delegated keypairs beforehand via [registerDelegatedKeypairs].
///
/// Signer discovery:
/// [loadAvailableSigners] fetches context rules and extracts signers so the
/// screen can decide between the single-signer and multi-signer paths.
library;

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../config/demo_config.dart' as config;
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import '../util/keypair_registration.dart';
import '../util/selected_signer_builder.dart';
import 'ed25519_signer_identity.dart';
import 'main_screen_flow.dart';

export 'ed25519_signer_identity.dart';

// ---------------------------------------------------------------------------
// SignerKind — categorization of signer types
// ---------------------------------------------------------------------------

/// Categorization of the signer represented by a [SignerInfo].
///
/// Determines the section the signer is rendered in within the signer picker
/// and the auth path used when the transaction is submitted.
enum SignerKind {
  /// WebAuthn passkey signer (an [OZExternalSigner] whose [keyData] contains
  /// a credential ID).
  passkey,

  /// Stellar account ("delegated") signer authorized by a G-address keypair.
  delegated,

  /// Ed25519 external signer (an [OZExternalSigner] without a WebAuthn
  /// credential ID).
  ed25519,
}

// ---------------------------------------------------------------------------
// SignerInfo — signer descriptor used by the transfer flow
// ---------------------------------------------------------------------------

/// Describes a signer on the connected smart account, returned by
/// [TransferFlow.loadAvailableSigners].
final class SignerInfo {
  /// Constructs a signer info record.
  const SignerInfo({
    required this.displayLabel,
    required this.address,
    required this.kind,
    required this.isConnectedCredential,
    this.credentialId,
    this.rawSigner,
  });

  /// Human-readable label (e.g. passkey credential ID snippet, G-address).
  final String displayLabel;

  /// Stellar address (G-address for delegated signers, empty otherwise).
  final String address;

  /// Category of this signer; controls how the picker groups and authorizes
  /// it.
  final SignerKind kind;

  /// True when this passkey matches the currently connected credential.
  ///
  /// Only meaningful when [kind] is [SignerKind.passkey].
  final bool isConnectedCredential;

  /// Base64URL credential ID for passkey signers, null for delegated and
  /// Ed25519 signers.
  final String? credentialId;

  /// The underlying SDK signer this entry was extracted from.
  ///
  /// Carries the on-chain `keyData` required by
  /// [OZMultiSignerManager.submitWithMultipleSigners] for rule resolution.
  /// May be null when the entry was constructed by a widget test that does
  /// not exercise multi-signer submission.
  final OZSmartAccountSigner? rawSigner;
}

// ---------------------------------------------------------------------------
// TransferResult
// ---------------------------------------------------------------------------

/// Outcome of a [TransferFlow.transfer] or [TransferFlow.multiSignerTransfer] call.
final class TransferResult {
  /// Constructs a transfer result.
  const TransferResult({
    required this.transactionHash,
    required this.amount,
    required this.tokenLabel,
    required this.recipient,
  });

  /// On-chain transaction hash.
  final String transactionHash;

  /// Amount transferred, as the human-readable decimal string supplied by the user.
  final String amount;

  /// Token ticker ("XLM" or "DEMO").
  final String tokenLabel;

  /// Recipient address.
  final String recipient;
}

// ---------------------------------------------------------------------------
// TransactionOperationsType
// ---------------------------------------------------------------------------

/// Abstraction over [OZTransactionOperations.transfer] used by
/// [TransferFlow].
///
/// Allows unit tests to inject a mock without running real network operations.
abstract interface class TransactionOperationsType {
  /// Transfers tokens; triggers a WebAuthn ceremony.
  ///
  /// [decimals] selects the amount scale: the known native decimals for the
  /// native token (skipping the on-chain `decimals()` read), or null to let
  /// the SDK fetch the token's own decimals.
  Future<OZTransactionResult> transfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    int? decimals,
  });
}

/// Default production adapter backed by [OZTransactionOperations].
final class TransactionOperationsAdapter implements TransactionOperationsType {
  /// Constructs the adapter from the live [OZTransactionOperations] instance.
  const TransactionOperationsAdapter(this._ops);

  final OZTransactionOperations _ops;

  @override
  Future<OZTransactionResult> transfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    int? decimals,
  }) {
    return _ops.transfer(
      tokenContract: tokenContract,
      recipient: recipient,
      amount: amount,
      decimals: decimals,
    );
  }
}

// ---------------------------------------------------------------------------
// MultiSignerManagerType
// ---------------------------------------------------------------------------

/// Abstraction over [OZMultiSignerManager.multiSignerTransfer] used by
/// [TransferFlow].
abstract interface class MultiSignerManagerType {
  /// Transfers tokens signed by the explicit [selectedSigners] list.
  ///
  /// [decimals] selects the amount scale: the known native decimals for the
  /// native token (skipping the on-chain `decimals()` read), or null to let
  /// the SDK fetch the token's own decimals.
  Future<OZTransactionResult> multiSignerTransfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    required List<OZSelectedSigner> selectedSigners,
    int? decimals,
  });
}

/// Default production adapter backed by [OZMultiSignerManager].
final class MultiSignerManagerAdapter implements MultiSignerManagerType {
  /// Constructs the adapter from the live [OZMultiSignerManager] instance.
  const MultiSignerManagerAdapter(this._manager);

  final OZMultiSignerManager _manager;

  @override
  Future<OZTransactionResult> multiSignerTransfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    required List<OZSelectedSigner> selectedSigners,
    int? decimals,
  }) {
    return _manager.multiSignerTransfer(
      tokenContract: tokenContract,
      recipient: recipient,
      amount: amount,
      selectedSigners: selectedSigners,
      decimals: decimals,
    );
  }
}

// ---------------------------------------------------------------------------
// ContextRuleManagerType
// ---------------------------------------------------------------------------

/// Abstraction over [OZContextRuleManager.listContextRules] used by
/// [TransferFlow.loadAvailableSigners].
abstract interface class ContextRuleManagerType {
  /// Returns all active parsed context rules for the connected contract.
  Future<List<OZParsedContextRule>> listContextRules();
}

/// Default production adapter backed by [OZContextRuleManager].
final class ContextRuleManagerAdapter implements ContextRuleManagerType {
  /// Constructs the adapter from the live [OZContextRuleManager] instance.
  const ContextRuleManagerAdapter(this._manager);

  final OZContextRuleManager _manager;

  @override
  Future<List<OZParsedContextRule>> listContextRules() =>
      _manager.listContextRules();
}

// ---------------------------------------------------------------------------
// TransferFlow
// ---------------------------------------------------------------------------

/// Business logic for the token-transfer screen.
///
/// Construct once per screen instance, passing the Riverpod notifiers and
/// SDK adapters as direct dependencies. The [TransferScreen] holds one
/// [TransferFlow] for its lifetime.
///
/// Thread safety:
/// All public methods are `async`. [_isTransferring] guards against
/// concurrent in-flight transfer calls. The screen's [LoadingButton]
/// provides the primary re-entrancy guard; this flag is an additional
/// safeguard for callers outside the button.
final class TransferFlow {
  /// Constructs a flow with injected dependencies.
  ///
  /// [demoState] and [activityLog] are the Riverpod notifiers.
  /// [transactionOperations] is the SDK adapter for single-signer transfers.
  /// [multiSignerManager] is the SDK adapter for multi-signer transfers.
  /// [contextRuleManager] is the SDK adapter for loading signers.
  /// [mainScreenFlow] is used for balance refresh after a successful transfer;
  /// when null the refresh is skipped (unit-test mode).
  TransferFlow({
    required DemoStateNotifier demoState,
    required ActivityLogNotifier activityLog,
    required TransactionOperationsType transactionOperations,
    required MultiSignerManagerType multiSignerManager,
    required ContextRuleManagerType contextRuleManager,
    MainScreenFlow? mainScreenFlow,
  })  : _demoState = demoState,
        _activityLog = activityLog,
        _transactionOperations = transactionOperations,
        _multiSignerManager = multiSignerManager,
        _contextRuleManager = contextRuleManager,
        _mainScreenFlow = mainScreenFlow;

  final DemoStateNotifier _demoState;
  final ActivityLogNotifier _activityLog;
  final TransactionOperationsType _transactionOperations;
  final MultiSignerManagerType _multiSignerManager;
  final ContextRuleManagerType _contextRuleManager;
  final MainScreenFlow? _mainScreenFlow;

  // ---- Re-entrancy guard ----

  /// True while a transfer is executing.
  bool _isTransferring = false;

  // -------------------------------------------------------------------------
  // Public: loadAvailableSigners
  // -------------------------------------------------------------------------

  /// Loads the available signers for the connected smart account.
  ///
  /// Fetches all active context rules via [contextRuleManager.listContextRules]
  /// and extracts passkey and delegated signer entries. Returns an empty list
  /// when the wallet is not connected, when no context rules exist, or when
  /// any error occurs (graceful fallback to single-signer mode).
  ///
  /// The connected credential ID from [DemoStateNotifier] is used to mark
  /// the matching passkey entry with [SignerInfo.isConnectedCredential].
  Future<List<SignerInfo>> loadAvailableSigners() async {
    final state = _demoState.currentState;
    if (!state.isConnected) return const <SignerInfo>[];

    try {
      final rules = await _contextRuleManager.listContextRules();
      return _extractSigners(rules, connectedCredentialId: state.credentialId);
    } catch (_) {
      return const <SignerInfo>[];
    }
  }

  // -------------------------------------------------------------------------
  // Public: transfer (single-signer)
  // -------------------------------------------------------------------------

  /// Transfers tokens using the connected passkey (single-signer path).
  ///
  /// Triggers one WebAuthn authentication ceremony, then submits the
  /// transaction. On success, refreshes XLM and DEMO balances.
  ///
  /// Throws:
  /// - [WebAuthnCancelled] when the user dismisses the passkey prompt.
  /// - Any SDK exception (e.g. [SmartAccountTransactionException]) for network or
  ///   on-chain failures.
  ///
  /// Caller must check [_isTransferring] before calling; the guard prevents
  /// concurrent calls.
  Future<TransferResult> transfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    required String tokenLabel,
  }) async {
    if (_isTransferring) {
      throw StateError('A transfer is already in progress.');
    }
    _isTransferring = true;
    try {
      final shortRecipient = truncateAddress(recipient);
      _activityLog.info(
        'Transferring $amount $tokenLabel to $shortRecipient...',
      );

      final result = await _transactionOperations.transfer(
        tokenContract: tokenContract,
        recipient: recipient,
        amount: amount,
        decimals: _transferDecimals(tokenContract),
      );

      if (!result.success) {
        throw DemoError(
          message: result.error ?? 'Transfer failed',
          category: DemoErrorCategory.onChain,
        );
      }

      final hash = result.hash ?? '';
      _activityLog.success(
        'Transfer successful! Hash: ${truncateAddress(hash)}',
      );

      await _refreshBalances();

      return TransferResult(
        transactionHash: hash,
        amount: amount,
        tokenLabel: tokenLabel,
        recipient: recipient,
      );
    } finally {
      _isTransferring = false;
    }
  }

  // -------------------------------------------------------------------------
  // Public: multiSignerTransfer
  // -------------------------------------------------------------------------

  /// Transfers tokens using an explicit list of signers (multi-signer path).
  ///
  /// The caller must invoke [registerDelegatedKeypairs] before calling this
  /// method so the external signer adapter can sign auth entries for
  /// delegated Stellar account signers.
  ///
  /// On success, refreshes XLM and DEMO balances.
  ///
  /// Throws:
  /// - [WebAuthnCancelled] when the user dismisses any passkey prompt.
  /// - Any SDK exception for network or on-chain failures.
  Future<TransferResult> multiSignerTransfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    required String tokenLabel,
    required List<OZSelectedSigner> selectedSigners,
  }) async {
    if (_isTransferring) {
      throw StateError('A transfer is already in progress.');
    }
    _isTransferring = true;
    try {
      final shortRecipient = truncateAddress(recipient);
      _activityLog.info(
        'Multi-signer transfer: $amount $tokenLabel to $shortRecipient '
        '(${selectedSigners.length} signer(s))',
      );

      final result = await _multiSignerManager.multiSignerTransfer(
        tokenContract: tokenContract,
        recipient: recipient,
        amount: amount,
        selectedSigners: selectedSigners,
        decimals: _transferDecimals(tokenContract),
      );

      if (!result.success) {
        throw DemoError(
          message: result.error ?? 'Transfer failed',
          category: DemoErrorCategory.onChain,
        );
      }

      final hash = result.hash ?? '';
      _activityLog.success(
        'Multi-signer transfer successful! Hash: ${truncateAddress(hash)}',
      );

      await _refreshBalances();

      return TransferResult(
        transactionHash: hash,
        amount: amount,
        tokenLabel: tokenLabel,
        recipient: recipient,
      );
    } finally {
      _isTransferring = false;
    }
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
  /// Throws the original exception after cleanup — callers must not proceed with
  /// the transfer.
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
      // Partial registration — roll back to prevent a corrupt signer state.
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
  /// consulted for keys registered here (the manager resolves them from its
  /// own in-memory registry first). This is the in-process custody path.
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
  /// failures with its own context ("Approve failed", "Transfer failed",
  /// "Add rule failed", etc.) before invoking the body.
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
  // Public: isSinglePasskeyTransfer
  // -------------------------------------------------------------------------

  /// Returns true when [selectedSigners] contains only the connected passkey
  /// (i.e. one [OZSelectedSignerPasskey] with no additional signers).
  ///
  /// Used to route the confirm action in the signer-picker sheet: when true
  /// the fast [transfer] path is used instead of [multiSignerTransfer].
  bool isSinglePasskeyTransfer(List<OZSelectedSigner> selectedSigners) {
    if (selectedSigners.length != 1) return false;
    final first = selectedSigners.first;
    if (first is! OZSelectedSignerPasskey) return false;
    // When the signer has no credential ID bytes it represents the connected
    // passkey — use the fast single-signer path.
    return first.credentialIdBytes == null;
  }

  // -------------------------------------------------------------------------
  // Public: buildSelectedSigners
  // -------------------------------------------------------------------------

  /// Converts [SignerInfo] choices into [OZSelectedSigner] entries consumed by
  /// [multiSignerTransfer].
  ///
  /// Delegates to [SelectedSignerBuilder.fromInfos], threading the kit's
  /// storage adapter so passkey signers carry their stored authenticator
  /// transports (enabling cross-device authentication).
  Future<List<OZSelectedSigner>> buildSelectedSigners(
    List<SignerInfo> signers,
  ) =>
      SelectedSignerBuilder.fromInfos(signers, storage: _demoState.storage);

  // -------------------------------------------------------------------------
  // Public: resolveTokenContract
  // -------------------------------------------------------------------------

  /// Returns the token contract address for the given [tokenKey].
  ///
  /// "xlm" maps to [config.nativeTokenContract].
  /// "demo" maps to [DemoStateNotifier.currentState.demoTokenContractId].
  /// Returns null when the DEMO token contract is not yet deployed.
  String? resolveTokenContract(String tokenKey) {
    if (tokenKey == _tokenKeyXlm) return config.nativeTokenContract;
    return _demoState.currentState.demoTokenContractId;
  }

  // -------------------------------------------------------------------------
  // Public: validateRecipient
  // -------------------------------------------------------------------------

  /// Validates the recipient address.
  ///
  /// Returns null on success, or an error string on failure.
  String? validateRecipient(String value) {
    if (value.isEmpty) return null;
    if (!StrKey.isValidStellarAccountId(value) &&
        !StrKey.isValidContractId(value)) {
      return 'Must be a valid Stellar account (G...) or contract (C...) address';
    }
    if (value == _demoState.currentState.contractId) {
      return 'Cannot transfer to your own account';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Public: validateDelegatedSecret
  // -------------------------------------------------------------------------

  /// Validates a delegated signer secret seed against its registered address.
  ///
  /// Returns null when [seed] is a valid Stellar secret seed whose derived
  /// public key matches [address]. Returns a non-null error string on any
  /// validation failure.
  ///
  /// Widgets must delegate to this method rather than importing the Stellar
  /// SDK directly.
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
        return 'Secret key does not match this signer\'s address.';
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
  /// [hexInput] must be a lowercase hex string of exactly
  /// [SmartAccountConstants.ed25519SecretSeedSize] * 2 characters. The derived
  /// public key must match [expectedPublicKey] byte-for-byte.
  ///
  /// Returns a record whose [rawSeed] field carries the decoded seed bytes on
  /// success, and whose [error] field carries a user-facing message on failure.
  /// Exactly one of the two fields is non-null.
  static ({Uint8List? rawSeed, String? error}) validateEd25519Secret(
    Uint8List expectedPublicKey,
    String hexInput,
  ) {
    const seedSize = SmartAccountConstants.ed25519SecretSeedSize;
    const hexLen = seedSize * 2;
    const badSecretMessage =
        'Secret key must be $hexLen hex characters ($seedSize bytes).';

    final Uint8List rawSeed;
    final KeyPair keypair;
    try {
      if (hexInput.length != hexLen) throw const FormatException('bad length');
      rawSeed = Util.hexToBytes(hexInput);
      keypair = KeyPair.fromSecretSeedList(rawSeed);
    } catch (_) {
      return (rawSeed: null, error: badSecretMessage);
    }

    final derivedPublicKey = Uint8List.fromList(keypair.publicKey);
    if (!_bytesEqual(derivedPublicKey, expectedPublicKey)) {
      return (
        rawSeed: null,
        error: "Secret key does not match this signer's public key.",
      );
    }

    return (rawSeed: rawSeed, error: null);
  }

  // -------------------------------------------------------------------------
  // Public: validateAmount
  // -------------------------------------------------------------------------

  /// Validates the amount string.
  ///
  /// Returns null on success, or an error string on failure.
  ///
  /// [availableBalance] is the user's current token balance as a decimal
  /// string. When provided and the entered amount exceeds it, returns
  /// `'Exceeds available balance'`.
  static String? validateAmount(String value, {double? availableBalance}) {
    if (value.isEmpty) return null;
    if (value.toLowerCase().contains('e')) {
      return 'Scientific notation is not supported';
    }
    // Enforce Stellar 7-decimal precision cap before double parsing.
    final decimalPattern = RegExp(r'^-?\d+(\.\d{1,7})?$');
    if (!decimalPattern.hasMatch(value)) {
      return 'Must be a valid number';
    }
    final parsed = double.tryParse(value);
    if (parsed == null) {
      return 'Must be a valid number';
    }
    if (parsed <= 0) {
      return 'Must be greater than zero';
    }
    if (availableBalance != null && parsed > availableBalance) {
      return 'Exceeds available balance';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Public: classifyTransferError
  // -------------------------------------------------------------------------

  /// Maps a raw exception to a user-facing error message.
  ///
  /// [WebAuthnCancelled] exceptions map to a fixed cancellation message.
  /// All other exceptions are classified and sanitised via [classifyError].
  String classifyTransferError(Object error) {
    if (error is WebAuthnCancelled) {
      _activityLog.info('Passkey authentication cancelled');
      return 'Passkey authentication cancelled';
    }
    // StateError from the in-flight guard — surface a clear message rather
    // than exposing the raw "Bad state:" prefix from Dart's StateError.
    if (error is StateError) {
      _activityLog.error('Transfer already in progress');
      return 'A transfer is already in progress. Please wait.';
    }
    final classified = classifyError(error);
    _activityLog.error('Transfer failed: ${classified.message}');
    return 'Transfer failed: ${classified.message}';
  }

  // -------------------------------------------------------------------------
  // Token key constants
  // -------------------------------------------------------------------------

  /// Token key for XLM (native).
  static const String tokenKeyXlm = _tokenKeyXlm;

  /// Token key for Demo Token (DEMO).
  static const String tokenKeyDemo = _tokenKeyDemo;

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Resolves the amount scale to pass to the SDK transfer methods.
  ///
  /// Native XLM is fixed at [nativeTokenDecimals], so the demo supplies it
  /// directly to avoid an extra `decimals()` round trip. For any other token,
  /// returns null so the SDK fetches the token contract's own decimals.
  int? _transferDecimals(String tokenContract) =>
      tokenContract == config.nativeTokenContract ? nativeTokenDecimals : null;

  /// Refreshes XLM and DEMO token balances after a successful transfer.
  ///
  /// Delegates to [MainScreenFlow.refreshBalances]. Errors are non-fatal.
  Future<void> _refreshBalances() async {
    try {
      await _mainScreenFlow?.refreshBalances();
    } catch (_) {
      // Non-fatal; stale balance remains until next manual refresh.
    }
  }

  /// Extracts [SignerInfo] entries from a list of parsed context rules.
  ///
  /// Each rule's [OZSmartAccountSigner] entries are inspected:
  ///
  /// - [OZExternalSigner] with a WebAuthn credential ID embedded in [keyData]
  ///   becomes a [SignerKind.passkey] entry. When the Base64URL credential
  ///   ID matches [connectedCredentialId] the entry is marked as
  ///   [SignerInfo.isConnectedCredential].
  /// - [OZExternalSigner] without a credential ID becomes a
  ///   [SignerKind.ed25519] entry whose [address] is the verifier address.
  /// - [OZDelegatedSigner] entries become [SignerKind.delegated] entries
  ///   whose [address] is the Stellar G- or C-address.
  ///
  /// Duplicate signers (same [uniqueKey] across rules) are deduplicated.
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
          // Decode credential ID from keyData when it is a WebAuthn signer.
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
// Token key private constants
// ---------------------------------------------------------------------------

const String _tokenKeyXlm = 'xlm';
const String _tokenKeyDemo = 'demo';

// ---------------------------------------------------------------------------
// Byte comparison helper
// ---------------------------------------------------------------------------

/// Returns true when [a] and [b] have identical length and contents.
bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
