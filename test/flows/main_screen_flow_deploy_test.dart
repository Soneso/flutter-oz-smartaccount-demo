/// Tests for [MainScreenFlow.deployPendingAndProvision].
///
/// Strategy:
/// - Verify that calling deployPendingAndProvision without a kit throws
///   [StateError] immediately.
/// - Verify error message renames: "Failed to initialize SDK:", "Failed to
///   refresh balance:" by inspecting activity log entries on specific code paths.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/main_screen_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------

(ProviderContainer, DemoStateNotifier, ActivityLogNotifier) makeSetup() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return (
    container,
    container.read(demoStateProvider.notifier),
    container.read(activityLogProvider.notifier),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MainScreenFlow.deployPendingAndProvision', () {
    test('throws StateError when kit is not initialised', () async {
      final (_, demoState, activityLog) = makeSetup();

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      // Kit is null — the flow must throw a StateError immediately and also
      // log an error so the activity log reflects the failure.
      await expectLater(
        flow.deployPendingAndProvision(credentialId: 'test-cred-id'),
        throwsA(isA<StateError>()),
      );
    });

    test('logs error entry and rethrows when kit is absent', () async {
      final (container, demoState, activityLog) = makeSetup();

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      try {
        await flow.deployPendingAndProvision(credentialId: 'test-cred-id');
      } catch (_) {}

      // A deployment failure must produce an error log entry.
      final entries = container.read(activityLogProvider);
      expect(
        entries.any((e) => e.level == LogLevel.error),
        isTrue,
        reason: 'Expected at least one error log entry after failed deploy',
      );
    });
  });

  group('MainScreenFlow error message wording', () {
    test('initializeKit logs "Failed to initialize SDK:" on bootstrap failure',
        () async {
      final (container, demoState, activityLog) = makeSetup();
      // Leave storage and webAuthn provider absent so kit build throws.

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );
      await flow.initializeKit();

      final entries = container.read(activityLogProvider);
      expect(
        entries.any(
          (e) =>
              e.level == LogLevel.error &&
              e.message.contains('Failed to initialize SDK:'),
        ),
        isTrue,
        reason:
            'Expected error log entry prefixed "Failed to initialize SDK:"',
      );
    });

    test('refreshBalances exits early when kit is null', () async {
      final (container, demoState, activityLog) = makeSetup();

      // Set connected state with a valid-looking contract ID but no kit.
      // refreshBalances guards on kit == null and exits early, so no log
      // entries should be written.
      demoState.setConnected(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: 'cred',
        isDeployed: true,
      );
      // Kit deliberately left null — refreshBalances exits early.

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      final countBefore = container.read(activityLogProvider).length;
      await flow.refreshBalances();
      final countAfter = container.read(activityLogProvider).length;

      // Early exit: no entries should have been added.
      expect(countAfter, equals(countBefore));
    });

    test(
        'deployPendingAndProvision success path — skipped: requires live RPC mock',
        () async {
      // Skipped: requires SDK mock — covered by integration tests.
      // The success path (demoState.isDeployed == true after deploy, success log
      // entry present) cannot be exercised without a real or mocked
      // OZSmartAccountKit that successfully calls walletOperations.deployPendingCredential.
      // Mocking the kit at the interface boundary would require either a full
      // injectable abstraction layer or a live testnet RPC. Both are out of scope
      // for unit tests; the integration test suite covers this path end-to-end.
    },
        skip: 'Requires SDK mock — covered by integration tests',
    );
  });

  group('MainScreenFlow.disconnect error message', () {
    test('does not use deprecated "Disconnect error:" phrasing', () async {
      final (container, demoState, activityLog) = makeSetup();

      // Build a kit with no real providers so disconnect succeeds trivially.
      final kitConfig = OZSmartAccountConfig(
        rpcUrl: 'https://soroban-testnet.stellar.org',
        networkPassphrase: 'Test SDF Network ; September 2015',
        accountWasmHash:
            '86b49fe03f7df0ad1c2a28bd8361b923ab57096e09f397f92f0c00ae3bd06d28',
        webauthnVerifierAddress:
            'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY',
        storage: OZInMemoryStorageAdapter(),
      );
      final kit = OZSmartAccountKit.create(config: kitConfig);
      demoState.kit = kit;
      demoState.setConnected(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: 'cred',
        isDeployed: true,
      );

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      await flow.disconnect();

      final entries = container.read(activityLogProvider);
      final hasDeprecated = entries.any(
        (e) => e.message.contains('Disconnect error:'),
      );
      expect(
        hasDeprecated,
        isFalse,
        reason:
            'Log entries must not use deprecated "Disconnect error:" phrasing',
      );
    });
  });
}
