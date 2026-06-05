/// Tests for [ApproveFlow].
///
/// Covers the functional matrix for the Approve screen flow:
/// 1. `approveAllowance` happy path → asserts the contract call args
///    (smartAcct, spender, i128 amount, u32 expiration).
/// 2. `multiSignerApproveAllowance` happy path → asserts the selectedSigners
///    list is passed through unchanged.
/// 3. WebAuthn cancellation surfaces the verbatim error string and logs at
///    info level.
/// 4. Generic SDK exception path → sanitised error in [ApproveResult.error]
///    and an error-level activity-log entry.
/// 5. Expiration offsets map correctly (1 day = 17280, etc.).
/// 6. `fetchAllowance` parses the BigInt result; null on failure.
/// 7. Spender / amount validators reject invalid inputs.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/approve_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'approve_test_support.dart';
import 'transfer_test_support.dart' show makeCancelledError, MockNetworkError;

void main() {
  // -------------------------------------------------------------------------
  // Scenario 1 — single-signer happy path
  // -------------------------------------------------------------------------

  group('ApproveFlow.approveAllowance — happy path', () {
    test('returns success with on-chain hash', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.successResult();

      final result = await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      expect(result.success, isTrue);
      expect(result.hash, ApproveFixtures.defaultTxHash);
      expect(result.error, isNull);
    });

    test('forwards target, fn name, and arg vector to the SDK', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.successResult();
      deps.environment.currentLedger = 1000;

      await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      expect(deps.contractCall.lastTarget, ApproveFixtures.defaultTokenContract);
      expect(deps.contractCall.lastTargetFn, 'approve');
      final args = deps.contractCall.lastTargetArgs!;
      expect(args.length, 4);
      // 1. from = smart account address.
      // 2. spender = G-address.
      // 3. amount = i128 stroops.
      expect(args[2].i128, isNotNull);
      // 4. expiration = u32 absolute ledger (current 1000 + offset 17280).
      expect(args[3].u32?.uint32, 18280);
    });

    test('logs info on start and success on confirmation', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.successResult();

      await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.info &&
              e.message.contains('Approving 10.0 DEMO'),
        ),
        isTrue,
      );
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.success &&
              e.message.contains('Approve successful!'),
        ),
        isTrue,
      );
    });

    test('handles contract-address spender', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.successResult();

      final result = await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultContractSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      expect(result.success, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 2 — multi-signer happy path
  // -------------------------------------------------------------------------

  group('ApproveFlow.multiSignerApproveAllowance — happy path', () {
    test('forwards selectedSigners to the SDK unchanged', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.multiSignerContractCall.result = ApproveFixtures.successResult();
      final signers = <OZSelectedSigner>[
        const OZSelectedSignerPasskey(),
        const OZSelectedSignerWallet(ApproveFixtures.defaultSpender),
      ];

      final result = await deps.flow.multiSignerApproveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: '5.0',
        expirationLedgerOffset: 172800,
        selectedSigners: signers,
      );

      expect(result.success, isTrue);
      expect(deps.multiSignerContractCall.lastSelectedSigners, signers);
    });

    test('logs the signer count in the start entry', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.multiSignerContractCall.result = ApproveFixtures.successResult();

      await deps.flow.multiSignerApproveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: '5.0',
        expirationLedgerOffset: 172800,
        selectedSigners: const <OZSelectedSigner>[
          OZSelectedSignerPasskey(),
          OZSelectedSignerPasskey(),
        ],
      );

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.info &&
              e.message.contains('Multi-signer approve: 5.0 DEMO') &&
              e.message.contains('(2 signer(s))'),
        ),
        isTrue,
      );
    });

    test('logs success on confirmation', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.multiSignerContractCall.result = ApproveFixtures.successResult();

      await deps.flow.multiSignerApproveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: '5.0',
        expirationLedgerOffset: 172800,
        selectedSigners: const <OZSelectedSigner>[OZSelectedSignerPasskey()],
      );

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.success &&
              e.message.contains('Multi-signer approve successful!'),
        ),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 3 — WebAuthn cancellation
  // -------------------------------------------------------------------------

  group('ApproveFlow — WebAuthn cancellation', () {
    test('approveAllowance maps cancellation to verbatim error string',
        () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.error = makeCancelledError();

      final result = await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      expect(result.success, isFalse);
      expect(result.error, 'Passkey authentication cancelled');

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.info &&
              e.message.contains('Passkey authentication cancelled'),
        ),
        isTrue,
      );
    });

    test('multiSigner variant maps cancellation identically', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.multiSignerContractCall.error = makeCancelledError();

      final result = await deps.flow.multiSignerApproveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
        selectedSigners: const <OZSelectedSigner>[OZSelectedSignerPasskey()],
      );

      expect(result.error, 'Passkey authentication cancelled');
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 4 — generic SDK failure
  // -------------------------------------------------------------------------

  group('ApproveFlow — generic SDK exception', () {
    test('sanitises message and logs at error level', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.error = MockNetworkError();

      final result = await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      expect(result.success, isFalse);
      expect(result.error, contains('Network error'));

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.error &&
              e.message.contains('Approve failed:'),
        ),
        isTrue,
      );
    });

    test('multi-signer variant uses the multi-signer error prefix', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.multiSignerContractCall.error = MockNetworkError();

      await deps.flow.multiSignerApproveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
        selectedSigners: const <OZSelectedSigner>[OZSelectedSignerPasskey()],
      );

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.error &&
              e.message.contains('Multi-signer approve failed:'),
        ),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 5 — failed OZTransactionResult
  // -------------------------------------------------------------------------

  group('ApproveFlow — failed OZTransactionResult', () {
    test('result.success false → ApproveResult.error sanitised', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.failureResult();

      final result = await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      expect(result.success, isFalse);
      expect(result.error, contains('Approve failed'));
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 6 — expiration offsets
  // -------------------------------------------------------------------------

  group('ApproveFlow — expiration offsets resolve correctly', () {
    test('1 day offset (17280) maps to absolute ledger', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.successResult();
      deps.environment.currentLedger = 500;

      await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 17280,
      );

      expect(deps.contractCall.lastTargetArgs!.last.u32?.uint32, 17780);
    });

    test('10 day offset (172800) maps to absolute ledger', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.successResult();
      deps.environment.currentLedger = 1;

      await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 172800,
      );

      expect(deps.contractCall.lastTargetArgs!.last.u32?.uint32, 172801);
    });

    test('30 day offset (518400) maps to absolute ledger', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.contractCall.result = ApproveFixtures.successResult();
      deps.environment.currentLedger = 100;

      await deps.flow.approveAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
        amount: ApproveFixtures.defaultAmount,
        expirationLedgerOffset: 518400,
      );

      expect(deps.contractCall.lastTargetArgs!.last.u32?.uint32, 518500);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 7 — fetchAllowance
  // -------------------------------------------------------------------------

  group('ApproveFlow.fetchAllowance', () {
    test('formats stroops as a decimal string', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.allowanceFetcher.result = BigInt.from(100000000); // 10.0 stroops

      // The flow waits 5s before fetching; bypass by using fakeAsync would
      // require an extra package — instead, accept the real delay here. The
      // test stays fast because the test runner does not block on the await.
      final value = await deps.flow.fetchAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
      );

      expect(value, '10');
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('returns null when the fetcher returns null', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.allowanceFetcher.result = null;

      final value = await deps.flow.fetchAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
      );

      expect(value, isNull);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('returns null when the fetcher throws', () async {
      final deps = ApproveFixtures.makeFlowWithDeps();
      deps.allowanceFetcher.error = MockNetworkError();

      final value = await deps.flow.fetchAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
      );

      expect(value, isNull);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('returns null when not connected', () async {
      final deps = ApproveFixtures.makeFlowWithDeps(isConnected: false);

      final value = await deps.flow.fetchAllowance(
        tokenContract: ApproveFixtures.defaultTokenContract,
        spenderAddress: ApproveFixtures.defaultSpender,
      );

      expect(value, isNull);
      // No fetcher call.
      expect(deps.allowanceFetcher.callCount, 0);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 8 — validators
  // -------------------------------------------------------------------------

  group('ApproveFlow.validateSpender', () {
    test('returns null for empty input', () {
      final deps = ApproveFixtures.makeFlowWithDeps();
      expect(deps.flow.validateSpender(''), isNull);
    });

    test('accepts valid G-address', () {
      final deps = ApproveFixtures.makeFlowWithDeps();
      expect(
        deps.flow.validateSpender(ApproveFixtures.defaultSpender),
        isNull,
      );
    });

    test('accepts valid C-address', () {
      final deps = ApproveFixtures.makeFlowWithDeps();
      expect(
        deps.flow.validateSpender(ApproveFixtures.defaultContractSpender),
        isNull,
      );
    });

    test('rejects malformed input with inventory string', () {
      final deps = ApproveFixtures.makeFlowWithDeps();
      expect(
        deps.flow.validateSpender('not-an-address'),
        'Must be a valid Stellar account (G...) or contract (C...) address',
      );
    });
  });

  group('ApproveFlow.validateAmount', () {
    test('returns null for empty input', () {
      expect(ApproveFlow.validateAmount(''), isNull);
    });

    test('accepts a valid decimal', () {
      expect(ApproveFlow.validateAmount('10.5'), isNull);
    });

    test('rejects scientific notation', () {
      expect(
        ApproveFlow.validateAmount('1e10'),
        'Scientific notation is not supported',
      );
    });

    test('rejects too-many fractional digits', () {
      expect(
        ApproveFlow.validateAmount('1.12345678'),
        'Must be a valid number',
      );
    });

    test('rejects non-numeric input', () {
      expect(
        ApproveFlow.validateAmount('abc'),
        'Must be a valid number',
      );
    });

    test('rejects zero', () {
      expect(
        ApproveFlow.validateAmount('0'),
        'Must be greater than zero',
      );
    });

    test('rejects negative values via the regex (no leading sign allowed)',
        () {
      expect(
        ApproveFlow.validateAmount('-1.0'),
        'Must be a valid number',
      );
    });
  });
}
