/// Shared test support for [TransferFlow] tests.
///
/// Provides mock implementations of [TransactionOperationsType],
/// [MultiSignerManagerType], and [ContextRuleManagerType], plus fixture
/// builders and helpers for assembling test dependencies.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/main_screen_flow.dart';
import 'package:smart_account_demo/flows/transfer_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// MockTransactionOperations
// ---------------------------------------------------------------------------

/// Configurable mock for [TransactionOperationsType].
///
/// Controls outcome via [result] and [error]. Records call arguments so tests
/// can assert on them.
final class MockTransactionOperations implements TransactionOperationsType {
  OZTransactionResult? result;
  Object? error;

  String? lastTokenContract;
  String? lastRecipient;
  String? lastAmount;
  int callCount = 0;

  @override
  Future<OZTransactionResult> transfer({
    required String tokenContract,
    required String recipient,
    required String amount,
  }) async {
    callCount++;
    lastTokenContract = tokenContract;
    lastRecipient = recipient;
    lastAmount = amount;
    final e = error;
    if (e != null) throw e;
    final r = result;
    if (r == null) {
      throw StateError(
        'MockTransactionOperations: neither result nor error configured.',
      );
    }
    return r;
  }
}

// ---------------------------------------------------------------------------
// MockMultiSignerManager
// ---------------------------------------------------------------------------

/// Configurable mock for [MultiSignerManagerType].
///
/// Controls outcome via [result] and [error]. Records call arguments.
final class MockMultiSignerManager implements MultiSignerManagerType {
  OZTransactionResult? result;
  Object? error;

  String? lastTokenContract;
  String? lastRecipient;
  String? lastAmount;
  List<OZSelectedSigner>? lastSelectedSigners;
  int callCount = 0;

  @override
  Future<OZTransactionResult> multiSignerTransfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    required List<OZSelectedSigner> selectedSigners,
  }) async {
    callCount++;
    lastTokenContract = tokenContract;
    lastRecipient = recipient;
    lastAmount = amount;
    lastSelectedSigners = selectedSigners;
    final e = error;
    if (e != null) throw e;
    final r = result;
    if (r == null) {
      throw StateError(
        'MockMultiSignerManager: neither result nor error configured.',
      );
    }
    return r;
  }
}

// ---------------------------------------------------------------------------
// MockContextRuleManager
// ---------------------------------------------------------------------------

/// Configurable mock for [ContextRuleManagerType].
///
/// Controls rules via [rules] and error via [error].
final class MockContextRuleManager implements ContextRuleManagerType {
  List<OZParsedContextRule> rules = const <OZParsedContextRule>[];
  Object? error;
  int callCount = 0;

  @override
  Future<List<OZParsedContextRule>> listContextRules() async {
    callCount++;
    final e = error;
    if (e != null) throw e;
    return rules;
  }
}

// ---------------------------------------------------------------------------
// Error stubs
// ---------------------------------------------------------------------------

/// Simulates a WebAuthn passkey cancellation.
WebAuthnCancelled makeCancelledError() =>
    const WebAuthnCancelled(message: 'User cancelled the passkey ceremony.');

/// Simulates a generic network error.
final class MockNetworkError implements Exception {
  @override
  String toString() => 'Network unreachable: connection timeout.';
}

/// Simulates a generic on-chain failure.
final class MockTransferError implements Exception {
  @override
  String toString() => 'Transfer failed: insufficient balance.';
}

// ---------------------------------------------------------------------------
// FakeOZExternalSignerManager
// ---------------------------------------------------------------------------

/// A minimal fake [OZExternalSignerManager] for testing cleanup behaviour.
///
/// Tracks which G-addresses and Ed25519 keys have been added, and counts
/// [removeAll] invocations, so tests can assert the correct cleanup invariants
/// without a live kit.
///
/// Only the subset of the manager API used by [TransferFlow]'s registration
/// and cleanup paths is implemented; all other methods throw [UnimplementedError].
final class FakeOZExternalSignerManager extends OZExternalSignerManager {
  FakeOZExternalSignerManager()
      : super(networkPassphrase: 'Test SDF Network ; September 2015');

  /// Currently registered G-addresses (added via [addFromSecret]).
  final Set<String> registeredAddresses = <String>{};

  /// Currently registered Ed25519 keys (added via [addEd25519FromRawKey]).
  final Set<String> registeredEd25519Keys = <String>{};

  /// If non-null, [addFromSecret] throws this error.
  Object? addFromSecretError;

  /// If non-null, [addEd25519FromRawKey] throws this error.
  Object? addEd25519Error;

  int addFromSecretCallCount = 0;
  int removeCallCount = 0;
  int removeAllCallCount = 0;
  int addEd25519CallCount = 0;
  int removeEd25519CallCount = 0;

  @override
  Future<String> addFromSecret(String secretKey) async {
    addFromSecretCallCount++;
    final err = addFromSecretError;
    if (err != null) throw err;
    // Derive address from the real keypair so seed-format validation applies.
    final kp = KeyPair.fromSecretSeed(secretKey);
    final address = kp.accountId;
    registeredAddresses.add(address);
    return address;
  }

  @override
  Future<void> remove(String address) async {
    removeCallCount++;
    registeredAddresses.remove(address);
  }

  @override
  Future<void> removeAll() async {
    removeAllCallCount++;
    registeredAddresses.clear();
    registeredEd25519Keys.clear();
  }

  @override
  Uint8List addEd25519FromRawKey({
    required Uint8List secretKeyBytes,
    required String verifierAddress,
  }) {
    addEd25519CallCount++;
    final err = addEd25519Error;
    if (err != null) throw err;
    if (secretKeyBytes.length != 32) {
      throw ArgumentError.value(
        secretKeyBytes.length,
        'secretKeyBytes',
        'Ed25519 secret key must be exactly 32 bytes',
      );
    }
    final kp = KeyPair.fromSecretSeedList(secretKeyBytes);
    final pubKey = Uint8List.fromList(kp.publicKey);
    registeredEd25519Keys.add('$verifierAddress:${pubKey.take(4).toList()}');
    return pubKey;
  }

  @override
  void removeEd25519({
    required String verifierAddress,
    required Uint8List publicKey,
  }) {
    removeEd25519CallCount++;
    registeredEd25519Keys.remove(
      '$verifierAddress:${publicKey.take(4).toList()}',
    );
  }
}

// ---------------------------------------------------------------------------
// TransferFixtures
// ---------------------------------------------------------------------------

/// Shared test-fixture builders for transfer tests.
final class TransferFixtures {
  TransferFixtures._();

  static const String defaultContractId =
      'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
  static const String defaultCredentialId =
      'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU';
  static const String defaultRecipient =
      'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';
  static const String defaultAmount = '10.0';
  static const String defaultTxHash =
      'abc123def456abc123def456abc123def456abc123def456abc123def456abcd';
  static const String nativeTokenContract =
      'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';
  static const String demoTokenContract =
      'CDEMO12345678901234567890123456789012345678901234567890123456';

  /// A successful [OZTransactionResult].
  static OZTransactionResult successResult({String? hash}) => OZTransactionResult(
        success: true,
        hash: hash ?? defaultTxHash,
      );

  /// A failed [OZTransactionResult].
  static OZTransactionResult failureResult({String? errorMessage}) =>
      OZTransactionResult(
        success: false,
        error: errorMessage ?? 'Transfer failed on-chain.',
      );

  /// Builds a [TransferFlow] with minimal dependencies for unit tests.
  ///
  /// [demoState] and [activityLog] are fresh from a [ProviderContainer].
  /// The container is disposed via [addTearDown].
  static TransferFlowTestDeps makeFlowWithDeps({
    MockTransactionOperations? transactionOps,
    MockMultiSignerManager? multiSignerManager,
    MockContextRuleManager? contextRuleManager,
    String? contractId,
    String? credentialId,
    String? demoTokenContractId,
    bool isConnected = true,
    bool isDeployed = true,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);

    if (isConnected) {
      demoState.setConnected(
        contractId: contractId ?? defaultContractId,
        credentialId: credentialId ?? defaultCredentialId,
        isDeployed: isDeployed,
      );
      if (demoTokenContractId != null) {
        demoState.updateDemoTokenContract(demoTokenContractId);
      }
    }

    final txOps = transactionOps ?? MockTransactionOperations();
    final multiMgr = multiSignerManager ?? MockMultiSignerManager();
    final contextMgr = contextRuleManager ?? MockContextRuleManager();

    final flow = TransferFlow(
      demoState: demoState,
      activityLog: activityLog,
      transactionOperations: txOps,
      multiSignerManager: multiMgr,
      contextRuleManager: contextMgr,
    );

    return TransferFlowTestDeps(
      flow: flow,
      demoState: demoState,
      activityLog: activityLog,
      transactionOps: txOps,
      multiSignerManager: multiMgr,
      contextRuleManager: contextMgr,
      container: container,
    );
  }

  /// Builds a [TransferFlow] wired with a [FakeOZExternalSignerManager] so
  /// cleanup and leak behaviour can be tested without a live kit.
  ///
  /// The fake manager is injected directly onto [DemoStateNotifier] and an
  /// in-memory kit stub is also set so [externalSigners] returns the fake.
  static TransferFlowWithManagerDeps makeFlowWithManager({
    MockMultiSignerManager? multiSignerManager,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);

    demoState.setConnected(
      contractId: defaultContractId,
      credentialId: defaultCredentialId,
      isDeployed: true,
    );

    final fakeManager = FakeOZExternalSignerManager();
    // Install the fake manager into a stub kit via the notifier.
    demoState.injectFakeExternalSigners(fakeManager);

    final multiMgr = multiSignerManager ?? MockMultiSignerManager();

    final flow = TransferFlow(
      demoState: demoState,
      activityLog: activityLog,
      transactionOperations: MockTransactionOperations(),
      multiSignerManager: multiMgr,
      contextRuleManager: MockContextRuleManager(),
    );

    return TransferFlowWithManagerDeps(
      flow: flow,
      demoState: demoState,
      fakeManager: fakeManager,
      container: container,
    );
  }
}

// ---------------------------------------------------------------------------
// TransferFlowTestDeps
// ---------------------------------------------------------------------------

/// All dependencies returned by [TransferFixtures.makeFlowWithDeps].
final class TransferFlowTestDeps {
  const TransferFlowTestDeps({
    required this.flow,
    required this.demoState,
    required this.activityLog,
    required this.transactionOps,
    required this.multiSignerManager,
    required this.contextRuleManager,
    required this.container,
  });

  final TransferFlow flow;
  final DemoStateNotifier demoState;
  final ActivityLogNotifier activityLog;
  final MockTransactionOperations transactionOps;
  final MockMultiSignerManager multiSignerManager;
  final MockContextRuleManager contextRuleManager;
  final ProviderContainer container;

  WalletConnectionState get state => demoState.currentState;
  List<LogEntry> get logEntries => container.read(activityLogProvider);
}

// ---------------------------------------------------------------------------
// TransferFlowWithManagerDeps
// ---------------------------------------------------------------------------

/// Dependencies for tests that inject a [FakeOZExternalSignerManager].
final class TransferFlowWithManagerDeps {
  const TransferFlowWithManagerDeps({
    required this.flow,
    required this.demoState,
    required this.fakeManager,
    required this.container,
  });

  final TransferFlow flow;
  final DemoStateNotifier demoState;
  final FakeOZExternalSignerManager fakeManager;
  final ProviderContainer container;
}

// ---------------------------------------------------------------------------
// NoOpMainScreenFlow
// ---------------------------------------------------------------------------

/// A [MainScreenFlow] that no-ops [refreshBalances] for test isolation.
final class NoOpMainScreenFlow extends MainScreenFlow {
  NoOpMainScreenFlow()
      : super(
          demoState: ProviderContainer().read(demoStateProvider.notifier),
          activityLog: ProviderContainer().read(activityLogProvider.notifier),
        );

  @override
  Future<void> refreshBalances() async {}
}
