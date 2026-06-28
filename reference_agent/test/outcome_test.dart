// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  group('ContractErrorClassifier', () {
    test('parses the contract error code from a HostError message', () {
      expect(
        ContractErrorClassifier.parseContractErrorCode(
          'HostError: Error(Contract, #3016)',
        ),
        3016,
      );
    });

    test('returns null when no contract code is present', () {
      expect(
        ContractErrorClassifier.parseContractErrorCode('network unreachable'),
        isNull,
      );
    });

    test('maps known OZContractErrorCodes constants to names', () {
      expect(
        ContractErrorClassifier.nameForCode(
          OZContractErrorCodes.unauthorizedSigner,
        ),
        'unauthorizedSigner',
      );
      expect(ContractErrorClassifier.nameForCode(3013), 'keyDataTooLarge');
      expect(ContractErrorClassifier.nameForCode(9999), isNull);
    });
  });

  group('classifyResult', () {
    test('success yields CallSucceeded with the hash', () {
      final outcome = classifyResult(
        const OZTransactionResult(success: true, hash: 'HASH'),
      );
      expect(outcome, isA<CallSucceeded>());
      expect((outcome as CallSucceeded).hash, 'HASH');
    });

    test('contract-code failure yields CallRejected', () {
      final outcome = classifyResult(
        const OZTransactionResult(
          success: false,
          error: 'Error(Contract, #3016)',
        ),
      );
      expect(outcome, isA<CallRejected>());
      final rejected = outcome as CallRejected;
      expect(rejected.errorCode, 3016);
      expect(rejected.errorName, 'unauthorizedSigner');
    });

    test('non-contract failure yields CallFailed', () {
      final outcome = classifyResult(
        const OZTransactionResult(success: false, error: 'timeout'),
      );
      expect(outcome, isA<CallFailed>());
      expect((outcome as CallFailed).message, 'timeout');
    });

    test('unknown contract code yields CallRejected with a null name', () {
      final outcome = classifyResult(
        const OZTransactionResult(
          success: false,
          error: 'Error(Contract, #4242)',
        ),
      );
      expect(outcome, isA<CallRejected>());
      final rejected = outcome as CallRejected;
      expect(rejected.errorCode, 4242);
      expect(rejected.errorName, isNull);
    });
  });

  group('classifyError', () {
    test('SmartAccountException with a contract code yields CallRejected', () {
      final outcome = classifyError(
        SmartAccountTransactionException.simulationFailed(
          'Simulation error: Error(Contract, #3016)',
        ),
      );
      expect(outcome, isA<CallRejected>());
      expect((outcome as CallRejected).errorCode, 3016);
    });

    test('generic exception without a code yields CallFailed', () {
      final outcome = classifyError(StateError('boom'));
      expect(outcome, isA<CallFailed>());
      expect((outcome as CallFailed).message, contains('boom'));
    });
  });
}
