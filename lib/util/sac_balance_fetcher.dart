/// SAC token balance fetcher.
///
/// Invokes `balance(id:)` on a Stellar Asset Contract (SAC) token contract
/// via simulation and returns the result as a [BigInt] stroop amount.
///
/// Simulation only — no on-chain transaction is submitted. A canonical
/// well-known testnet source account is used as the simulation envelope
/// source; the RPC does not validate on-chain sequence numbers or balances
/// for simulation calls.
///
/// Both [MainScreenFlow.refreshBalances] and post-creation balance refresh
/// route through this helper so the encoding and decoding logic is
/// maintained in exactly one place.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../token/demo_token_service.dart';

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/// Error category for a balance-fetch failure.
enum SACBalanceFetcherErrorKind {
  /// The Soroban RPC simulation call returned an error response.
  simulationFailed,

  /// The simulation returned a type that is not an i128 balance.
  unexpectedReturnType,
}

/// Typed error thrown by [SACBalanceFetcher.fetchBalance].
///
/// Caught by callers that want structured error reporting (e.g. logging the
/// category and reason separately). [message] is always safe to surface in
/// the activity log — it contains no raw XDR or signing payloads.
final class SACBalanceFetcherError implements Exception {
  /// Constructs a balance-fetch error.
  const SACBalanceFetcherError({required this.kind, required this.message});

  /// Machine-readable category used to choose the log level.
  final SACBalanceFetcherErrorKind kind;

  /// Human-readable description suitable for the activity log.
  final String message;

  @override
  String toString() => 'SACBalanceFetcherError(${kind.name}): $message';
}

// ---------------------------------------------------------------------------
// SACBalanceFetcher
// ---------------------------------------------------------------------------

/// Invokes `balance(id: <account>)` on a SAC token contract and returns the
/// result as a [BigInt] stroop amount.
///
/// The on-chain balance type is i128, so [BigInt] is used end-to-end to
/// preserve the full range losslessly across native and web targets. Pair
/// with [formatStroopsBigIntAsXlm] to render the value as a display string.
///
/// Usage:
/// ```dart
/// final stroops = await SACBalanceFetcher.fetchBalance(
///   contract: nativeTokenContract,
///   account: connectedContractId,
///   kit: kit,
/// );
/// ```
abstract final class SACBalanceFetcher {
  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Fetches the SAC `balance(id: <account>)` for the given [contract] and
  /// [account].
  ///
  /// Simulation is performed via [kit.sorobanServer]. The time bounds on the
  /// simulation envelope use [kit.config.timeoutInSeconds] so the envelope
  /// remains valid for the same window used by all other kit operations.
  ///
  /// - Returns the balance as a [BigInt] in stroops (i128 range).
  /// - Throws [SACBalanceFetcherError] on simulation failure or unexpected
  ///   return type.
  static Future<BigInt> fetchBalance({
    required String contract,
    required String account,
    required OZSmartAccountKit kit,
  }) async {
    final transaction = _buildBalanceTransaction(
      contractAddress: contract,
      accountAddress: account,
      kit: kit,
    );
    final simulation = await _simulate(transaction: transaction, kit: kit);
    return _decodeI128Result(simulation);
  }

  // -------------------------------------------------------------------------
  // Private: transaction construction
  // -------------------------------------------------------------------------

  /// Constructs an [InvokeHostFunctionOperation] transaction that calls
  /// `balance(id:)` on a SAC token contract.
  ///
  /// The `id` argument is a `contract`-variant [XdrSCVal] wrapping the smart
  /// account's C-strkey. Time bounds are derived from
  /// [kit.config.timeoutInSeconds] to match the timeout window the kit uses
  /// for its own submissions.
  static Transaction _buildBalanceTransaction({
    required String contractAddress,
    required String accountAddress,
    required OZSmartAccountKit kit,
  }) {
    final addressArg = XdrSCVal.forContractAddress(accountAddress);

    final invokeContractArgs = XdrInvokeContractArgs(
      Address.forContractId(contractAddress).toXdr(),
      'balance',
      <XdrSCVal>[addressArg],
    );
    final hostFunction = XdrHostFunction.forInvokingContractWithArgs(
      invokeContractArgs,
    );
    final operation = InvokeHostFunctionOperation(
      HostFunction.fromXdr(hostFunction),
      auth: const <SorobanAuthorizationEntry>[],
    );

    final sourceAccount = Account.fromAccountId(
      DemoTokenService.adminAddress(),
      BigInt.zero,
    );

    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timeBounds = TimeBounds(
      0,
      nowSeconds + kit.config.timeoutInSeconds,
    );
    final preconditions = TransactionPreconditions()
      ..timeBounds = timeBounds;

    return TransactionBuilder(sourceAccount)
        .setMaxOperationFee(AbstractTransaction.MIN_BASE_FEE)
        .addOperation(operation)
        .addMemo(Memo.none())
        .addPreconditions(preconditions)
        .build();
  }

  // -------------------------------------------------------------------------
  // Private: simulation
  // -------------------------------------------------------------------------

  /// Sends the transaction to the Soroban RPC simulation endpoint and returns
  /// the unwrapped success result.
  ///
  /// Throws [SACBalanceFetcherError] with [SACBalanceFetcherErrorKind.simulationFailed]
  /// on any RPC or contract error.
  static Future<SimulateTransactionResponse> _simulate({
    required Transaction transaction,
    required OZSmartAccountKit kit,
  }) async {
    final SimulateTransactionResponse simulation;
    try {
      simulation = await kit.sorobanServer.simulateTransaction(
        SimulateTransactionRequest(transaction),
      );
    } catch (e) {
      throw SACBalanceFetcherError(
        kind: SACBalanceFetcherErrorKind.simulationFailed,
        message: 'RPC request failed: $e',
      );
    }

    if (simulation.isErrorResponse) {
      final reason = simulation.error?.message ?? 'unknown RPC error';
      throw SACBalanceFetcherError(
        kind: SACBalanceFetcherErrorKind.simulationFailed,
        message: 'Simulation returned an error: $reason',
      );
    }

    return simulation;
  }

  // -------------------------------------------------------------------------
  // Private: i128 decoding
  // -------------------------------------------------------------------------

  /// Extracts a [BigInt] stroop amount from the first result of a SAC
  /// `balance` simulation response.
  ///
  /// An empty result set is treated as a contract or RPC anomaly, not a
  /// valid zero balance. [SACBalanceFetcherError] with
  /// [SACBalanceFetcherErrorKind.unexpectedReturnType] is thrown so callers
  /// can distinguish "balance is zero" from "no result returned".
  ///
  /// Throws [SACBalanceFetcherError] when the result set is empty, the result
  /// value is null, or the SCVal is not an i128.
  static BigInt _decodeI128Result(SimulateTransactionResponse simulation) {
    final results = simulation.results;
    if (results == null || results.isEmpty) {
      throw const SACBalanceFetcherError(
        kind: SACBalanceFetcherErrorKind.unexpectedReturnType,
        message: 'Simulation returned no results — expected an i128 balance',
      );
    }
    final resultValue = results.first.resultValue;
    if (resultValue == null) {
      throw const SACBalanceFetcherError(
        kind: SACBalanceFetcherErrorKind.unexpectedReturnType,
        message: 'Could not decode SCVal from simulation result',
      );
    }
    return extractI128AsBigInt(resultValue);
  }

  /// Decodes an i128 [XdrSCVal] into a [BigInt] losslessly.
  ///
  /// Reconstructs the 128-bit signed value as `(hi << 64) + lo`, preserving
  /// the full i128 range on every supported platform. The result is a true
  /// [BigInt] — no fixed-width narrowing or sentinel substitution.
  ///
  /// Throws [SACBalanceFetcherError] when [scVal] is not an i128.
  static BigInt extractI128AsBigInt(XdrSCVal scVal) {
    final i128 = scVal.i128;
    if (i128 == null) {
      throw SACBalanceFetcherError(
        kind: SACBalanceFetcherErrorKind.unexpectedReturnType,
        message:
            'Expected i128 SCVal, got discriminant ${scVal.discriminant.value}',
      );
    }
    final hi = i128.hi.int64;
    final lo = i128.lo.uint64;
    return (hi << 64) + lo;
  }
}
