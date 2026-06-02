/// Shared test support for [WalletCreationFlow] tests.
///
/// Provides mock implementations of [WalletOperationsType] and
/// [DemoTokenServiceType], error stubs, fixture data builders, and helper
/// functions for assembling test dependencies.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/wallet_creation_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/token/demo_token_service.dart';
import 'package:smart_account_demo/wallet/wallet_operations_adapter.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// MockWalletOperations
// ---------------------------------------------------------------------------

/// Configurable mock for [WalletOperationsType].
///
/// All test control is through [result] and [error]. Records the parameters
/// it was called with so tests can assert on them.
final class MockWalletOperations implements WalletOperationsType {
  CreateWalletResult? result;
  Object? error;

  String? lastUserName;
  bool? lastAutoSubmit;
  bool? lastAutoFund;
  String? lastNativeTokenContract;
  int callCount = 0;

  @override
  Future<CreateWalletResult> createWallet({
    required String userName,
    required bool autoSubmit,
    required bool autoFund,
    String? nativeTokenContract,
  }) async {
    callCount++;
    lastUserName = userName;
    lastAutoSubmit = autoSubmit;
    lastAutoFund = autoFund;
    lastNativeTokenContract = nativeTokenContract;
    final e = error;
    if (e != null) throw e;
    final r = result;
    if (r == null) {
      throw StateError(
        'MockWalletOperations: neither result nor error configured.',
      );
    }
    return r;
  }
}

// ---------------------------------------------------------------------------
// MockSlowWalletOperations
// ---------------------------------------------------------------------------

/// A wallet operations mock that suspends until an external [Completer] is
/// completed.
///
/// Used to verify the reentrancy guard: the first [createWallet] call suspends
/// while awaiting the completer; the test issues a second call while the first
/// is in flight; asserts the second call throws immediately; then completes the
/// completer to let the first call finish. This avoids wall-clock timing
/// dependencies that cause CI flakiness.
final class MockSlowWalletOperations implements WalletOperationsType {
  /// Constructs the mock with the provided [completer].
  ///
  /// The completer must be completed by the test after asserting on the
  /// reentrancy throw so the first in-flight call can finish.
  MockSlowWalletOperations({required this.completer});

  /// The completer that controls when [createWallet] returns.
  final Completer<CreateWalletResult> completer;

  Object? error;

  @override
  Future<CreateWalletResult> createWallet({
    required String userName,
    required bool autoSubmit,
    required bool autoFund,
    String? nativeTokenContract,
  }) async {
    final e = error;
    if (e != null) throw e;
    return completer.future;
  }
}

// ---------------------------------------------------------------------------
// MockDemoTokenService
// ---------------------------------------------------------------------------

/// Configurable mock for [DemoTokenServiceType].
final class MockDemoTokenService implements DemoTokenServiceType {
  DemoTokenResult? result;
  Object? error;

  String? lastRecipientContractId;
  int callCount = 0;

  @override
  Future<DemoTokenResult> ensureTokenAndMint({
    required String recipientContractId,
  }) async {
    callCount++;
    lastRecipientContractId = recipientContractId;
    final e = error;
    if (e != null) throw e;
    final r = result;
    if (r == null) {
      throw StateError(
        'MockDemoTokenService: neither result nor error configured.',
      );
    }
    return r;
  }
}

// ---------------------------------------------------------------------------
// Error stubs
// ---------------------------------------------------------------------------

/// Simulates a user-cancellation error.
///
/// Uses the SDK's [WebAuthnCancelled] factory constructor directly (it is a
/// final class and cannot be subclassed). The flow's [_mapCreationError]
/// checks for [WebAuthnCancelled] via an `is` check, so this produces
/// [WalletCreationError.userCanceled] in the flow.
WebAuthnCancelled makeCancelledError() =>
    const WebAuthnCancelled(message: 'User cancelled the passkey ceremony.');

/// Simulates a network error thrown by the SDK.
final class MockNetworkError implements Exception {
  @override
  String toString() => 'Network unreachable: connection timeout.';
}

/// Simulates a mint-layer error thrown by the token service.
final class MockMintError implements Exception {
  @override
  String toString() => 'Mint operation failed: insufficient allowance.';
}

// ---------------------------------------------------------------------------
// WalletCreationFixtures
// ---------------------------------------------------------------------------

/// Shared test-fixture builders for wallet creation tests.
final class WalletCreationFixtures {
  WalletCreationFixtures._();

  static const String defaultContractId =
      'CABC1234567890123456789012345678901234567890123456789012';
  static const String defaultCredentialId =
      'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU';
  static const String tokenContractId =
      'CDEMOTOKEN12345678901234567890123456789012345678901234567';

  /// A valid 65-byte secp256r1 uncompressed key (0x04 prefix + 64 zero bytes).
  static Uint8List get validPublicKey {
    final key = Uint8List(65);
    key[0] = 0x04;
    return key;
  }

  /// Returns a [CreateWalletResult] with a valid secp256r1 public key.
  static CreateWalletResult validSdkResult({
    String contractId = defaultContractId,
    String credentialId = defaultCredentialId,
    bool deployed = true,
  }) {
    return CreateWalletResult(
      credentialId: credentialId,
      contractId: contractId,
      publicKey: validPublicKey,
      signedTransactionXdr: 'placeholder_xdr',
      transactionHash: deployed ? 'abc123txhash' : null,
    );
  }

  /// Returns a [CreateWalletResult] whose 32-byte key fails the secp256r1 check.
  static CreateWalletResult invalidKeyResult() {
    return CreateWalletResult(
      credentialId: defaultCredentialId,
      contractId: defaultContractId,
      publicKey: Uint8List(32),
      signedTransactionXdr: 'placeholder_xdr',
    );
  }

  /// Returns a [CreateWalletResult] with a 65-byte key starting with 0x02.
  static CreateWalletResult wrongPrefixKeyResult() {
    final badKey = Uint8List(65);
    badKey[0] = 0x02;
    return CreateWalletResult(
      credentialId: defaultCredentialId,
      contractId: defaultContractId,
      publicKey: badKey,
      signedTransactionXdr: 'placeholder_xdr',
    );
  }

  /// Returns a [DemoTokenResult] with the fixture token contract ID.
  static DemoTokenResult tokenResult({
    String contractId = tokenContractId,
    int amountMinted = 100000000000,
    bool alreadyExisted = false,
  }) =>
      DemoTokenResult(
        tokenContractId: contractId,
        amountMinted: amountMinted,
        alreadyExisted: alreadyExisted,
      );

  // ---- Flow factory helpers ----

  /// Builds a [WalletCreationFlow] with no associated state/log references.
  ///
  /// Uses a fresh [ProviderContainer] with ephemeral notifiers. Suitable for
  /// tests that only care about the return value or thrown error.
  ///
  /// The container is disposed automatically via [addTearDown] so tests do not
  /// need to manage its lifecycle explicitly.
  static WalletCreationFlow makeFlow({
    required WalletOperationsType walletOps,
    MockDemoTokenService? tokenService,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);
    return WalletCreationFlow(
      demoState: demoState,
      activityLog: activityLog,
      walletOperations: walletOps,
      demoTokenService: tokenService,
    );
  }

  /// Builds a flow with its [DemoStateNotifier] and [ActivityLogNotifier]
  /// exposed so tests can assert on them.
  ///
  /// The container is disposed automatically via [addTearDown].
  static FlowTestDeps makeFlowWithDeps({
    required WalletOperationsType walletOps,
    MockDemoTokenService? tokenService,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);
    final flow = WalletCreationFlow(
      demoState: demoState,
      activityLog: activityLog,
      walletOperations: walletOps,
      demoTokenService: tokenService,
    );
    return FlowTestDeps(
      flow: flow,
      demoState: demoState,
      activityLog: activityLog,
      container: container,
    );
  }
}

// ---------------------------------------------------------------------------
// FlowTestDeps
// ---------------------------------------------------------------------------

/// Dependencies returned by [WalletCreationFixtures.makeFlowWithDeps].
final class FlowTestDeps {
  const FlowTestDeps({
    required this.flow,
    required this.demoState,
    required this.activityLog,
    required this.container,
  });

  final WalletCreationFlow flow;
  final DemoStateNotifier demoState;
  final ActivityLogNotifier activityLog;
  final ProviderContainer container;

  /// Convenience accessor for the current [WalletConnectionState].
  WalletConnectionState get state => demoState.currentState;

  /// Convenience accessor for the current log entries.
  List<LogEntry> get logEntries => container.read(activityLogProvider);
}
