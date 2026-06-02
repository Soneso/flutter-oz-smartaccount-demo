/// Shared test support for [WalletConnectionFlow] tests.
///
/// Provides mock implementations of [WalletConnectionOperationsType] and
/// [CredentialOperationsType], fixture data builders, and helper functions
/// for assembling test dependencies.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/wallet_connection_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// MockWalletConnectionOperations
// ---------------------------------------------------------------------------

/// Configurable mock for [WalletConnectionOperationsType].
final class MockWalletConnectionOperations
    implements WalletConnectionOperationsType {
  OZConnectWalletResult? connectResult;
  Object? connectError;

  AuthenticatePasskeyResult? authenticateResult;
  Object? authenticateError;

  DeployPendingResult? deployResult;
  Object? deployError;

  int connectCallCount = 0;
  int authenticateCallCount = 0;
  int deployCallCount = 0;

  ConnectWalletOptions? lastConnectOptions;
  String? lastDeployCredentialId;
  bool? lastDeployAutoFund;
  String? lastDeployNativeTokenContract;

  @override
  Future<OZConnectWalletResult?> connectWallet({
    required ConnectWalletOptions options,
  }) async {
    connectCallCount++;
    lastConnectOptions = options;
    final e = connectError;
    if (e != null) throw e;
    return connectResult;
  }

  @override
  Future<AuthenticatePasskeyResult> authenticatePasskey() async {
    authenticateCallCount++;
    final e = authenticateError;
    if (e != null) throw e;
    final r = authenticateResult;
    if (r == null) {
      throw StateError(
        'MockWalletConnectionOperations: neither authenticateResult nor '
        'authenticateError configured.',
      );
    }
    return r;
  }

  @override
  Future<DeployPendingResult> deployPendingCredential({
    required String credentialId,
    bool autoFund = false,
    String? nativeTokenContract,
  }) async {
    deployCallCount++;
    lastDeployCredentialId = credentialId;
    lastDeployAutoFund = autoFund;
    lastDeployNativeTokenContract = nativeTokenContract;
    final e = deployError;
    if (e != null) throw e;
    final r = deployResult;
    if (r == null) {
      throw StateError(
        'MockWalletConnectionOperations: neither deployResult nor deployError '
        'configured.',
      );
    }
    return r;
  }
}

// ---------------------------------------------------------------------------
// MockCredentialOperations
// ---------------------------------------------------------------------------

/// Configurable mock for [CredentialOperationsType].
final class MockCredentialOperations implements CredentialOperationsType {
  List<StoredCredential> pendingCredentials = const [];
  Object? pendingError;

  Object? deleteError;
  bool deleteResult = true;

  bool isDeployedResult = true;
  Object? isDeployedError;

  int getPendingCallCount = 0;
  int deleteCallCount = 0;
  int isDeployedCallCount = 0;

  String? lastDeletedCredentialId;

  @override
  Future<List<StoredCredential>> getPendingCredentials() async {
    getPendingCallCount++;
    final e = pendingError;
    if (e != null) throw e;
    return pendingCredentials;
  }

  @override
  Future<void> deleteCredential({required String credentialId}) async {
    deleteCallCount++;
    lastDeletedCredentialId = credentialId;
    final e = deleteError;
    if (e != null) throw e;
  }

  @override
  Future<bool> isDeployed() async {
    isDeployedCallCount++;
    final e = isDeployedError;
    if (e != null) throw e;
    return isDeployedResult;
  }
}

// ---------------------------------------------------------------------------
// WalletConnectionFixtures
// ---------------------------------------------------------------------------

/// Shared fixture builders for wallet connection tests.
final class WalletConnectionFixtures {
  WalletConnectionFixtures._();

  static const String defaultCredentialId =
      'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU';
  // Valid checksummed C-addresses (StrKey.encodeContractId of 32 zero bytes
  // and 32 one bytes respectively). The previous dummy strings failed
  // StrKey.isValidContractId after the validator was strengthened to use full
  // base32+CRC-16 verification.
  static const String defaultContractId =
      'CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC4';
  static const String altContractId =
      'CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526';

  /// A valid 65-byte secp256r1 uncompressed public key (0x04 prefix + 64 zeros).
  static Uint8List get validPublicKey {
    final key = Uint8List(65);
    key[0] = 0x04;
    return key;
  }

  /// Returns an [OZConnectWalletConnected] result with fixture data.
  static OZConnectWalletConnected connectedResult({
    String credentialId = defaultCredentialId,
    String contractId = defaultContractId,
    bool restoredFromSession = false,
  }) =>
      OZConnectWalletConnected(
        credentialId: credentialId,
        contractId: contractId,
        restoredFromSession: restoredFromSession,
      );

  /// Returns an [OZConnectWalletAmbiguous] result with two fixture candidates.
  static OZConnectWalletAmbiguous ambiguousResult({
    String credentialId = defaultCredentialId,
    List<String>? candidates,
  }) =>
      OZConnectWalletAmbiguous(
        credentialId: credentialId,
        candidates: candidates ?? [defaultContractId, altContractId],
      );

  /// Returns an [AuthenticatePasskeyResult] with fixture data.
  static AuthenticatePasskeyResult authenticateResult({
    String credentialId = defaultCredentialId,
  }) =>
      AuthenticatePasskeyResult(
        credentialId: credentialId,
        signature: OZWebAuthnSignature(
          authenticatorData: Uint8List(37),
          clientData: Uint8List(0),
          signature: Uint8List(64),
        ),
        publicKey: validPublicKey,
      );

  /// Returns a [DeployPendingResult] with fixture data.
  static DeployPendingResult deployPendingResult({
    String contractId = defaultContractId,
  }) =>
      DeployPendingResult(
        contractId: contractId,
        signedTransactionXdr: 'placeholder_xdr',
        transactionHash: 'abc123txhash',
      );

  /// Returns a [StoredCredential] with fixture data.
  static StoredCredential storedCredential({
    String credentialId = defaultCredentialId,
    String? contractId = defaultContractId,
    String? nickname,
  }) =>
      StoredCredential(
        credentialId: credentialId,
        contractId: contractId,
        publicKey: validPublicKey,
        nickname: nickname,
      );

  /// Builds a [WalletConnectionFlow] with no live state references.
  ///
  /// Uses a fresh [ProviderContainer] with ephemeral notifiers. Suitable for
  /// tests that care only about return values or thrown errors.
  static WalletConnectionFlowDeps makeFlow({
    MockWalletConnectionOperations? walletOps,
    MockCredentialOperations? credentialOps,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);
    final ops = walletOps ?? MockWalletConnectionOperations();
    final creds = credentialOps ?? MockCredentialOperations();
    final flow = WalletConnectionFlow(
      demoState: demoState,
      activityLog: activityLog,
      walletOperations: ops,
      credentialOperations: creds,
    );
    return WalletConnectionFlowDeps(
      flow: flow,
      demoState: demoState,
      activityLog: activityLog,
      container: container,
      walletOps: ops,
      credentialOps: creds,
    );
  }
}

// ---------------------------------------------------------------------------
// WalletConnectionFlowDeps
// ---------------------------------------------------------------------------

/// Dependencies returned by [WalletConnectionFixtures.makeFlow].
final class WalletConnectionFlowDeps {
  const WalletConnectionFlowDeps({
    required this.flow,
    required this.demoState,
    required this.activityLog,
    required this.container,
    required this.walletOps,
    required this.credentialOps,
  });

  final WalletConnectionFlow flow;
  final DemoStateNotifier demoState;
  final ActivityLogNotifier activityLog;
  final ProviderContainer container;
  final MockWalletConnectionOperations walletOps;
  final MockCredentialOperations credentialOps;

  WalletConnectionState get state => demoState.currentState;
  List<LogEntry> get logEntries => container.read(activityLogProvider);
}

// ---------------------------------------------------------------------------
// Error stubs
// ---------------------------------------------------------------------------

/// Simulates a user-cancellation from a passkey ceremony.
WebAuthnCancelled makeCancelledError() =>
    const WebAuthnCancelled(message: 'User cancelled the passkey ceremony.');

/// Simulates a generic network error.
final class MockNetworkError implements Exception {
  @override
  String toString() => 'Network unreachable: socket exception.';
}

/// Simulates a contract-not-found RPC error.
final class MockRpcError implements Exception {
  @override
  String toString() => 'RPC error: contract not found.';
}
