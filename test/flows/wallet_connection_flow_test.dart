/// Tests for [WalletConnectionFlow].
///
/// Strategy:
/// - Path A (auto connect): session restore, no-result, cancellation.
/// - Path B (indexer): single result, ambiguous result, no-result, cancellation.
/// - Path C (address): connected, no-result, cancellation.
/// - finalizeAmbiguous: success.
/// - Path D (retry deploy): success, failure.
/// - Path D (delete): success.
/// - loadPendingCredentials: list returned, empty on error.
/// - isDeployed probe: true and false branch.
/// - Kit nil: null flow.
/// - Network error: inline error logged, not thrown to caller as-is.
///
/// No network or platform services are used. All SDK operations are mocked via
/// [WalletConnectionOperationsType] and [CredentialOperationsType] test doubles.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/wallet_connection_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'wallet_connection_test_support.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Path A: autoConnect
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — autoConnect', () {
    test('session restore returns ConnectionResultConnected, state updated',
        () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectResult = WalletConnectionFixtures.connectedResult(
        restoredFromSession: true,
      );
      deps.credentialOps.isDeployedResult = true;

      final result = await deps.flow.autoConnect();

      expect(result, isA<ConnectionResultConnected>());
      final connected = result! as ConnectionResultConnected;
      expect(connected.restoredFromSession, isTrue);
      expect(connected.isDeployed, isTrue);
      expect(deps.state.isConnected, isTrue);
      expect(deps.state.contractId, equals(WalletConnectionFixtures.defaultContractId));
    });

    test('auto connect with no-result returns null', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectResult = null;

      final result = await deps.flow.autoConnect();

      expect(result, isNull);
      expect(deps.state.isConnected, isFalse);
    });

    test('auto connect with Ambiguous returns ConnectionResultAmbiguous',
        () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectResult = WalletConnectionFixtures.ambiguousResult();

      final result = await deps.flow.autoConnect();

      expect(result, isA<ConnectionResultAmbiguous>());
      final ambiguous = result! as ConnectionResultAmbiguous;
      expect(ambiguous.candidates.length, equals(2));
      expect(deps.state.isConnected, isFalse);
    });

    test('auto connect — isDeployed = false when context rule probe throws',
        () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectResult = WalletConnectionFixtures.connectedResult();
      deps.credentialOps.isDeployedError = MockRpcError();

      final result = await deps.flow.autoConnect();

      expect(result, isA<ConnectionResultConnected>());
      final connected = result! as ConnectionResultConnected;
      expect(connected.isDeployed, isFalse);
      expect(deps.state.isDeployed, isFalse);
    });

    test('user cancellation rethrows WebAuthnCancelled', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectError = makeCancelledError();

      await expectLater(
        deps.flow.autoConnect(),
        throwsA(isA<WebAuthnCancelled>()),
      );
      expect(deps.state.isConnected, isFalse);
    });

    test('cancellation writes info log', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectError = makeCancelledError();

      try {
        await deps.flow.autoConnect();
      } on WebAuthnCancelled {
        // expected
      }

      final hasCancel = deps.logEntries.any(
        (e) =>
            e.level == LogLevel.info &&
            e.message.toLowerCase().contains('cancelled'),
      );
      expect(hasCancel, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Path B: connectViaIndexer
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — connectViaIndexer', () {
    test('single result returns ConnectionResultConnected', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateResult =
          WalletConnectionFixtures.authenticateResult();
      deps.walletOps.connectResult = WalletConnectionFixtures.connectedResult();
      deps.credentialOps.isDeployedResult = true;

      final result = await deps.flow.connectViaIndexer();

      expect(result, isA<ConnectionResultConnected>());
      expect(deps.state.isConnected, isTrue);
      // Both authenticate + connect were called.
      expect(deps.walletOps.authenticateCallCount, equals(1));
      expect(deps.walletOps.connectCallCount, equals(1));
    });

    test('ambiguous result returns ConnectionResultAmbiguous', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateResult =
          WalletConnectionFixtures.authenticateResult();
      deps.walletOps.connectResult = WalletConnectionFixtures.ambiguousResult();

      final result = await deps.flow.connectViaIndexer();

      expect(result, isA<ConnectionResultAmbiguous>());
      final ambiguous = result! as ConnectionResultAmbiguous;
      expect(ambiguous.candidates.length, equals(2));
      expect(deps.state.isConnected, isFalse);
    });

    test('no indexer result returns null', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateResult =
          WalletConnectionFixtures.authenticateResult();
      deps.walletOps.connectResult = null;

      final result = await deps.flow.connectViaIndexer();

      expect(result, isNull);
      expect(deps.state.isConnected, isFalse);
    });

    test('user cancellation during authenticate rethrows WebAuthnCancelled',
        () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateError = makeCancelledError();

      await expectLater(
        deps.flow.connectViaIndexer(),
        throwsA(isA<WebAuthnCancelled>()),
      );
      // connect was never called.
      expect(deps.walletOps.connectCallCount, equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // Path C: connectWithAddress
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — connectWithAddress', () {
    const address = WalletConnectionFixtures.defaultContractId;

    test('connected result returned, state updated', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateResult =
          WalletConnectionFixtures.authenticateResult();
      deps.walletOps.connectResult = WalletConnectionFixtures.connectedResult(
        contractId: address,
      );
      deps.credentialOps.isDeployedResult = true;

      final result = await deps.flow.connectWithAddress(address);

      expect(result, isA<ConnectionResultConnected>());
      expect(deps.state.isConnected, isTrue);
      // Verify the correct contractId was passed.
      expect(
        deps.walletOps.lastConnectOptions?.contractId,
        equals(address),
      );
    });

    test('no-result returns null', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateResult =
          WalletConnectionFixtures.authenticateResult();
      deps.walletOps.connectResult = null;

      final result = await deps.flow.connectWithAddress(address);

      expect(result, isNull);
      expect(deps.state.isConnected, isFalse);
    });

    test('user cancellation rethrows WebAuthnCancelled', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateError = makeCancelledError();

      await expectLater(
        deps.flow.connectWithAddress(address),
        throwsA(isA<WebAuthnCancelled>()),
      );
    });

    test('SDK connect error rethrows', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.authenticateResult =
          WalletConnectionFixtures.authenticateResult();
      deps.walletOps.connectError = MockRpcError();

      await expectLater(
        deps.flow.connectWithAddress(address),
        throwsA(isA<MockRpcError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // finalizeAmbiguous
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — finalizeAmbiguous', () {
    test('returns ConnectionResultConnected on success', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectResult = WalletConnectionFixtures.connectedResult();
      deps.credentialOps.isDeployedResult = true;

      final result = await deps.flow.finalizeAmbiguous(
        credentialId: WalletConnectionFixtures.defaultCredentialId,
        contractAddress: WalletConnectionFixtures.defaultContractId,
      );

      expect(result, isA<ConnectionResultConnected>());
      expect(deps.state.isConnected, isTrue);
    });

    test('returns null when connect returns null', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectResult = null;

      final result = await deps.flow.finalizeAmbiguous(
        credentialId: WalletConnectionFixtures.defaultCredentialId,
        contractAddress: WalletConnectionFixtures.defaultContractId,
      );

      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Path D: retryPendingDeploy
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — retryPendingDeploy', () {
    test('success updates state and returns connected', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.deployResult = WalletConnectionFixtures.deployPendingResult();
      deps.credentialOps.isDeployedResult = true;

      final result = await deps.flow.retryPendingDeploy(
        credentialId: WalletConnectionFixtures.defaultCredentialId,
      );

      expect(result, isA<ConnectionResultConnected>());
      expect(deps.state.isConnected, isTrue);
      expect(deps.state.isDeployed, isTrue);
    });

    test('failure rethrows exception', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.deployError = MockNetworkError();

      await expectLater(
        deps.flow.retryPendingDeploy(
          credentialId: WalletConnectionFixtures.defaultCredentialId,
        ),
        throwsA(isA<MockNetworkError>()),
      );
      expect(deps.state.isConnected, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Path D: deletePendingCredential
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — deletePendingCredential', () {
    test('success returns true', () async {
      final deps = WalletConnectionFixtures.makeFlow();

      final ok = await deps.flow.deletePendingCredential(
        credentialId: WalletConnectionFixtures.defaultCredentialId,
      );

      expect(ok, isTrue);
      expect(
        deps.credentialOps.lastDeletedCredentialId,
        equals(WalletConnectionFixtures.defaultCredentialId),
      );
    });

    test('failure returns false and logs error', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.credentialOps.deleteError = MockNetworkError();

      final ok = await deps.flow.deletePendingCredential(
        credentialId: WalletConnectionFixtures.defaultCredentialId,
      );

      expect(ok, isFalse);
      final hasError =
          deps.logEntries.any((e) => e.level == LogLevel.error);
      expect(hasError, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // loadPendingCredentials
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — loadPendingCredentials', () {
    test('returns list of pending credentials', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.credentialOps.pendingCredentials = [
        WalletConnectionFixtures.storedCredential(),
      ];

      final pending = await deps.flow.loadPendingCredentials();

      expect(pending.length, equals(1));
      expect(
        pending.first.credentialId,
        equals(WalletConnectionFixtures.defaultCredentialId),
      );
    });

    test('returns empty list when getPendingCredentials throws', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.credentialOps.pendingError = MockNetworkError();

      final pending = await deps.flow.loadPendingCredentials();

      expect(pending, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Network error path
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — network error handling', () {
    test('network error in autoConnect rethrows and logs', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.connectError = MockNetworkError();

      await expectLater(
        deps.flow.autoConnect(),
        throwsA(isA<MockNetworkError>()),
      );

      final hasError =
          deps.logEntries.any((e) => e.level == LogLevel.error);
      expect(hasError, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // retryPendingDeploy state sync on failure
  // ---------------------------------------------------------------------------

  group('WalletConnectionFlow — retryPendingDeploy failure state sync', () {
    test('isConnected is false after deploy throws', () async {
      final deps = WalletConnectionFixtures.makeFlow();
      deps.walletOps.deployError = MockNetworkError();

      // Pre-set connected state to simulate SDK pre-setting it before submit.
      deps.demoState.setConnected(
        contractId: WalletConnectionFixtures.defaultContractId,
        credentialId: WalletConnectionFixtures.defaultCredentialId,
        isDeployed: false,
      );
      expect(deps.state.isConnected, isTrue);

      await expectLater(
        deps.flow.retryPendingDeploy(
          credentialId: WalletConnectionFixtures.defaultCredentialId,
        ),
        throwsA(isA<MockNetworkError>()),
      );

      // Flow must revert to disconnected on failure.
      expect(deps.state.isConnected, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // buildWalletConnectionFlow factory
  // ---------------------------------------------------------------------------

  group('buildWalletConnectionFlow', () {
    test('returns null when kit is not initialised', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final demoState = container.read(demoStateProvider.notifier);
      final activityLog = container.read(activityLogProvider.notifier);

      final flow = buildWalletConnectionFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      expect(flow, isNull);
    });
  });
}
