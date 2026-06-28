// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// Classification of a single scoped contract-call attempt.
///
/// A call either confirmed on-chain ([CallSucceeded]), was rejected by the
/// smart-account contract with a parseable error code ([CallRejected]), or
/// failed for a non-contract reason such as a network error ([CallFailed]).
/// A [CallRejected] covers any parseable on-chain contract error code, which
/// the agent escalates for human review.
sealed class CallOutcome {
  const CallOutcome();
}

/// The scoped call confirmed on-chain.
final class CallSucceeded extends CallOutcome {
  /// Constructs a success outcome carrying the confirmed transaction [hash].
  const CallSucceeded({required this.hash});

  /// On-chain transaction hash.
  final String hash;

  @override
  String toString() => 'CallSucceeded(hash: $hash)';
}

/// The smart-account contract rejected the call with an on-chain error code.
///
/// [errorCode] is the integer extracted from the contract error in the failure
/// message (e.g. `Error(Contract, #3016)` yields `3016`). [errorName] is the
/// symbolic name when [errorCode] matches a known [OZContractErrorCodes]
/// constant, otherwise `null`.
final class CallRejected extends CallOutcome {
  /// Constructs a rejection outcome.
  const CallRejected({
    required this.errorCode,
    required this.rawMessage,
    this.errorName,
  });

  /// Integer contract error code parsed from the failure.
  final int errorCode;

  /// Symbolic name of [errorCode] from [OZContractErrorCodes], or `null` when
  /// the code is not one of the SDK's documented constants.
  final String? errorName;

  /// The raw failure message the code was parsed from.
  final String rawMessage;

  @override
  String toString() =>
      'CallRejected(code: $errorCode, name: ${errorName ?? '(unknown)'})';
}

/// The call failed for a reason other than a contract rejection (for example a
/// network or simulation error). The agent does not escalate these.
final class CallFailed extends CallOutcome {
  /// Constructs a non-contract failure outcome with a [message].
  const CallFailed({required this.message});

  /// Sanitised failure description.
  final String message;

  @override
  String toString() => 'CallFailed(message: $message)';
}

/// Maps and parses OpenZeppelin smart-account contract error codes.
abstract final class ContractErrorClassifier {
  /// Symbolic names for the [OZContractErrorCodes] constants the SDK documents.
  static const Map<int, String> knownCodes = <int, String>{
    OZContractErrorCodes.mathOverflow: 'mathOverflow',
    OZContractErrorCodes.keyDataTooLarge: 'keyDataTooLarge',
    OZContractErrorCodes.contextRuleIdsLengthMismatch:
        'contextRuleIdsLengthMismatch',
    OZContractErrorCodes.nameTooLong: 'nameTooLong',
    OZContractErrorCodes.unauthorizedSigner: 'unauthorizedSigner',
  };

  /// Matches `#<digits>` as it appears in `Error(Contract, #3016)`.
  static final RegExp _codePattern = RegExp(r'#(\d+)');

  /// Returns the integer contract error code embedded in [message], or `null`
  /// when no `#<digits>` token is present.
  static int? parseContractErrorCode(String message) {
    final match = _codePattern.firstMatch(message);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Returns the symbolic name for [code], or `null` when it is not a known
  /// [OZContractErrorCodes] constant.
  static String? nameForCode(int code) => knownCodes[code];

  /// Returns the message text of [error], preferring the SDK exception's own
  /// `message` over its `toString()`.
  static String messageOf(Object error) {
    if (error is SmartAccountException) return error.message;
    return error.toString();
  }
}

/// Classifies an [OZTransactionResult] returned by the multi-signer pipeline.
CallOutcome classifyResult(OZTransactionResult result) {
  if (result.success) {
    return CallSucceeded(hash: result.hash ?? '');
  }
  final message = result.error ?? 'Unknown submission error';
  return _classifyFailureMessage(message);
}

/// Classifies an exception thrown by the multi-signer pipeline.
CallOutcome classifyError(Object error) {
  return _classifyFailureMessage(ContractErrorClassifier.messageOf(error));
}

CallOutcome _classifyFailureMessage(String message) {
  final code = ContractErrorClassifier.parseContractErrorCode(message);
  if (code != null) {
    return CallRejected(
      errorCode: code,
      errorName: ContractErrorClassifier.nameForCode(code),
      rawMessage: message,
    );
  }
  return CallFailed(message: message);
}
