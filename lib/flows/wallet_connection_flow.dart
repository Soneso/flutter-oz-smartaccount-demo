/// Business logic for connecting to an existing smart account wallet.
///
/// [WalletConnectionFlow] is the single entry point for all wallet connection
/// strategies. The [WalletConnectionScreen] delegates every SDK interaction
/// here; screens must not call into the SDK directly.
///
/// Connection strategies:
/// - [autoConnect] — session restore with WebAuthn fallback.
/// - [connectViaIndexer] — explicit WebAuthn then indexer lookup.
/// - [connectWithAddress] — explicit WebAuthn then direct contract address.
/// - [finalizeAmbiguous] — resolve picker selection after Ambiguous result.
/// - [retryPendingDeploy] — deploy a pending credential that failed earlier.
/// - [deletePendingCredential] — remove a pending credential from storage.
/// - [loadPendingCredentials] — list pending (undeployed) credentials.
///
/// Screens-never-call-SDK rule:
/// This file and its callers must not reference kit manager accessors directly.
/// Only flows call into the SDK; screens call only flow methods.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../config/demo_config.dart' as config;
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../token/demo_token_service.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import 'main_screen_flow.dart';

// ---------------------------------------------------------------------------
// ConnectionResult
// ---------------------------------------------------------------------------

/// Outcome of a [WalletConnectionFlow] connect call.
sealed class ConnectionResult {
  const ConnectionResult();
}

/// The connection resolved to a single contract.
final class ConnectionResultConnected extends ConnectionResult {
  /// Constructs a connected result.
  const ConnectionResultConnected({
    required this.credentialId,
    required this.contractId,
    required this.isDeployed,
    required this.restoredFromSession,
  });

  /// Base64URL-encoded WebAuthn credential ID.
  final String credentialId;

  /// Smart account contract address (C-address).
  final String contractId;

  /// Whether the contract is confirmed deployed on-chain.
  final bool isDeployed;

  /// Whether the connection was restored from a saved session.
  final bool restoredFromSession;
}

/// The credential is registered on more than one contract; user must pick one.
final class ConnectionResultAmbiguous extends ConnectionResult {
  /// Constructs an ambiguous result with a list of candidate contract addresses.
  const ConnectionResultAmbiguous({
    required this.credentialId,
    required this.candidates,
  });

  /// Base64URL-encoded WebAuthn credential ID.
  final String credentialId;

  /// Candidate contract addresses (C-addresses) returned by the indexer.
  final List<String> candidates;
}

// ---------------------------------------------------------------------------
// WalletConnectionSection
// ---------------------------------------------------------------------------

/// Identifies which connection section is in-flight in the screen.
enum ConnectionSection {
  /// Section A — auto connect.
  auto,

  /// Section B — connect via indexer.
  indexer,

  /// Section C — connect with explicit contract address.
  address,

  /// Section D — pending deployment action.
  pending,
}

// ---------------------------------------------------------------------------
// CredentialOperationsType
// ---------------------------------------------------------------------------

/// Abstraction over credential and context-rule manager operations.
///
/// Separates testable credential operations from [WalletConnectionFlow] so
/// tests can inject mocks without a live kit.
abstract interface class CredentialOperationsType {
  /// Returns all credentials that are still pending on-chain deployment.
  Future<List<OZStoredCredential>> getPendingCredentials();

  /// Permanently deletes [credentialId] from local storage.
  Future<void> deleteCredential({required String credentialId});

  /// Checks whether the currently-connected contract is deployed on-chain.
  ///
  /// Calls `contextRuleManager.getContextRulesCount()`. Any thrown error is
  /// treated as not deployed.
  Future<bool> isDeployed();
}

// ---------------------------------------------------------------------------
// CredentialOperationsAdapter
// ---------------------------------------------------------------------------

/// Production adapter that forwards [CredentialOperationsType] calls to the
/// underlying [OZCredentialManager] and [OZContextRuleManager].
final class CredentialOperationsAdapter implements CredentialOperationsType {
  /// Constructs an adapter from a live kit.
  const CredentialOperationsAdapter(this._kit);

  final OZSmartAccountKit _kit;

  @override
  Future<List<OZStoredCredential>> getPendingCredentials() =>
      _kit.credentialManager.getPendingCredentials();

  @override
  Future<void> deleteCredential({required String credentialId}) =>
      _kit.credentialManager.deleteCredential(credentialId: credentialId);

  @override
  Future<bool> isDeployed() async {
    try {
      await _kit.contextRuleManager.getContextRulesCount();
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// WalletConnectionOperationsType
// ---------------------------------------------------------------------------

/// Abstraction over wallet operations used by [WalletConnectionFlow].
///
/// Exposes only the subset of [OZWalletOperations] that the flow requires.
/// Tests inject a mock; production code uses [WalletConnectionOperationsAdapter].
abstract interface class WalletConnectionOperationsType {
  /// Connects to a wallet using the supplied options.
  Future<OZConnectWalletResult?> connectWallet({
    required OZConnectWalletOptions options,
  });

  /// Authenticates with a passkey and returns the credential ID.
  Future<OZAuthenticatePasskeyResult> authenticatePasskey();

  /// Deploys a pending credential (retry or deferred deploy).
  ///
  /// When [autoFund] is true the SDK funds the new contract with XLM via
  /// FriendBot using [nativeTokenContract] as the SAC address. Passing
  /// [autoFund] without [nativeTokenContract] raises a validation error
  /// inside the SDK.
  Future<OZDeployPendingResult> deployPendingCredential({
    required String credentialId,
    bool autoFund = false,
    String? nativeTokenContract,
  });
}

// ---------------------------------------------------------------------------
// WalletConnectionOperationsAdapter
// ---------------------------------------------------------------------------

/// Production adapter that forwards [WalletConnectionOperationsType] calls to
/// the underlying [OZWalletOperations].
final class WalletConnectionOperationsAdapter
    implements WalletConnectionOperationsType {
  /// Constructs an adapter wrapping [inner].
  const WalletConnectionOperationsAdapter(this._inner);

  final OZWalletOperations _inner;

  @override
  Future<OZConnectWalletResult?> connectWallet({
    required OZConnectWalletOptions options,
  }) =>
      _inner.connectWallet(options: options);

  @override
  Future<OZAuthenticatePasskeyResult> authenticatePasskey() =>
      _inner.authenticatePasskey();

  @override
  Future<OZDeployPendingResult> deployPendingCredential({
    required String credentialId,
    bool autoFund = false,
    String? nativeTokenContract,
  }) =>
      _inner.deployPendingCredential(
        credentialId: credentialId,
        autoFund: autoFund,
        nativeTokenContract: nativeTokenContract,
      );
}

// ---------------------------------------------------------------------------
// WalletConnectionFlow
// ---------------------------------------------------------------------------

/// Business logic for the wallet connection screen.
///
/// Construct once per screen instance, passing the Riverpod notifiers and
/// required SDK adapters. This makes the flow fully unit-testable without
/// requiring a widget environment.
///
/// See [WalletConnectionScreen] for a usage example.
final class WalletConnectionFlow {
  /// Constructs a flow with injected dependencies.
  WalletConnectionFlow({
    required DemoStateNotifier demoState,
    required ActivityLogNotifier activityLog,
    required WalletConnectionOperationsType walletOperations,
    required CredentialOperationsType credentialOperations,
    MainScreenFlow? mainScreenFlow,
  })  : _demoState = demoState,
        _activityLog = activityLog,
        _walletOperations = walletOperations,
        _credentialOperations = credentialOperations,
        _mainScreenFlow = mainScreenFlow;

  final DemoStateNotifier _demoState;
  final ActivityLogNotifier _activityLog;
  final WalletConnectionOperationsType _walletOperations;
  final CredentialOperationsType _credentialOperations;
  final MainScreenFlow? _mainScreenFlow;

  // -------------------------------------------------------------------------
  // Public: autoConnect
  // -------------------------------------------------------------------------

  /// Connects using a saved session or triggers WebAuthn if none exists.
  ///
  /// Path A: calls `connectWallet(prompt: true)` so the SDK restores from
  /// session or falls back to a WebAuthn ceremony.
  ///
  /// Returns [ConnectionResultConnected] on single-contract resolution,
  /// [ConnectionResultAmbiguous] when multiple contracts are found,
  /// or null when no wallet was found for this passkey.
  ///
  /// Throws [WebAuthnCancelled] when the user dismisses the passkey sheet.
  /// Throws on hard RPC or network errors.
  Future<ConnectionResult?> autoConnect() async {
    _activityLog.info('Auto connect: restoring session or prompting passkey...');
    try {
      final sdkResult = await _walletOperations.connectWallet(
        options: const OZConnectWalletOptions(prompt: true),
      );
      if (sdkResult == null) {
        _activityLog.info('Auto connect: no wallet found for this passkey.');
        return null;
      }
      return await _handleConnectResult(sdkResult);
    } on WebAuthnCancelled {
      _activityLog.info('Passkey authentication cancelled');
      rethrow;
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Auto connect failed: ${classified.message}');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Public: connectViaIndexer
  // -------------------------------------------------------------------------

  /// Authenticates with a passkey, then resolves the contract via the indexer.
  ///
  /// Path B: always triggers WebAuthn, then calls `connectWallet(credentialId:)`.
  ///
  /// Returns [ConnectionResultConnected] or [ConnectionResultAmbiguous] (multiple
  /// contracts found), or null when the indexer returns no results.
  ///
  /// Throws [WebAuthnCancelled] on user cancellation.
  Future<ConnectionResult?> connectViaIndexer() async {
    _activityLog.info('Connect via indexer: authenticating passkey...');
    final OZAuthenticatePasskeyResult authResult;
    try {
      authResult = await _walletOperations.authenticatePasskey();
    } on WebAuthnCancelled {
      _activityLog.info('Passkey authentication cancelled');
      rethrow;
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Passkey authentication failed: ${classified.message}');
      rethrow;
    }

    _activityLog.info('Passkey authenticated. Looking up contract via indexer...');
    try {
      final sdkResult = await _walletOperations.connectWallet(
        options: OZConnectWalletOptions(credentialId: authResult.credentialId),
      );
      if (sdkResult == null) {
        _activityLog.info('Indexer: no contract found for this credential.');
        return null;
      }
      return await _handleConnectResult(sdkResult);
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Indexer connect failed: ${classified.message}');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Public: connectWithAddress
  // -------------------------------------------------------------------------

  /// Authenticates with a passkey, then connects directly to [contractAddress].
  ///
  /// Path C: always triggers WebAuthn, then calls
  /// `connectWallet(credentialId:contractId:)`.
  ///
  /// Returns [ConnectionResultConnected] on success, null when the contract
  /// was not found or the credential is not registered on it.
  ///
  /// Throws [WebAuthnCancelled] on user cancellation.
  Future<ConnectionResultConnected?> connectWithAddress(
    String contractAddress,
  ) async {
    _activityLog.info(
      'Connect with address: authenticating passkey for '
      '${truncateAddress(contractAddress)}...',
    );
    final OZAuthenticatePasskeyResult authResult;
    try {
      authResult = await _walletOperations.authenticatePasskey();
    } on WebAuthnCancelled {
      _activityLog.info('Passkey authentication cancelled');
      rethrow;
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Passkey authentication failed: ${classified.message}');
      rethrow;
    }

    _activityLog.info('Passkey authenticated. Connecting to contract...');
    try {
      final sdkResult = await _walletOperations.connectWallet(
        options: OZConnectWalletOptions(
          credentialId: authResult.credentialId,
          contractId: contractAddress,
        ),
      );
      if (sdkResult == null) {
        _activityLog.info('Could not connect to the provided contract address.');
        return null;
      }
      final result = await _handleConnectResult(sdkResult);
      if (result is ConnectionResultConnected) return result;
      // Ambiguous result is not possible when an explicit contractId is
      // supplied — the SDK always returns Connected or null in that path.
      return null;
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Address connect failed: ${classified.message}');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Public: finalizeAmbiguous
  // -------------------------------------------------------------------------

  /// Resolves an Ambiguous result by connecting to the user-selected address.
  ///
  /// Called after [ContractPickerSheet] returns a [contractAddress]. Calls
  /// `connectWallet(credentialId:contractId:)` without re-prompting WebAuthn.
  ///
  /// Returns [ConnectionResultConnected] on success, null when the contract
  /// was not found.
  Future<ConnectionResultConnected?> finalizeAmbiguous({
    required String credentialId,
    required String contractAddress,
  }) async {
    _activityLog.info(
      'Finalizing wallet selection: ${truncateAddress(contractAddress)}...',
    );
    try {
      final sdkResult = await _walletOperations.connectWallet(
        options: OZConnectWalletOptions(
          credentialId: credentialId,
          contractId: contractAddress,
        ),
      );
      if (sdkResult == null) {
        _activityLog.info('Selected contract not found.');
        return null;
      }
      final result = await _handleConnectResult(sdkResult);
      if (result is ConnectionResultConnected) return result;
      return null;
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Wallet selection failed: ${classified.message}');
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Public: retryPendingDeploy
  // -------------------------------------------------------------------------

  /// Retries the on-chain deployment for a pending credential.
  ///
  /// Path D: calls `deployPendingCredential(autoFund: true,
  /// nativeTokenContract: ...)` so the wallet is funded with XLM as part of
  /// the deploy, then refreshes balances and provisions DEMO tokens via the
  /// shared helper so the user gets the same end-state as the auto-deploy
  /// path on the creation screen. DEMO mint failure is non-fatal — the deploy
  /// success is preserved.
  ///
  /// Returns [ConnectionResultConnected] on success.
  /// Throws on deploy-step SDK or network failure (DEMO mint failures are
  /// caught inside the shared helper).
  Future<ConnectionResultConnected> retryPendingDeploy({
    required String credentialId,
  }) async {
    final safeCredId = redactId(credentialId);
    _activityLog.info('Retrying deployment for credential $safeCredId...');
    final ConnectionResultConnected connected;
    try {
      final deployResult = await _walletOperations.deployPendingCredential(
        credentialId: credentialId,
        autoFund: true,
        nativeTokenContract: config.nativeTokenContract,
      );
      final deployed = await _credentialOperations.isDeployed();
      _demoState.setConnected(
        contractId: deployResult.contractId,
        credentialId: credentialId,
        isDeployed: deployed,
      );
      _activityLog.success(
        'Deployment succeeded: ${truncateAddress(deployResult.contractId)}',
      );
      await _mainScreenFlow?.refreshBalances();
      connected = ConnectionResultConnected(
        credentialId: credentialId,
        contractId: deployResult.contractId,
        isDeployed: deployed,
        restoredFromSession: false,
      );
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Deployment failed: ${classified.message}');
      // The SDK may have pre-set connected state before submitting the deploy
      // transaction. On failure, revert to disconnected so DemoState and the
      // kit's internal state are consistent.
      _demoState.setDisconnected();
      rethrow;
    }

    // Provision DEMO tokens for the freshly deployed wallet, mirroring the
    // auto-deploy + main-screen Deploy Now paths. Reads the shared token
    // service via the injected MainScreenFlow so all three deploy entry
    // points operate on a single DemoTokenService instance.
    await provisionDemoTokens(
      service: _mainScreenFlow?.demoTokenService,
      demoState: _demoState,
      activityLog: _activityLog,
      onRefreshBalances: () async =>
          _mainScreenFlow?.refreshBalances() ?? Future<void>.value(),
      recipientContractId: connected.contractId,
    );

    return connected;
  }

  // -------------------------------------------------------------------------
  // Public: loadPendingCredentials
  // -------------------------------------------------------------------------

  /// Loads all credentials that have a stored public key and contract ID but
  /// whose on-chain deployment has not been confirmed.
  Future<List<OZStoredCredential>> loadPendingCredentials() async {
    try {
      return await _credentialOperations.getPendingCredentials();
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error(
        'Failed to load pending credentials: ${classified.message}',
      );
      return const [];
    }
  }

  // -------------------------------------------------------------------------
  // Public: deletePendingCredential
  // -------------------------------------------------------------------------

  /// Permanently removes [credentialId] from local storage.
  ///
  /// Returns true on success, false when the deletion fails (error is logged
  /// but not rethrown so the screen can show an inline per-card message).
  Future<bool> deletePendingCredential({required String credentialId}) async {
    final safeCredId = redactId(credentialId);
    _activityLog.info('Deleting credential $safeCredId...');
    try {
      await _credentialOperations.deleteCredential(credentialId: credentialId);
      _activityLog.info('Credential $safeCredId deleted.');
      return true;
    } catch (e) {
      final classified = classifyError(e);
      _activityLog.error('Delete failed: ${classified.message}');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Private: _handleConnectResult
  // -------------------------------------------------------------------------

  /// Translates a raw [OZConnectWalletResult] to a [ConnectionResult].
  ///
  /// For [OZConnectWalletConnected]: probes the chain for deployment status,
  /// writes to [DemoStateNotifier], calls [MainScreenFlow.refreshBalances],
  /// and returns [ConnectionResultConnected].
  ///
  /// For [OZConnectWalletAmbiguous]: returns [ConnectionResultAmbiguous] without
  /// mutating demo state (the user must pick from the picker first).
  Future<ConnectionResult> _handleConnectResult(
    OZConnectWalletResult sdkResult,
  ) async {
    if (sdkResult is OZConnectWalletAmbiguous) {
      _activityLog.info(
        'Multiple wallets found for this passkey. Please select one.',
      );
      return ConnectionResultAmbiguous(
        credentialId: sdkResult.credentialId,
        candidates: sdkResult.candidates,
      );
    }

    final connected = sdkResult as OZConnectWalletConnected;
    // isDeployed probes the chain; any error is treated as not deployed so the
    // connection still succeeds and Section D shows the retry option.
    bool deployed;
    try {
      deployed = await _credentialOperations.isDeployed();
    } catch (_) {
      deployed = false;
    }
    _demoState.setConnected(
      contractId: connected.contractId,
      credentialId: connected.credentialId,
      isDeployed: deployed,
    );
    if (deployed) {
      await _mainScreenFlow?.refreshBalances();
    }
    final shortAddr = truncateAddress(connected.contractId);
    final safeCredId = redactId(connected.credentialId);
    if (connected.restoredFromSession) {
      _activityLog.success(
        'Session restored: $shortAddr (cred: $safeCredId)',
      );
    } else {
      _activityLog.success(
        'Wallet connected: $shortAddr (cred: $safeCredId)',
      );
    }
    return ConnectionResultConnected(
      credentialId: connected.credentialId,
      contractId: connected.contractId,
      isDeployed: deployed,
      restoredFromSession: connected.restoredFromSession,
    );
  }
}

// ---------------------------------------------------------------------------
// WalletConnectionFlowFactory
// ---------------------------------------------------------------------------

/// Helper that builds a [WalletConnectionFlow] from the active kit in
/// [DemoStateNotifier].
///
/// Returns null when no kit is present.
WalletConnectionFlow? buildWalletConnectionFlow({
  required DemoStateNotifier demoState,
  required ActivityLogNotifier activityLog,
  MainScreenFlow? mainScreenFlow,
}) {
  final kit = demoState.kit;
  if (kit == null) return null;
  return WalletConnectionFlow(
    demoState: demoState,
    activityLog: activityLog,
    walletOperations: WalletConnectionOperationsAdapter(kit.walletOperations),
    credentialOperations: CredentialOperationsAdapter(kit),
    mainScreenFlow: mainScreenFlow,
  );
}
