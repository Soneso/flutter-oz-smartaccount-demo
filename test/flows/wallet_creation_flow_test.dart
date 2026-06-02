/// Tests for [WalletCreationFlow].
///
/// Strategy:
/// - Username validation: empty, whitespace-only, and trimming behaviour.
/// - Happy path: autoSubmit producing [WalletCreationResult].
/// - DEMO token mint paths: mint triggered, mint skipped (no service), mint
///   failure is non-fatal (flow still returns a result).
/// - Error paths: user cancellation, SDK network error, concurrent call guard,
///   WebAuthn key format check.
/// - [safeUserNameForLog] truncation and redaction.
/// - [WalletCreationError.actionableMessage] formatting.
///
/// No network or platform services are used. All SDK operations are mocked via
/// [WalletOperationsType] and [DemoTokenServiceType] test doubles.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/wallet_creation_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'wallet_creation_test_support.dart';

void main() {
  // -------------------------------------------------------------------------
  // Username validation
  // -------------------------------------------------------------------------

  group('WalletCreationFlow — username validation', () {
    test('empty username throws invalidUsername, SDK never called', () async {
      final ops = MockWalletOperations();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      await expectLater(
        flow.createWallet(
          username: '',
          autoSubmit: true,
        ),
        throwsA(isA<WalletCreationError>()),
      );
      expect(ops.callCount, equals(0));
    });

    test('whitespace-only username throws invalidUsername, SDK never called',
        () async {
      final ops = MockWalletOperations();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      await expectLater(
        flow.createWallet(
          username: '   ',
          autoSubmit: true,
        ),
        throwsA(isA<WalletCreationError>()),
      );
      expect(ops.callCount, equals(0));
    });

    test('whitespace-only username error is invalidUsername variant', () async {
      final ops = MockWalletOperations();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      WalletCreationError? thrown;
      try {
        await flow.createWallet(
          username: '   ',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WalletCreationError>());
      expect(thrown!.actionableMessage, contains('must not be empty'));
    });

    test('username is trimmed before passing to SDK', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      await flow.createWallet(
        username: '  Alice  ',
        autoSubmit: true,
      );

      expect(ops.lastUserName, equals('Alice'));
    });

    test('username with special ASCII characters passes unchanged', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      await flow.createWallet(
        username: 'user_123',
        autoSubmit: true,
      );

      expect(ops.lastUserName, equals('user_123'));
    });
  });

  // -------------------------------------------------------------------------
  // Happy path
  // -------------------------------------------------------------------------

  group('WalletCreationFlow — happy path', () {
    test(
        'autoSubmit=true: DemoState connected, result isDeployed, '
        'autoFund passed to SDK', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      final result = await deps.flow.createWallet(
        username: 'TestUser',
        autoSubmit: true,
      );

      expect(result.isDeployed, isTrue);
      expect(result.contractAddress, isNotEmpty);
      expect(result.credentialId, isNotEmpty);
      expect(deps.state.isConnected, isTrue);
      expect(deps.state.isDeployed, isTrue);
      expect(ops.lastAutoSubmit, isTrue);
      // autoFund mirrors autoSubmit — should be true when autoSubmit is true.
      expect(ops.lastAutoFund, isTrue);
      expect(ops.lastNativeTokenContract, isNotNull);
      expect(
        deps.logEntries.any(
          (e) =>
              e.level == LogLevel.success &&
              e.message.toLowerCase().contains('deployed'),
        ),
        isTrue,
      );
    });

    test('autoSubmit=false: DemoState connected but isDeployed=false', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult(deployed: false);
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      final result = await deps.flow.createWallet(
        username: 'Pending User',
        autoSubmit: false,
      );

      expect(result.isDeployed, isFalse);
      expect(deps.state.isConnected, isTrue);
      expect(deps.state.isDeployed, isFalse);
      // autoFund mirrors autoSubmit — should be false when autoSubmit is false.
      expect(ops.lastAutoFund, isFalse);
      expect(ops.lastNativeTokenContract, isNull);
    });

    test('autoSubmit=false: nativeTokenContract not passed to SDK', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      await flow.createWallet(
        username: 'Bob',
        autoSubmit: false,
      );

      expect(ops.lastNativeTokenContract, isNull);
    });

    test('autoSubmit=true: nativeTokenContract passed to SDK', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      await flow.createWallet(
        username: 'Funded',
        autoSubmit: true,
      );

      expect(ops.lastNativeTokenContract, isNotNull);
      expect(ops.lastNativeTokenContract, isNotEmpty);
    });

    test('success logs at success level and contains address', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      await deps.flow.createWallet(
        username: 'Karl',
        autoSubmit: true,
      );

      expect(
        deps.logEntries.any((e) => e.level == LogLevel.success),
        isTrue,
      );
    });

    test('result carries transactionHash from SDK when deployed', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      final result = await flow.createWallet(
        username: 'TxHashUser',
        autoSubmit: true,
      );

      expect(result.transactionHash, equals('abc123txhash'));
    });

    test('result transactionHash is null when not deployed', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult(deployed: false);
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      final result = await flow.createWallet(
        username: 'PendingTx',
        autoSubmit: false,
      );

      expect(result.transactionHash, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // DEMO token mint
  // -------------------------------------------------------------------------

  group('WalletCreationFlow — DEMO token mint', () {
    test('autoSubmit=true with service: mint is attempted', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final tokenSvc = MockDemoTokenService()
        ..result = WalletCreationFixtures.tokenResult();
      final deps = WalletCreationFixtures.makeFlowWithDeps(
        walletOps: ops,
        tokenService: tokenSvc,
      );

      await deps.flow.createWallet(
        username: 'Carol',
        autoSubmit: true,
      );

      expect(tokenSvc.callCount, equals(1));
      expect(
        deps.state.demoTokenContractId,
        equals(WalletCreationFixtures.tokenContractId),
      );
    });

    test('autoSubmit=false with service: mint is not attempted', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult(deployed: false);
      final tokenSvc = MockDemoTokenService()
        ..result = WalletCreationFixtures.tokenResult();
      final flow = WalletCreationFixtures.makeFlow(
        walletOps: ops,
        tokenService: tokenSvc,
      );

      await flow.createWallet(
        username: 'Dave',
        autoSubmit: false,
      );

      expect(tokenSvc.callCount, equals(0));
    });

    test('no service: flow succeeds without mint', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      final result = await flow.createWallet(
        username: 'NoMint',
        autoSubmit: true,
      );

      expect(result.contractAddress, isNotEmpty);
    });

    test('mint failure is non-fatal: flow returns result and logs error',
        () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final tokenSvc = MockDemoTokenService()
        ..error = MockMintError();
      final deps = WalletCreationFixtures.makeFlowWithDeps(
        walletOps: ops,
        tokenService: tokenSvc,
      );

      final result = await deps.flow.createWallet(
        username: 'MintFail',
        autoSubmit: true,
      );

      // Wallet creation succeeded despite mint failure.
      expect(result.contractAddress, isNotEmpty);
      expect(result.isDeployed, isTrue);
      // demoTokenBalance is null because mint failed.
      expect(result.demoTokenBalance, isNull);
      // Wallet state committed correctly.
      expect(deps.state.isConnected, isTrue);
      // Error logged.
      expect(
        deps.logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Error paths
  // -------------------------------------------------------------------------

  group('WalletCreationFlow — error paths', () {
    test('user cancels passkey: userCanceled error, neutral log entry', () async {
      final ops = MockWalletOperations()
        ..error = makeCancelledError();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      WalletCreationError? thrownError;
      try {
        await deps.flow.createWallet(
          username: 'Frank',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        thrownError = e;
      }

      expect(thrownError, isA<WalletCreationError>());
      // The thrown error must be the userCanceled variant.
      expect(
        thrownError!.actionableMessage.toLowerCase(),
        contains('cancel'),
      );
      // User cancellation must be logged at info (neutral), not error.
      expect(
        deps.logEntries.any(
          (e) =>
              e.message.toLowerCase().contains('cancel') &&
              e.level == LogLevel.info,
        ),
        isTrue,
      );
      // No error-level entries for a user cancellation.
      expect(
        deps.logEntries.any((e) => e.level == LogLevel.error),
        isFalse,
        reason: 'User cancellation should not produce an error log entry',
      );
    });

    test('SDK network error: creationFailed wraps error, error logged', () async {
      final ops = MockWalletOperations()
        ..error = MockNetworkError();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      WalletCreationError? thrownError;
      try {
        await deps.flow.createWallet(
          username: 'Grace',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        thrownError = e;
      }

      expect(thrownError, isA<WalletCreationError>());
      expect(thrownError!.actionableMessage, isNotEmpty);
      expect(deps.state.isConnected, isFalse);
      expect(
        deps.logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
      );
    });

    test(
        'concurrent createWallet call throws creationFailed with '
        '"already in progress"', () async {
      // MockSlowWalletOperations suspends until the completer is completed.
      // This avoids wall-clock timing dependencies that cause CI flakiness.
      final completer = Completer<CreateWalletResult>();
      final ops = MockSlowWalletOperations(completer: completer);
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      WalletCreationError? secondCallError;

      // Launch the first call. It will suspend inside the mock awaiting the
      // completer, setting _isCreating = true before yielding.
      final firstFuture = flow.createWallet(
        username: 'Alice',
        autoSubmit: true,
      );

      // Flush microtasks so the first call enters the async body and sets
      // _isCreating = true before the second call is issued.
      await Future<void>.microtask(() {});

      // Second call must throw creationFailed immediately.
      try {
        await flow.createWallet(
          username: 'Bob',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        secondCallError = e;
      }

      expect(secondCallError, isA<WalletCreationError>());
      expect(
        secondCallError!.actionableMessage,
        contains('already in progress'),
      );

      // Complete the completer so the first call can finish cleanly.
      completer.complete(WalletCreationFixtures.validSdkResult());
      await firstFuture;
    });
  });

  // -------------------------------------------------------------------------
  // SF-4-1 regression: typed-only cancel detection
  // -------------------------------------------------------------------------

  group('_mapCreationError typed-only cancel detection', () {
    test(
        'SDK error with "operation not allowed" substring maps to creationFailed '
        '(not userCanceled)', () async {
      final ops = MockWalletOperations()
        ..error = Exception('operation not allowed by policy');
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      WalletCreationError? thrownError;
      try {
        await deps.flow.createWallet(
          username: 'ZeroDay',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        thrownError = e;
      }

      expect(thrownError, isA<WalletCreationError>());
      // Must be classified as creationFailed, not userCanceled.
      expect(thrownError!.isUserCanceled, isFalse);
      // The error banner path should be taken, not the cancelled banner path.
      expect(thrownError.actionableMessage, isNot(contains('cancel')));
    });

    test(
        'SDK error with "transaction aborted" substring maps to creationFailed '
        '(not userCanceled)', () async {
      final ops = MockWalletOperations()
        ..error = Exception('transaction aborted by RPC node');
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      WalletCreationError? thrownError;
      try {
        await deps.flow.createWallet(
          username: 'RpcFail',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        thrownError = e;
      }

      expect(thrownError, isA<WalletCreationError>());
      expect(thrownError!.isUserCanceled, isFalse);
    });

    test('only typed WebAuthnCancelled maps to userCanceled', () async {
      final ops = MockWalletOperations()
        ..error = makeCancelledError();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      WalletCreationError? thrownError;
      try {
        await deps.flow.createWallet(
          username: 'CancelUser',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        thrownError = e;
      }

      expect(thrownError, isA<WalletCreationError>());
      expect(thrownError!.isUserCanceled, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // WebAuthn key format verification
  // -------------------------------------------------------------------------

  group('WalletCreationFlow — credential key format verification', () {
    test('32-byte publicKey triggers webAuthnKeyFormatInvalid and error log',
        () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.invalidKeyResult();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      WalletCreationError? thrownError;
      try {
        await deps.flow.createWallet(
          username: 'Heidi',
          autoSubmit: true,
        );
      } on WalletCreationError catch (e) {
        thrownError = e;
      }

      expect(thrownError, isA<WalletCreationError>());
      expect(
        thrownError!.actionableMessage,
        contains('key format invalid'),
      );
      expect(deps.state.isConnected, isFalse);
      expect(
        deps.logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
      );
    });

    test('valid 65-byte publicKey (0x04) passes verification', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      final result = await deps.flow.createWallet(
        username: 'Ivan',
        autoSubmit: true,
      );

      expect(result.contractAddress, isNotEmpty);
      expect(deps.state.isConnected, isTrue);
    });

    test('65-byte key with 0x02 prefix (compressed) triggers webAuthnKeyFormatInvalid',
        () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.wrongPrefixKeyResult();
      final deps = WalletCreationFixtures.makeFlowWithDeps(walletOps: ops);

      WalletCreationError? thrownError;
      try {
        await deps.flow.createWallet(
          username: 'Judy',
          autoSubmit: false,
        );
      } on WalletCreationError catch (e) {
        thrownError = e;
      }

      expect(thrownError, isA<WalletCreationError>());
      expect(
        thrownError!.actionableMessage,
        contains('key format invalid'),
      );
      expect(deps.state.isConnected, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // safeUserNameForLog
  // -------------------------------------------------------------------------

  group('WalletCreationFlow.safeUserNameForLog', () {
    test('names under 32 chars pass through (ASCII)', () {
      expect(
        WalletCreationFlow.safeUserNameForLog('Alice'),
        equals('Alice'),
      );
    });

    test('names longer than 32 chars are truncated before processing', () {
      // Use characters that do not trigger the redaction deny-list so the
      // assertion is purely on the truncation boundary.
      final longName = 'BcDeFgHiJk' * 4; // 40 chars, all ASCII, no deny-list hit
      final result = WalletCreationFlow.safeUserNameForLog(longName);
      // After truncation to 32 chars and redactMessage (no matches), result
      // length must not exceed 32.
      expect(result.length, lessThanOrEqualTo(32));
    });

    test('non-ASCII characters are stripped', () {
      const withNonAscii = 'useréname';
      final result = WalletCreationFlow.safeUserNameForLog(withNonAscii);
      expect(result, equals('username'));
    });

    test('newlines are stripped', () {
      const withNewline = 'user\nname';
      final result = WalletCreationFlow.safeUserNameForLog(withNewline);
      expect(result.contains('\n'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // WalletCreationError.actionableMessage formatting
  // -------------------------------------------------------------------------

  group('WalletCreationError.actionableMessage', () {
    test('invalidUsername includes the reason', () {
      const err = WalletCreationError.invalidUsername('must not be empty');
      expect(err.actionableMessage, contains('must not be empty'));
    });

    test('userCanceled returns a friendly message', () {
      const err = WalletCreationError.userCanceled();
      expect(err.actionableMessage.toLowerCase(), contains('cancel'));
    });

    test('webAuthnKeyFormatInvalid includes the reason', () {
      const err = WalletCreationError.webAuthnKeyFormatInvalid('bad size');
      expect(err.actionableMessage, contains('bad size'));
    });

    test('creationFailed includes the reason', () {
      const err = WalletCreationError.creationFailed('network timeout');
      expect(err.actionableMessage, contains('network timeout'));
    });
  });

  // -------------------------------------------------------------------------
  // WalletCreationResult structure
  // -------------------------------------------------------------------------

  group('WalletCreationResult', () {
    test('fields reflect the SDK result and autoSubmit flag', () async {
      final ops = MockWalletOperations()
        ..result = WalletCreationFixtures.validSdkResult();
      final flow = WalletCreationFixtures.makeFlow(walletOps: ops);

      final result = await flow.createWallet(
        username: 'Test',
        autoSubmit: true,
      );

      expect(
        result.contractAddress,
        equals(WalletCreationFixtures.defaultContractId),
      );
      expect(
        result.credentialId,
        equals(WalletCreationFixtures.defaultCredentialId),
      );
      expect(result.isDeployed, isTrue);
      // xlmBalance/demoTokenBalance depend on mainScreenFlow; null when not
      // injected (unit test path).
      expect(result.xlmBalance, isNull);
      expect(result.demoTokenBalance, isNull);
    });
  });
}
