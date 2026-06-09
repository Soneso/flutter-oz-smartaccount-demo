/// Business logic for the main dashboard screen.
///
/// [MainScreenFlow] is the single entry point for kit initialisation, balance
/// refresh, and session teardown on the main screen. The [MainScreen] widget
/// delegates every SDK interaction here; screens must not call into the SDK
/// directly.
///
/// Concurrency:
/// All public methods are `async`. Callers await them from widget callbacks.
/// Mutations to [DemoStateNotifier] are applied directly on the notifier
/// instance, which Riverpod routes safely to the build scheduler.
///
/// Re-entrancy guard:
/// [initializeKit] uses a boolean flag to prevent a second concurrent call
/// from constructing a duplicate kit instance. Any call that arrives while an
/// init is already in flight returns immediately.
///
/// Failure modes (per method):
/// - [initializeKit] — sets [DemoStateNotifier.bootstrapError] on failure;
///   logs to the activity log; never throws to the caller (the screen
///   observes [bootstrapError] via the provider).
/// - [refreshBalances] — catches all errors and logs them; never throws;
///   stale balance labels remain visible while the error is shown in the log.
/// - [disconnect] — best-effort; errors during SDK teardown are logged but
///   the demo state is always cleared regardless so the user is never stuck.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../config/demo_config.dart' as config;
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../token/demo_token_service.dart';
import '../util/format_utils.dart';
import '../util/sac_balance_fetcher.dart';
import '../wallet/demo_ed25519_adapter.dart';
import '../wallet/external_signer_manager_adapter.dart';
import '../wallet/wallet_operations_adapter.dart';

// ---------------------------------------------------------------------------
// MainScreenFlow
// ---------------------------------------------------------------------------

/// Business logic for the main dashboard screen.
///
/// Construct once per screen instance, passing the Riverpod notifiers as
/// direct dependencies. This makes the flow fully unit-testable without
/// requiring a widget environment.
///
/// ```dart
/// // In ConsumerState.initState:
/// _flow = MainScreenFlow(
///   demoState: ref.read(demoStateProvider.notifier),
///   activityLog: ref.read(activityLogProvider.notifier),
/// );
/// ```
class MainScreenFlow {
  /// Constructs a flow with injected dependencies.
  ///
  /// [demoState] is the Riverpod notifier that holds kit, providers, and
  /// connection state. [activityLog] is the notifier that the flow appends
  /// entries to on every significant event.
  ///
  /// The flow does not perform any SDK work at construction time. Call
  /// [initializeKit] from the main screen's [State.initState] to start kit
  /// creation.
  MainScreenFlow({
    required DemoStateNotifier demoState,
    required ActivityLogNotifier activityLog,
    DemoTokenServiceType? demoTokenService,
  })  : _demoState = demoState,
        _activityLog = activityLog,
        _demoTokenService = demoTokenService;

  final DemoStateNotifier _demoState;
  final ActivityLogNotifier _activityLog;

  /// Optional service used by [deployPendingAndProvision] to provision the
  /// DEMO token after the smart-account contract is deployed. When null the
  /// Deploy Now path completes XLM funding but skips DEMO token deploy + mint.
  /// Tests typically leave this null; the production provider wires the
  /// shared [demoTokenServiceProvider].
  final DemoTokenServiceType? _demoTokenService;

  /// Exposes the injected token service so other flows can share the same
  /// instance (e.g. [WalletCreationFlow] reads it via the [MainScreenFlow]
  /// it receives from the wallet-creation screen factory).
  DemoTokenServiceType? get demoTokenService => _demoTokenService;

  // ---- Re-entrancy guard ----

  /// True while [initializeKit] is executing.
  ///
  /// Prevents a second call (e.g. from a re-mount after a hot reload) from
  /// constructing a duplicate kit or racing against an in-flight init.
  bool _isInitializing = false;

  // -------------------------------------------------------------------------
  // Kit initialisation
  // -------------------------------------------------------------------------

  /// Initialises the [OZSmartAccountKit] and registers it in [DemoStateNotifier].
  ///
  /// The method is idempotent: if the kit is already present in
  /// [DemoStateNotifier.kit] or if another call is currently in flight, it
  /// returns immediately.
  ///
  /// On success:
  /// - [DemoStateNotifier.kit] is set to the new kit.
  /// - [DemoStateNotifier.externalAdapter] is set to the shared wallet adapter.
  /// - A global event listener is registered on [kit.events].
  /// - An info entry is appended to the activity log.
  ///
  /// On failure:
  /// - [DemoStateNotifier.bootstrapError] is set to an actionable message.
  /// - An error entry is appended to the activity log.
  /// - The error is not re-thrown (the screen observes [bootstrapError] via
  ///   the provider).
  Future<void> initializeKit() async {
    // Guard: already initialized.
    if (_demoState.kit != null) return;

    // Guard: re-entrancy.
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      // The wallet adapter bridges the active WalletConnector session to the
      // kit's external signer manager. The kit constructs the manager
      // internally from config, so a single shared adapter instance is enough.
      final sharedAdapter = ExternalSignerManagerAdapter()
        ..walletConnector = _demoState.walletConnector;

      // The Ed25519 adapter handles the out-of-process signing path. Keys
      // registered on-demand via kit.externalSigners.addEd25519FromRawKey use
      // the manager's in-process registry and bypass this adapter entirely, so
      // DemoEd25519Adapter.canSignFor returns false for them.
      final demoAdapter = DemoEd25519Adapter();

      final kit = _buildKit(
        externalAdapter: sharedAdapter,
        ed25519Adapter: demoAdapter,
      );

      // Subscribe to kit events BEFORE registering the kit in DemoState so no
      // event emitted synchronously during kit registration is missed.
      _subscribeToKitEvents(kit);

      _demoState.kit = kit;
      _demoState.setExternalAdapter(sharedAdapter);
      _demoState.storeEd25519Adapter(demoAdapter);

      // DEMO token C-address is deterministic (admin keypair + salt are
      // pure constants); deriving it once at init time makes it available
      // to every screen across the kit's lifetime.
      _demoState.updateDemoTokenContract(DemoTokenService.deriveContractAddress());

      _activityLog.success('Smart account kit initialised.');

      // Surface which optional kit features are wired so developers can
      // see at a glance whether they are exercising the relayer + indexer
      // paths or the RPC-only / on-chain-scan fallbacks.
      if (config.defaultRelayerUrl.isNotEmpty) {
        _activityLog.info('Relayer fee sponsoring enabled');
      }
      if (config.defaultIndexerUrl.isNotEmpty) {
        _activityLog.info('Indexer lookup enabled');
      }
    } catch (e) {
      final message = _actionableMessage(e);
      _demoState.setBootstrapError(message);
      _activityLog.error('Failed to initialize SDK: $message');
    } finally {
      _isInitializing = false;
    }
  }

  // -------------------------------------------------------------------------
  // Balance refresh
  // -------------------------------------------------------------------------

  /// Fetches XLM and DEMO token balances for the connected wallet and updates
  /// [DemoStateNotifier].
  ///
  /// Silently exits when no wallet is connected or no kit is present.
  ///
  /// XLM balance is fetched from the native SAC address
  /// ([config.nativeTokenContract]) via a short-lived [SorobanServer].
  ///
  /// DEMO token balance is only fetched when
  /// [WalletConnectionState.demoTokenContractId] is non-null.
  ///
  /// All errors are caught, logged to the activity log at error level, and
  /// never re-thrown. Stale balance labels remain visible.
  Future<void> refreshBalances() async {
    final state = _demoState.currentState;
    if (!state.isConnected) return;
    final contractId = state.contractId;
    if (contractId == null) return;
    if (_demoState.kit == null) return;

    _activityLog.info('Refreshing balances...');

    try {
      final xlm = await SACBalanceFetcher.fetchBalance(
        contract: config.nativeTokenContract,
        account: contractId,
        rpcUrl: config.rpcUrl,
      );
      _demoState.updateXlmBalance(formatStroopsBigIntAsXlm(xlm));
    } catch (e) {
      _activityLog.error(
        'Failed to refresh balance: ${_actionableMessage(e)}',
      );
    }

    final demoTokenContractId = state.demoTokenContractId;
    if (demoTokenContractId != null) {
      try {
        final demo = await SACBalanceFetcher.fetchBalance(
          contract: demoTokenContractId,
          account: contractId,
          rpcUrl: config.rpcUrl,
        );
        _demoState.updateDemoTokenBalance(formatStroopsBigIntAsXlm(demo));
      } catch (e) {
        _activityLog.error(
          'Failed to refresh balance: ${_actionableMessage(e)}',
        );
      }
    }

    _activityLog.info('Balances refreshed.');
  }

  // -------------------------------------------------------------------------
  // Disconnect
  // -------------------------------------------------------------------------

  /// Disconnects the current session, leaving the kit available for reuse.
  ///
  /// Calls [OZSmartAccountKit.disconnect] to clear the kit's stored session,
  /// then toggles connection state to disconnected via
  /// [DemoStateNotifier.setDisconnected]. The kit instance and kit event
  /// subscription are left in place so the next connect flow (Auto Connect,
  /// indexer, or address) can run without re-initialising the SDK.
  ///
  /// SDK teardown errors are caught and logged; connection state is cleared
  /// regardless so the user is never stuck in a partially-connected state.
  Future<void> disconnect() async {
    // Clear the kit's stored session and toggle connection state; the kit and
    // its subscription stay alive for reconnect (see doc comment above).
    final kit = _demoState.kit;
    if (kit != null) {
      try {
        await kit.disconnect();
      } catch (e) {
        _activityLog.error(
          'Disconnect failed: ${_actionableMessage(e)}',
        );
      }
    }

    _demoState.setDisconnected();
    _activityLog.info('Wallet disconnected.');
  }

  // -------------------------------------------------------------------------
  // Deploy pending
  // -------------------------------------------------------------------------

  /// Deploys a pending smart account contract for [credentialId] and
  /// marks the wallet as deployed in [DemoStateNotifier].
  ///
  /// Intended for the `Deploy Now` button on the main-screen undeployed
  /// warning card, and by the result card on the wallet creation screen.
  ///
  /// On success the wallet is funded with XLM (via the SDK's autoFund flow)
  /// and, when a [demoTokenService] is wired, the DEMO token is also
  /// deployed and minted to the new wallet. Both balances are refreshed so
  /// the wallet status card populates immediately.
  ///
  /// On success:
  /// - [DemoStateNotifier.updateDeployed] is set to true.
  /// - [refreshBalances] is called so the XLM balance populates.
  /// - [provisionDemoTokens] is invoked so the DEMO contract id is recorded
  ///   in [DemoStateNotifier] and the DEMO balance label populates. Mint
  ///   failure is non-fatal — the deploy success is preserved.
  /// - Success entries are appended to the activity log.
  ///
  /// On failure of the deploy step itself:
  /// - An error entry is appended to the activity log.
  /// - The error is rethrown so the calling widget can surface it inline
  ///   (e.g. in the warning card's own error display area).
  Future<void> deployPendingAndProvision({
    required String credentialId,
  }) async {
    final kit = _demoState.kit;
    if (kit == null) {
      _activityLog.error('Deployment failed: kit has not been initialised.');
      throw StateError('Cannot deploy: kit has not been initialised.');
    }

    _activityLog.info('Deploying pending contract...');

    try {
      await kit.walletOperations.deployPendingCredential(
        credentialId: credentialId,
        autoFund: true,
        nativeTokenContract: config.nativeTokenContract,
      );
      _demoState.updateDeployed(true);
      _activityLog.success('Contract deployed successfully.');
      await refreshBalances();
    } catch (e) {
      final message = _actionableMessage(e);
      _activityLog.error('Deployment failed: $message');
      rethrow;
    }

    // Provision DEMO tokens for the freshly deployed wallet, mirroring the
    // auto-deploy path in WalletCreationFlow. Failure is non-fatal — the
    // shared helper logs the curated error and returns null.
    final contractId = _demoState.currentState.contractId;
    if (contractId != null) {
      await provisionDemoTokens(
        service: _demoTokenService,
        demoState: _demoState,
        activityLog: _activityLog,
        onRefreshBalances: refreshBalances,
        recipientContractId: contractId,
      );
    }
  }

  // -------------------------------------------------------------------------
  // WalletOperations factory
  // -------------------------------------------------------------------------

  /// Constructs a [WalletOperationsAdapter] wrapping the active kit's wallet
  /// operations manager.
  ///
  /// Returns null when no kit is present in [DemoStateNotifier]. The caller
  /// is responsible for handling the null case (typically by showing an error
  /// and aborting the creation flow).
  ///
  /// Centralising construction here keeps kit manager accessors out of screen
  /// files and satisfies the screens-never-call-SDK architecture rule.
  WalletOperationsAdapter? buildWalletOperations() {
    final kit = _demoState.kit;
    if (kit == null) return null;
    return WalletOperationsAdapter(kit.walletOperations);
  }

  // -------------------------------------------------------------------------
  // Private: kit construction
  // -------------------------------------------------------------------------

  /// Builds the [OZSmartAccountConfig] and kit from [config] and the
  /// platform providers that were injected at app startup.
  ///
  /// [externalAdapter] is the wallet-connector bridge for signing requests
  /// that must be routed to Freighter (web) or a Reown-compatible wallet
  /// (native). The kit injects it into its owned [OZExternalSignerManager].
  ///
  /// [ed25519Adapter] is the out-of-process Ed25519 signing bridge. The kit
  /// injects it into its owned manager as [OZSmartAccountConfig.externalEd25519Adapter].
  /// In-memory Ed25519 keys registered at runtime via
  /// [OZExternalSignerManager.addEd25519FromRawKey] bypass this adapter
  /// (the manager's in-process registry handles them) — [ed25519Adapter]
  /// only handles keys that the demo intentionally keeps out-of-process.
  ///
  /// Throws [BootstrapError] when the App entry point did not inject the
  /// providers. Throws [SmartAccountConfigurationException] when [config] constants are
  /// invalid.
  OZSmartAccountKit _buildKit({
    required ExternalSignerManagerAdapter externalAdapter,
    required DemoEd25519Adapter ed25519Adapter,
  }) {
    final webAuthnProvider = _demoState.webAuthnProvider;
    if (webAuthnProvider == null) {
      throw const BootstrapError(
        'WebAuthn provider was not injected. Check main.dart.',
      );
    }
    final storage = _demoState.storage;
    if (storage == null) {
      throw const BootstrapError(
        'Storage adapter was not injected. Check main.dart.',
      );
    }

    final kitConfig = OZSmartAccountConfig(
      rpcUrl: config.rpcUrl,
      networkPassphrase: config.networkPassphrase,
      accountWasmHash: config.accountWasmHash,
      webauthnVerifierAddress: config.webauthnVerifierAddress,
      // Empty URL strings disable the corresponding optional feature: the
      // kit treats `null` as absent, falls back to the RPC-only submission
      // path (no relayer) and the on-chain scan path (no indexer).
      relayerUrl: config.defaultRelayerUrl.isEmpty
          ? null
          : config.defaultRelayerUrl,
      indexerUrl: config.defaultIndexerUrl.isEmpty
          ? null
          : config.defaultIndexerUrl,
      webauthnProvider: webAuthnProvider,
      storage: storage,
      externalWallet: externalAdapter,
      externalEd25519Adapter: ed25519Adapter,
      maxContextRuleScanId: config.maxContextRuleScanId,
    );

    return OZSmartAccountKit.create(config: kitConfig);
  }

  // -------------------------------------------------------------------------
  // Private: kit event subscription
  // -------------------------------------------------------------------------

  /// Registers a global listener on [kit.events] that pipes each emitted
  /// event into the activity log. Each event is converted to a human-readable
  /// entry at appropriate severity. Sensitive values (credential IDs) are
  /// redacted via [redactId].
  void _subscribeToKitEvents(OZSmartAccountKit kit) {
    kit.events.addListener((event) {
      final (level, message) = describeKitEvent(event);
      _activityLog.addEntry(message, level: level);
    });
  }

  // -------------------------------------------------------------------------
  // Kit event description (pure, static — testable without a flow instance)
  // -------------------------------------------------------------------------

  /// Converts a [OZSmartAccountEvent] to a [(LogLevel, String)] pair.
  ///
  /// Extracted as a pure static method so tests can verify each mapping
  /// independently without setting up a full kit or flow instance.
  ///
  /// Credential IDs are truncated via [redactId].
  /// Transaction hashes are allowed in full (public on-chain identifiers).
  static (LogLevel, String) describeKitEvent(OZSmartAccountEvent event) {
    if (event is OZSmartAccountEventWalletConnected) {
      final safeCredId = redactId(event.credentialId);
      return (
        LogLevel.success,
        'Wallet connected: ${truncateAddress(event.contractId)} '
            '(cred: $safeCredId)',
      );
    }
    if (event is OZSmartAccountEventWalletDisconnected) {
      return (
        LogLevel.info,
        'Wallet disconnected: ${truncateAddress(event.contractId)}',
      );
    }
    if (event is OZSmartAccountEventCredentialCreated) {
      final safeCredId = redactId(event.credential.credentialId);
      return (LogLevel.success, 'Credential registered: $safeCredId');
    }
    if (event is OZSmartAccountEventCredentialDeleted) {
      final safeCredId = redactId(event.credentialId);
      return (LogLevel.info, 'Credential removed: $safeCredId');
    }
    if (event is OZSmartAccountEventSessionExpired) {
      final safeCredId = redactId(event.credentialId);
      return (
        LogLevel.error,
        'Session expired for ${truncateAddress(event.contractId)} '
            '(cred: $safeCredId). Please reconnect.',
      );
    }
    if (event is OZSmartAccountEventTransactionSigned) {
      final credDesc = event.credentialId != null
          ? redactId(event.credentialId!)
          : 'external';
      return (
        LogLevel.info,
        'Transaction signed for ${truncateAddress(event.contractId)} '
            'via $credDesc',
      );
    }
    if (event is OZSmartAccountEventTransactionSubmitted) {
      // Transaction hashes are public on-chain identifiers — no redaction.
      final level = event.success ? LogLevel.success : LogLevel.error;
      final prefix = event.hash.length > 16
          ? '${event.hash.substring(0, 16)}...'
          : event.hash;
      final msg = event.success
          ? 'Transaction submitted: $prefix'
          : 'Transaction submission failed: $prefix';
      return (level, msg);
    }
    if (event is OZSmartAccountEventCredentialSyncFailed) {
      final safeCredId = redactId(event.credentialId);
      return (
        LogLevel.error,
        'Credential sync failed for $safeCredId: '
            '${_actionableMessage(event.error)}',
      );
    }
    // Fallback for any future event types added to the SDK.
    return (LogLevel.info, 'Kit event: ${event.eventTypeName}');
  }

  // -------------------------------------------------------------------------
  // Private: helpers
  // -------------------------------------------------------------------------

  /// Converts any exception to a short, actionable message safe for the UI.
  static String _actionableMessage(Object error) {
    if (error is BootstrapError) return error.message;
    if (error is SACBalanceFetcherError) return error.message;
    if (error is SmartAccountConfigurationException) {
      return 'Configuration error: ${error.message}';
    }
    // Avoid surfacing raw SDK exception messages (may contain XDR/RPC payload
    // fragments). Use a category-level description instead.
    final raw = error.toString().toLowerCase();
    if (raw.contains('network') ||
        raw.contains('socket') ||
        raw.contains('timeout')) {
      return 'Network error. Check your connection and try again.';
    }
    return 'An unexpected error occurred. Please try again.';
  }
}

// ---------------------------------------------------------------------------
// BootstrapError
// ---------------------------------------------------------------------------

/// Thrown by [MainScreenFlow._buildKit] when a required platform provider was
/// not injected before kit initialisation was attempted.
///
/// This is a programming error that occurs when the [main.dart] entry point
/// does not set [DemoStateNotifier.webAuthnProvider] or
/// [DemoStateNotifier.storage] before the first frame renders. It surfaces via
/// [DemoStateNotifier.bootstrapError] rather than propagating to caller code.
final class BootstrapError implements Exception {
  /// Constructs a bootstrap error with an actionable [message].
  const BootstrapError(this.message);

  /// Short, actionable description of why initialisation failed.
  final String message;

  @override
  String toString() => 'BootstrapError: $message';
}
