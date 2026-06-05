/// Business logic for the token allowance Approve screen.
///
/// [ApproveFlow] is the single entry point for granting a token spending
/// allowance from the connected smart account. The [ApproveScreen] delegates
/// every SDK interaction here; screens must not call into the SDK directly.
///
/// Three operations:
/// - [approveAllowance]            — single-signer approve via the connected
///                                   passkey.
/// - [multiSignerApproveAllowance] — multi-signer approve using an explicit
///                                   list of signers. The caller must
///                                   register delegated keypairs via
///                                   [registerDelegatedKeypairs] beforehand.
///                                   Ed25519 secrets are registered on the
///                                   adapter via [registerEd25519ViaAdapter].
/// - [fetchAllowance]              — read-only simulation of the token's
///                                   `allowance(from, spender)` entry point;
///                                   used by the result card.
library;

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../token/demo_token_service.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import 'context_rule_flow.dart' show ContextRuleFlow;
import 'ed25519_signer_identity.dart';

// ---------------------------------------------------------------------------
// ApproveResult
// ---------------------------------------------------------------------------

/// Outcome of an [ApproveFlow.approveAllowance] or
/// [ApproveFlow.multiSignerApproveAllowance] call.
///
/// [success] is true when the on-chain transaction was confirmed.
/// [hash] is populated on success.
/// [error] carries a sanitised user-facing message on failure.
final class ApproveResult {
  /// Constructs an approve result.
  const ApproveResult({
    required this.success,
    this.hash,
    this.error,
  });

  /// True when the underlying SDK call confirmed on-chain.
  final bool success;

  /// On-chain transaction hash on success; null on failure.
  final String? hash;

  /// Sanitised user-facing error message on failure; null on success.
  final String? error;
}

// ---------------------------------------------------------------------------
// ContractCallType
// ---------------------------------------------------------------------------

/// Abstraction over [OZTransactionOperations.contractCall] used by
/// [ApproveFlow] for single-signer approve.
///
/// Allows unit tests to inject a mock adapter without running real network
/// operations.
abstract interface class ContractCallType {
  /// Invokes [targetFn] on [target] with [targetArgs]; triggers a WebAuthn
  /// ceremony when authorisation is required.
  Future<OZTransactionResult> contractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
  });
}

/// Default production adapter backed by [OZTransactionOperations].
final class ContractCallAdapter implements ContractCallType {
  /// Constructs the adapter from the live [OZTransactionOperations] instance.
  const ContractCallAdapter(this._ops);

  final OZTransactionOperations _ops;

  @override
  Future<OZTransactionResult> contractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
  }) {
    return _ops.contractCall(
      target: target,
      targetFn: targetFn,
      targetArgs: targetArgs,
    );
  }
}

// ---------------------------------------------------------------------------
// MultiSignerContractCallType
// ---------------------------------------------------------------------------

/// Abstraction over [OZMultiSignerManager.multiSignerContractCall] used by
/// [ApproveFlow] for multi-signer approve.
abstract interface class MultiSignerContractCallType {
  /// Invokes [targetFn] on [target] with [targetArgs], signed by the
  /// explicit [selectedSigners] list.
  Future<OZTransactionResult> multiSignerContractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
    required List<OZSelectedSigner> selectedSigners,
  });
}

/// Default production adapter backed by [OZMultiSignerManager].
final class MultiSignerContractCallAdapter
    implements MultiSignerContractCallType {
  /// Constructs the adapter from the live [OZMultiSignerManager] instance.
  const MultiSignerContractCallAdapter(this._manager);

  final OZMultiSignerManager _manager;

  @override
  Future<OZTransactionResult> multiSignerContractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
    required List<OZSelectedSigner> selectedSigners,
  }) {
    return _manager.multiSignerContractCall(
      target: target,
      targetFn: targetFn,
      targetArgs: targetArgs,
      selectedSigners: selectedSigners,
    );
  }
}

// ---------------------------------------------------------------------------
// AllowanceFetcherType
// ---------------------------------------------------------------------------

/// Abstraction over the read-only `allowance(from, spender)` simulation used
/// by [ApproveFlow.fetchAllowance].
///
/// The production adapter performs a Soroban simulation against the live
/// [SorobanServer]; tests inject a mock that returns canned amounts so the
/// background fetch can be exercised deterministically.
abstract interface class AllowanceFetcherType {
  /// Returns the current allowance in stroops, or null when the simulation
  /// fails or the result cannot be decoded.
  Future<BigInt?> fetchAllowance({
    required String tokenContract,
    required String fromAddress,
    required String spenderAddress,
  });
}

// ---------------------------------------------------------------------------
// ApproveFlow
// ---------------------------------------------------------------------------

/// Business logic for the Approve screen.
///
/// Construct once per screen instance, passing the Riverpod notifiers and
/// SDK adapters as direct dependencies. The [ApproveScreen] holds one
/// [ApproveFlow] for its lifetime.
///
/// Thread safety:
/// All public methods are `async`. [_isApproving] guards against concurrent
/// in-flight calls. The screen's [LoadingButton] provides the primary
/// re-entrancy guard; this flag is an additional safeguard for callers
/// outside the button.
final class ApproveFlow {
  /// Constructs a flow with injected dependencies.
  ///
  /// [demoState] and [activityLog] are the Riverpod notifiers.
  /// [contractCall] is the SDK adapter for single-signer approve.
  /// [multiSignerContractCall] is the SDK adapter for multi-signer approve.
  /// [allowanceFetcher] is the read-only simulation adapter, when null the
  /// allowance row stays at "Loading..." indefinitely; callers must supply
  /// the production adapter or a test double.
  /// [contextRuleFlow] is reused for [resolveAbsoluteLedger] so the flow
  /// shares a single source of truth for ledger-offset → absolute conversion.
  ApproveFlow({
    required DemoStateNotifier demoState,
    required ActivityLogNotifier activityLog,
    required ContractCallType contractCall,
    required MultiSignerContractCallType multiSignerContractCall,
    required ContextRuleFlow contextRuleFlow,
    required AllowanceFetcherType allowanceFetcher,
  })  : _demoState = demoState,
        _activityLog = activityLog,
        _contractCall = contractCall,
        _multiSignerContractCall = multiSignerContractCall,
        _contextRuleFlow = contextRuleFlow,
        _allowanceFetcher = allowanceFetcher;

  final DemoStateNotifier _demoState;
  final ActivityLogNotifier _activityLog;
  final ContractCallType _contractCall;
  final MultiSignerContractCallType _multiSignerContractCall;
  final ContextRuleFlow _contextRuleFlow;
  final AllowanceFetcherType _allowanceFetcher;

  // ---- Re-entrancy guard ----

  /// True while an approve call is executing.
  bool _isApproving = false;

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
  // Public: registerEd25519ViaAdapter
  // -------------------------------------------------------------------------

  /// Registers Ed25519 signing secrets on the kit's [DemoEd25519Adapter].
  ///
  /// Calls [DemoEd25519Adapter.add] for each entry in [ed25519Secrets].
  /// The secrets are held by the adapter, not the SDK manager's in-process
  /// registry. The SDK pipeline consults the adapter (via [canSignFor])
  /// ahead of the in-process registry, so these keys resolve through the
  /// adapter path.
  ///
  /// No-ops silently when the adapter is not initialised. On any [add]
  /// failure the adapter is fully cleared before rethrowing so it is
  /// never left in a partial state.
  void registerEd25519ViaAdapter(
    Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
  ) {
    final adapter = _demoState.ed25519Adapter;
    if (adapter == null) return;

    try {
      for (final entry in ed25519Secrets.entries) {
        adapter.add(entry.key, entry.value);
      }
    } catch (e) {
      adapter.clearAll();
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Public: clearDelegatedKeypairs / withCleanupOfDelegatedKeypairs
  // -------------------------------------------------------------------------

  /// Removes every signer the flow registered on the kit-owned manager and
  /// clears any secrets held by the Ed25519 adapter.
  ///
  /// Calls [OZExternalSignerManager.removeAll], which clears all in-memory
  /// keypair and Ed25519 signers, disconnects every external wallet
  /// connection, and clears the persisted wallet connections from storage.
  /// The Ed25519 adapter holds its own secrets outside the manager, so it is
  /// cleared separately via [DemoEd25519Adapter.clearAll].
  ///
  /// No-ops silently when neither the kit nor the adapter is initialised.
  Future<void> clearDelegatedKeypairs() async {
    await _demoState.externalSigners?.removeAll();
    _demoState.ed25519Adapter?.clearAll();
  }

  /// Runs [body] and guarantees [clearDelegatedKeypairs] is called even if
  /// [body] throws. Failures from [clearDelegatedKeypairs] are swallowed so
  /// the cleanup never masks an in-flight error from [body].
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
  /// and the Ed25519 secrets on the [DemoEd25519Adapter] via
  /// [registerEd25519ViaAdapter] (the adapter custody path), then runs [body]
  /// and returns its value. Both registrations run inside the guarded region so
  /// a failure during Ed25519 registration still clears the delegated keypairs
  /// that were registered first; nothing leaks on success, failure, or
  /// cancellation.
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
      registerEd25519ViaAdapter(ed25519Secrets);
      return body();
    });
  }

  // -------------------------------------------------------------------------
  // Public: approveAllowance (single-signer)
  // -------------------------------------------------------------------------

  /// Submits an `approve(from, spender, amount, expiration)` call on
  /// [tokenContract] using the connected passkey (single-signer path).
  ///
  /// [amount] is a human-readable decimal string already validated against
  /// [validateAmount]. [expirationLedgerOffset] is the number of ledgers
  /// from now at which the allowance expires; the absolute ledger is
  /// resolved via [ContextRuleFlow.resolveAbsoluteLedger].
  ///
  /// Returns an [ApproveResult]. On failure, [ApproveResult.error] is
  /// already sanitised and safe to display verbatim.
  Future<ApproveResult> approveAllowance({
    required String tokenContract,
    required String spenderAddress,
    required String amount,
    required int expirationLedgerOffset,
  }) async {
    if (_isApproving) {
      throw StateError('An approve is already in progress.');
    }
    _isApproving = true;

    try {
      _activityLog.info(
        'Approving $amount DEMO for ${truncateAddress(spenderAddress)}',
      );

      final args = await _buildApproveArgs(
        spenderAddress: spenderAddress,
        amount: amount,
        expirationLedgerOffset: expirationLedgerOffset,
      );
      if (args == null) {
        return const ApproveResult(
          success: false,
          error: 'No wallet connected.',
        );
      }

      final OZTransactionResult result;
      try {
        result = await _contractCall.contractCall(
          target: tokenContract,
          targetFn: 'approve',
          targetArgs: args,
        );
      } on WebAuthnCancelled {
        _activityLog.info('Passkey authentication cancelled');
        return const ApproveResult(
          success: false,
          error: 'Passkey authentication cancelled',
        );
      } catch (e) {
        final classified = classifyError(e);
        _activityLog.error('Approve failed: ${classified.message}');
        return ApproveResult(success: false, error: classified.message);
      }

      if (!result.success) {
        final message = 'Approve failed: ${result.error ?? "Unknown error"}';
        _activityLog.error(message);
        return ApproveResult(success: false, error: message);
      }

      final hash = result.hash ?? '';
      _activityLog.success(
        'Approve successful! Hash: $hash',
      );
      return ApproveResult(success: true, hash: hash);
    } finally {
      _isApproving = false;
    }
  }

  // -------------------------------------------------------------------------
  // Public: multiSignerApproveAllowance
  // -------------------------------------------------------------------------

  /// Submits an `approve(from, spender, amount, expiration)` call signed by
  /// the explicit [selectedSigners] list (multi-signer path).
  ///
  /// The caller must invoke [registerDelegatedKeypairs] and
  /// [registerEd25519ViaAdapter] before calling this method. Delegated
  /// keypairs are registered on the kit-owned manager; Ed25519 secrets are
  /// registered on the adapter so they route through the adapter custody path.
  ///
  /// Returns an [ApproveResult]. On failure, [ApproveResult.error] is
  /// already sanitised and safe to display verbatim.
  Future<ApproveResult> multiSignerApproveAllowance({
    required String tokenContract,
    required String spenderAddress,
    required String amount,
    required int expirationLedgerOffset,
    required List<OZSelectedSigner> selectedSigners,
  }) async {
    if (_isApproving) {
      throw StateError('An approve is already in progress.');
    }
    _isApproving = true;

    try {
      _activityLog.info(
        'Multi-signer approve: $amount DEMO for '
        '${truncateAddress(spenderAddress)} '
        '(${selectedSigners.length} signer(s))',
      );

      final args = await _buildApproveArgs(
        spenderAddress: spenderAddress,
        amount: amount,
        expirationLedgerOffset: expirationLedgerOffset,
      );
      if (args == null) {
        return const ApproveResult(
          success: false,
          error: 'No wallet connected.',
        );
      }

      final OZTransactionResult result;
      try {
        result = await _multiSignerContractCall.multiSignerContractCall(
          target: tokenContract,
          targetFn: 'approve',
          targetArgs: args,
          selectedSigners: selectedSigners,
        );
      } on WebAuthnCancelled {
        _activityLog.info('Passkey authentication cancelled');
        return const ApproveResult(
          success: false,
          error: 'Passkey authentication cancelled',
        );
      } catch (e) {
        final classified = classifyError(e);
        _activityLog.error(
          'Multi-signer approve failed: ${classified.message}',
        );
        return ApproveResult(success: false, error: classified.message);
      }

      if (!result.success) {
        final message =
            'Multi-signer approve failed: ${result.error ?? "Unknown error"}';
        _activityLog.error(message);
        return ApproveResult(success: false, error: message);
      }

      final hash = result.hash ?? '';
      _activityLog.success(
        'Multi-signer approve successful! Hash: $hash',
      );
      return ApproveResult(success: true, hash: hash);
    } finally {
      _isApproving = false;
    }
  }

  // -------------------------------------------------------------------------
  // Public: fetchAllowance
  // -------------------------------------------------------------------------

  /// Reads the current allowance granted to [spenderAddress] on
  /// [tokenContract] from the connected smart account.
  ///
  /// Performs a fixed 5-second delay before the simulation so the ledger
  /// state catches up with a recent approve transaction (the result card
  /// triggers this fetch right after a successful approve). Returns the
  /// formatted decimal display string ("100.0") or null on any failure —
  /// allowance fetching is purely cosmetic and must never surface an error
  /// to the user.
  Future<String?> fetchAllowance({
    required String tokenContract,
    required String spenderAddress,
  }) async {
    final smartAccount = _demoState.currentState.contractId;
    if (smartAccount == null) return null;

    // Wait for ledger state to propagate after the approve transaction.
    await Future<void>.delayed(const Duration(seconds: 5));

    try {
      final stroops = await _allowanceFetcher.fetchAllowance(
        tokenContract: tokenContract,
        fromAddress: smartAccount,
        spenderAddress: spenderAddress,
      );
      if (stroops == null) return null;
      return formatStroopsBigIntAsXlm(stroops);
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Public: validateSpender
  // -------------------------------------------------------------------------

  /// Validates [value] as a Stellar G-address or C-address.
  ///
  /// Returns null when the field is empty (so the form is not flagged on
  /// initial render). Returns the validation error string when [value] is a
  /// non-empty, non-address string.
  String? validateSpender(String value) {
    if (value.isEmpty) return null;
    if (!StrKey.isValidStellarAccountId(value) &&
        !StrKey.isValidContractId(value)) {
      return 'Must be a valid Stellar account (G...) or contract (C...) address';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Public: validateAmount
  // -------------------------------------------------------------------------

  /// Validates [value] against the amount rules.
  ///
  /// Returns null when the field is empty (so the form is not flagged on
  /// initial render). Otherwise returns one of the validation error strings
  /// when the value fails parsing, exceeds 7-decimal precision, or is not
  /// positive.
  static String? validateAmount(String value) {
    if (value.isEmpty) return null;
    if (value.toLowerCase().contains('e')) {
      return 'Scientific notation is not supported';
    }
    if (!stellarDecimalAmountPattern.hasMatch(value)) {
      return 'Must be a valid number';
    }
    final parsed = double.tryParse(value);
    if (parsed == null) {
      return 'Must be a valid number';
    }
    if (parsed <= 0) {
      return 'Must be greater than zero';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Builds the `approve` argument vector
  /// `[from, spender, amount as i128, expiration as u32]`.
  ///
  /// Returns null when the wallet is not connected so callers can short-
  /// circuit with a clear error rather than constructing an invalid call.
  Future<List<XdrSCVal>?> _buildApproveArgs({
    required String spenderAddress,
    required String amount,
    required int expirationLedgerOffset,
  }) async {
    final smartAccount = _demoState.currentState.contractId;
    if (smartAccount == null) return null;

    final stroops = Util.toXdrInt64Amount(amount);
    final spenderScVal = _addressScVal(spenderAddress);

    // Resolve the offset → absolute ledger sequence. The screen layer
    // guarantees offset > 0 (dropdown enforces it) so the result is always
    // a non-null absolute ledger; default to 0 only as a defensive fallback.
    final absolute =
        await _contextRuleFlow.resolveAbsoluteLedger(expirationLedgerOffset) ??
            0;

    return <XdrSCVal>[
      XdrSCVal.forAddress(Address.forContractId(smartAccount).toXdr()),
      spenderScVal,
      Util.stroopsToI128ScVal(stroops),
      XdrSCVal.forU32(absolute),
    ];
  }

  /// Encodes a Stellar G- or C-address as an `Address` SCVal.
  ///
  /// Mirrors the SDK helper used by [OZMultiSignerManager.multiSignerTransfer].
  XdrSCVal _addressScVal(String address) {
    if (StrKey.isValidContractId(address)) {
      return XdrSCVal.forAddress(Address.forContractId(address).toXdr());
    }
    return XdrSCVal.forAddress(Address.forAccountId(address).toXdr());
  }
}

// ---------------------------------------------------------------------------
// AllowanceFetcherAdapter — production simulation-based allowance reader
// ---------------------------------------------------------------------------

/// Production [AllowanceFetcherType] backed by [SorobanServer] simulation.
///
/// Builds an envelope that invokes `allowance(from, spender)` on the token
/// contract, simulates it against the configured RPC, and decodes the i128
/// result into a stroop [BigInt]. Returns null on any failure path so the
/// screen can render "Unable to fetch" without raising an exception.
///
/// A short-lived [SorobanServer] is created from [rpcUrl] for each fetch and
/// closed in a `finally` block so the connection is always released.
final class AllowanceFetcherAdapter implements AllowanceFetcherType {
  /// Constructs the adapter with the Soroban RPC endpoint.
  const AllowanceFetcherAdapter({required String rpcUrl}) : _rpcUrl = rpcUrl;

  final String _rpcUrl;

  @override
  Future<BigInt?> fetchAllowance({
    required String tokenContract,
    required String fromAddress,
    required String spenderAddress,
  }) async {
    final server = SorobanServer(_rpcUrl);
    try {
      final transaction = _buildAllowanceTransaction(
        tokenContract: tokenContract,
        fromAddress: fromAddress,
        spenderAddress: spenderAddress,
      );

      final simulation = await server.simulateTransaction(
        SimulateTransactionRequest(transaction),
      );
      if (simulation.isErrorResponse) return null;

      final results = simulation.results;
      if (results == null || results.isEmpty) return null;
      final scVal = results.first.resultValue;
      if (scVal == null) return null;

      return _extractI128AsBigInt(scVal);
    } catch (_) {
      return null;
    } finally {
      server.close();
    }
  }

  Transaction _buildAllowanceTransaction({
    required String tokenContract,
    required String fromAddress,
    required String spenderAddress,
  }) {
    final fromScVal = _addressScVal(fromAddress);
    final spenderScVal = _addressScVal(spenderAddress);

    final invokeContractArgs = XdrInvokeContractArgs(
      Address.forContractId(tokenContract).toXdr(),
      'allowance',
      <XdrSCVal>[fromScVal, spenderScVal],
    );
    final hostFunction = XdrHostFunction.forInvokingContractWithArgs(
      invokeContractArgs,
    );
    final operation = InvokeHostFunctionOperation(
      HostFunction.fromXdr(hostFunction),
      auth: const <SorobanAuthorizationEntry>[],
    );

    final sourceAccount =
        Account.fromAccountId(DemoTokenService.adminAddress(), BigInt.zero);

    return TransactionBuilder(sourceAccount)
        .setMaxOperationFee(AbstractTransaction.MIN_BASE_FEE)
        .addOperation(operation)
        .addMemo(Memo.none())
        .build();
  }

  XdrSCVal _addressScVal(String address) {
    if (StrKey.isValidContractId(address)) {
      return XdrSCVal.forAddress(Address.forContractId(address).toXdr());
    }
    return XdrSCVal.forAddress(Address.forAccountId(address).toXdr());
  }

  /// Decodes an i128 [XdrSCVal] as a signed 128-bit [BigInt].
  ///
  /// Returns null when [scVal] is not an i128. The math reconstructs the
  /// signed 128-bit value from the (hi, lo) XDR limbs without truncating
  /// to a 64-bit integer so any legitimate allowance amount is preserved.
  BigInt? _extractI128AsBigInt(XdrSCVal scVal) {
    final i128 = scVal.i128;
    if (i128 == null) return null;
    final hi = i128.hi.int64;
    final lo = i128.lo.uint64;
    final shifted = hi << 64;
    return shifted + lo;
  }
}
