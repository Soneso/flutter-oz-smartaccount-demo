/// Tests for [MainScreenFlow].
///
/// Strategy:
/// - [initializeKit] is tested via failure paths (nil provider → bootstrapError
///   set + error log entry) and idempotency guard.
/// - [refreshBalances] covers guard conditions: disconnected state exits early,
///   nil kit exits early. Live network is NOT required.
/// - [disconnect] verifies all state is cleared and a log entry is added.
/// - [describeKitEvent] maps each [OZSmartAccountEvent] type to the expected
///   [LogLevel] and message pattern.
/// - Screens-never-call-SDK guard reads every file in [lib/screens/] and
///   asserts none contain SDK type or accessor patterns, anchored via an
///   absolute path so the guard cannot pass vacuously on a missing directory.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/main_screen_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// Project-root locator
// ---------------------------------------------------------------------------

/// Walks up the directory tree from [Platform.script] until a directory
/// containing a `pubspec.yaml` sibling is found, then returns that directory
/// as the project root.
///
/// This is resilient to non-standard test runners, IDE workspace roots, and
/// future monorepo reorganisations. Fails the test immediately if no
/// `pubspec.yaml` ancestor can be located.
Directory _projectRoot() {
  var dir = File.fromUri(Platform.script).parent;
  while (dir.path != dir.parent.path) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  fail(
    'Could not locate pubspec.yaml walking up from ${Platform.script}. '
    'The guard test cannot anchor the screens directory.',
  );
}

// ---------------------------------------------------------------------------
// Top-level helpers (not test functions — no group/test nesting required)
// ---------------------------------------------------------------------------

/// Returns a ([ProviderContainer], [DemoStateNotifier], [ActivityLogNotifier]).
///
/// The container is disposed in [addTearDown] so each test starts clean.
(ProviderContainer, DemoStateNotifier, ActivityLogNotifier) makeTestSetup() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return (
    container,
    container.read(demoStateProvider.notifier),
    container.read(activityLogProvider.notifier),
  );
}

/// Builds a minimal [OZSmartAccountKit] using [OZInMemoryStorageAdapter].
/// No network or Keychain access required.
OZSmartAccountKit buildMinimalKit() {
  final kitConfig = OZSmartAccountConfig(
    rpcUrl: 'https://soroban-testnet.stellar.org',
    networkPassphrase: 'Test SDF Network ; September 2015',
    accountWasmHash:
        '86b49fe03f7df0ad1c2a28bd8361b923ab57096e09f397f92f0c00ae3bd06d28',
    webauthnVerifierAddress:
        'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY',
    storage: OZInMemoryStorageAdapter(),
  );
  return OZSmartAccountKit.create(config: kitConfig);
}

// ---------------------------------------------------------------------------
// Test suite entry point
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // initializeKit — failure paths
  // -------------------------------------------------------------------------

  group('MainScreenFlow.initializeKit', () {
    test('sets bootstrapError when WebAuthn provider is nil', () async {
      final (container, demoState, activityLog) = makeTestSetup();
      // Storage present, WebAuthn provider absent.
      demoState.storage = OZInMemoryStorageAdapter();

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      await flow.initializeKit();

      expect(demoState.bootstrapError, isNotNull);
      expect(
        demoState.bootstrapError,
        anyOf(contains('WebAuthn'), contains('provider')),
      );
      final logEntries = container.read(activityLogProvider);
      expect(
        logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
        reason: 'Expected at least one error log entry',
      );
    });

    test('sets bootstrapError when storage is nil', () async {
      final (container, demoState, activityLog) = makeTestSetup();
      // Neither provider nor storage injected.

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      await flow.initializeKit();

      expect(demoState.bootstrapError, isNotNull);
      final logEntries = container.read(activityLogProvider);
      expect(
        logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
      );
    });

    test('is idempotent when kit is already initialised', () async {
      final (container, demoState, activityLog) = makeTestSetup();
      demoState.storage = OZInMemoryStorageAdapter();

      // Pre-populate the kit so the guard fires immediately.
      final existingKit = buildMinimalKit();
      demoState.kit = existingKit;

      final initialCount = container.read(activityLogProvider).length;

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      await flow.initializeKit();

      // No additional log entries should be added.
      expect(
        container.read(activityLogProvider).length,
        equals(initialCount),
        reason: 'No log entries should be added when kit is already present',
      );
      // The kit reference must be unchanged.
      expect(demoState.kit, same(existingKit));
    });
  });

  // -------------------------------------------------------------------------
  // disconnect
  // -------------------------------------------------------------------------

  group('MainScreenFlow.disconnect', () {
    test('clears connection state, preserves kit, logs an info entry', () async {
      final (container, demoState, activityLog) = makeTestSetup();

      final kit = buildMinimalKit();
      demoState.kit = kit;
      demoState.setConnected(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: 'dummyCredentialId',
        isDeployed: true,
      );
      demoState.updateXlmBalance('10.0');
      demoState.updateDemoTokenBalance('500.0');

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      await flow.disconnect();

      expect(
        demoState.kit,
        same(kit),
        reason: 'Kit instance must survive disconnect so the user can '
            'immediately reconnect without paying SDK init cost again',
      );
      expect(
        demoState.currentState.isConnected,
        isFalse,
        reason: 'Should be disconnected after disconnect',
      );
      expect(
        demoState.currentState.xlmBalance,
        isNull,
        reason: 'XLM balance should be null after disconnect',
      );
      expect(
        demoState.currentState.demoTokenBalance,
        isNull,
        reason: 'DEMO balance should be null after disconnect',
      );

      final logEntries = container.read(activityLogProvider);
      expect(
        logEntries.any(
          (e) =>
              e.level == LogLevel.info &&
              e.message.toLowerCase().contains('disconnect'),
        ),
        isTrue,
        reason: 'Expected a disconnect log entry',
      );
    });

    test('disconnect from disconnected state logs without error', () async {
      final (container, demoState, activityLog) = makeTestSetup();

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      await flow.disconnect();

      final logEntries = container.read(activityLogProvider);
      expect(
        logEntries.any((e) => e.level == LogLevel.error),
        isFalse,
        reason: 'Disconnect from disconnected state must not log an error',
      );
    });
  });

  // -------------------------------------------------------------------------
  // refreshBalances — guard paths
  // -------------------------------------------------------------------------

  group('MainScreenFlow.refreshBalances', () {
    test('exits early when wallet is not connected', () async {
      final (container, demoState, activityLog) = makeTestSetup();

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      final countBefore = container.read(activityLogProvider).length;
      await flow.refreshBalances();

      expect(
        container.read(activityLogProvider).length,
        equals(countBefore),
        reason: 'refreshBalances should not log when disconnected',
      );
    });

    test('exits early when kit is nil but connected state is set', () async {
      final (container, demoState, activityLog) = makeTestSetup();
      demoState.setConnected(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: 'cred',
        isDeployed: true,
      );
      // Kit deliberately left null.

      final flow = MainScreenFlow(
        demoState: demoState,
        activityLog: activityLog,
      );

      final countBefore = container.read(activityLogProvider).length;
      await flow.refreshBalances();

      expect(container.read(activityLogProvider).length, equals(countBefore));
    });
  });

  // -------------------------------------------------------------------------
  // BootstrapError
  // -------------------------------------------------------------------------

  group('BootstrapError', () {
    test('has an actionable toString', () {
      const err = BootstrapError('WebAuthn provider was not injected.');
      final desc = err.toString();
      expect(desc, contains('provider'));
      expect(desc, contains('not injected'));
    });
  });

  // -------------------------------------------------------------------------
  // describeKitEvent — mapping tests for each OZSmartAccountEvent subtype
  // -------------------------------------------------------------------------

  group('MainScreenFlow.describeKitEvent', () {
    test('WalletConnected → success level, contains address and cred', () {
      const event = OZSmartAccountEventWalletConnected(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: 'abcdef1234567890abcdef1234567890',
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.success);
      expect(message.toLowerCase(), contains('connected'));
      expect(message, contains('cred:'));
    });

    test('WalletDisconnected → info level', () {
      const event = OZSmartAccountEventWalletDisconnected(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.info);
      expect(message.toLowerCase(), contains('disconnect'));
    });

    test('CredentialCreated → success level', () {
      final credential = OZStoredCredential(
        credentialId: 'abcdef1234567890abcdef1234567890',
        publicKey: Uint8List(65),
      );
      final event = OZSmartAccountEventCredentialCreated(credential: credential);
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.success);
      expect(message, contains('Credential registered'));
    });

    test('CredentialDeleted → info level', () {
      const event = OZSmartAccountEventCredentialDeleted(
        credentialId: 'abcdef1234567890abcdef1234567890',
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.info);
      expect(message.toLowerCase(), contains('removed'));
    });

    test('SessionExpired → error level with reconnect hint', () {
      const event = OZSmartAccountEventSessionExpired(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: 'abcdef1234567890abcdef1234567890',
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.error);
      expect(message.toLowerCase(), contains('expired'));
      expect(message.toLowerCase(), contains('reconnect'));
    });

    test('TransactionSigned with credentialId → info level', () {
      const event = OZSmartAccountEventTransactionSigned(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: 'abcdef1234567890abcdef1234567890',
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.info);
      expect(message.toLowerCase(), contains('signed'));
    });

    test('TransactionSigned without credentialId → "external" in message', () {
      const event = OZSmartAccountEventTransactionSigned(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: null,
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.info);
      expect(message, contains('external'));
    });

    test('TransactionSubmitted success → success level', () {
      const event = OZSmartAccountEventTransactionSubmitted(
        hash: 'abc123def456abc123def456abc123de',
        success: true,
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.success);
      expect(message.toLowerCase(), contains('submitted'));
    });

    test('TransactionSubmitted failure → error level', () {
      const event = OZSmartAccountEventTransactionSubmitted(
        hash: 'abc123def456abc123def456abc123de',
        success: false,
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.error);
      expect(message.toLowerCase(), contains('failed'));
    });

    test('CredentialSyncFailed → error level', () {
      final event = OZSmartAccountEventCredentialSyncFailed(
        credentialId: 'abcdef1234567890abcdef1234567890',
        error: Exception('RPC timeout'),
      );
      final (level, message) = MainScreenFlow.describeKitEvent(event);
      expect(level, LogLevel.error);
      expect(message.toLowerCase(), contains('sync failed'));
    });

    test('long credential IDs are truncated with ellipsis', () {
      const longCredId = 'abcdef1234567890ABCDEF1234567890extraextralong';
      const event = OZSmartAccountEventWalletConnected(
        contractId: 'CDUMMYCONTRACTADDRESS123456789012345678901234567890ABCDEF',
        credentialId: longCredId,
      );
      final (_, message) = MainScreenFlow.describeKitEvent(event);
      // The full credential ID must not appear verbatim.
      expect(message.contains(longCredId), isFalse);
      // The truncated form with '...' must appear.
      expect(message, contains('...'));
    });
  });

  // -------------------------------------------------------------------------
  // Screens-never-call-SDK guard
  // -------------------------------------------------------------------------

  group('Architecture', () {
    test('screen files contain no direct SDK calls or accessor reach-through',
        () {
      // Anchor the screens directory via [_projectRoot()], which walks up from
      // [Platform.script] (the compiled test binary) until it finds a sibling
      // pubspec.yaml. This is robust to non-standard runners, IDE workspace
      // roots, and future monorepo moves — unlike [Directory.current], which
      // only coincidentally equals the package root under `flutter test`.
      final screensDir = Directory(
        '${_projectRoot().path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}screens',
      );

      // Fail explicitly when the path is wrong so the guard is never vacuous.
      expect(
        screensDir.existsSync(),
        isTrue,
        reason:
            'Guard test setup broken — screens directory not found at '
            '${screensDir.path}. Fix path arithmetic in this test.',
      );

      // Deny-list: type names + property-accessor reach-through.
      // Note: '.walletOperations' (no trailing dot) catches both
      // '.walletOperations.' and '.walletOperations)' so no screen can
      // dereference the manager directly regardless of how the call is closed.
      const forbiddenPatterns = <String>[
        'OZSmartAccountKit',
        'OZWalletOperations',
        'OZTransactionOperations',
        'OZContextRuleManager',
        'OZPolicyManager',
        'OZSignerManager',
        'OZCredentialManager',
        'OZMultiSignerManager',
        'OZExternalSignerManager',
        'SorobanServer',
        '.walletOperations',
        '.transactionOperations.',
        '.contextRuleManager.',
        '.policyManager.',
        '.signerManager.',
        '.credentialManager.',
        '.multiSignerManager.',
        '.externalSignerManager.',
      ];

      final violations = <String>[];
      final entities = screensDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;

        final contents = entity.readAsStringSync();
        for (final pattern in forbiddenPatterns) {
          if (contents.contains(pattern)) {
            violations.add(
              '${entity.path} contains forbidden pattern: "$pattern"',
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'Architecture violations found:\n${violations.join('\n')}',
      );
    });
  });
} // end main()
