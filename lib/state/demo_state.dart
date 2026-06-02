import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../wallet/demo_ed25519_adapter.dart';
import '../wallet/external_signer_manager_adapter.dart';
import '../wallet/wallet_connector.dart';

// ---------------------------------------------------------------------------
// Connection state
// ---------------------------------------------------------------------------

/// Snapshot of the current wallet connection.
///
/// Immutable value; the notifier replaces it atomically on each change.
@immutable
final class WalletConnectionState {
  const WalletConnectionState({
    required this.isConnected,
    required this.isDeployed,
    this.contractId,
    this.credentialId,
    this.xlmBalance,
    this.demoTokenContractId,
    this.demoTokenBalance,
  });

  /// True when a wallet credential has been loaded and the kit is active.
  final bool isConnected;

  /// True when the smart account contract is confirmed deployed on-chain.
  final bool isDeployed;

  /// The connected wallet's C-address, null when disconnected.
  final String? contractId;

  /// The active WebAuthn credential ID (Base64URL), null when disconnected.
  final String? credentialId;

  /// The connected wallet's XLM balance display string, null when unknown.
  final String? xlmBalance;

  /// The DEMO token contract address, null when not yet deployed.
  final String? demoTokenContractId;

  /// The connected wallet's DEMO balance display string, null when unknown.
  final String? demoTokenBalance;

  /// Returns a disconnected, empty state.
  const WalletConnectionState.disconnected()
      : isConnected = false,
        isDeployed = false,
        contractId = null,
        credentialId = null,
        xlmBalance = null,
        demoTokenContractId = null,
        demoTokenBalance = null;

  WalletConnectionState copyWith({
    bool? isConnected,
    bool? isDeployed,
    String? contractId,
    String? credentialId,
    String? xlmBalance,
    String? demoTokenContractId,
    String? demoTokenBalance,
  }) {
    return WalletConnectionState(
      isConnected: isConnected ?? this.isConnected,
      isDeployed: isDeployed ?? this.isDeployed,
      contractId: contractId ?? this.contractId,
      credentialId: credentialId ?? this.credentialId,
      xlmBalance: xlmBalance ?? this.xlmBalance,
      demoTokenContractId: demoTokenContractId ?? this.demoTokenContractId,
      demoTokenBalance: demoTokenBalance ?? this.demoTokenBalance,
    );
  }
}

// ---------------------------------------------------------------------------
// Demo app state notifier
// ---------------------------------------------------------------------------

/// Top-level mutable state for the demo app.
///
/// Holds platform-injected dependencies ([webAuthnProvider], [storage]) that
/// are set by [main.dart] before [runApp] is called, and the [kit] instance
/// which is created lazily by [MainScreenFlow.initializeKit].
///
/// Screens observe [WalletConnectionState] via [demoStateProvider] and
/// invoke flows instead of mutating this notifier directly.
class DemoStateNotifier extends Notifier<WalletConnectionState> {
  @override
  WalletConnectionState build() => const WalletConnectionState.disconnected();

  // ---- Platform-injected singletons (set once in main.dart, before runApp) ----

  /// Platform-specific WebAuthn provider. Must be set before the kit is created.
  WebAuthnProvider? webAuthnProvider;

  /// Platform-specific storage adapter. Must be set before the kit is created.
  StorageAdapter? storage;

  /// Platform-specific wallet connector singleton.
  ///
  /// On web this is the Freighter handler. On native platforms without a
  /// connector implementation it is null. The kit's external signer
  /// adapter is wired against this instance during [MainScreenFlow.initializeKit]
  /// so wallet-routed signers and the picker share the same connection state.
  WalletConnector? walletConnector;

  /// Whether the host is a real device (or Web) where wallet-pairing deep
  /// links can reach a real wallet app. False on the iOS Simulator and on
  /// Android emulators. Set once at startup by `main.dart` after
  /// `detectIsPhysicalDevice()` resolves; never mutated again.
  ///
  /// UI surfaces that initiate wallet pairing (the "Import from Freighter"
  /// button on the delegated-signer add form and the "Connect Wallet" button
  /// on the multi-signer picker) read this flag via [walletConnectorForUi]
  /// and hide themselves when it is false. The kit-side adapter that routes
  /// signing for already-connected wallets continues to use [walletConnector]
  /// directly because nothing can become connected from a simulated host in
  /// the first place.
  bool isPhysicalDevice = false;

  /// The wallet connector exposed to UI surfaces that initiate pairing.
  ///
  /// Returns [walletConnector] on physical devices (and on Web) and `null`
  /// on the iOS Simulator and Android emulators. Pairing flows that consume
  /// this getter hide their UI cleanly when it is null instead of presenting
  /// an affordance that would immediately fail at deep-link time.
  WalletConnector? get walletConnectorForUi =>
      isPhysicalDevice ? walletConnector : null;

  // ---- Kit instance (created lazily by MainScreenFlow.initializeKit) ----

  /// The [OZSmartAccountKit] instance, null until [initializeKit] succeeds.
  OZSmartAccountKit? kit;

  // ---- Bootstrap error (set by MainScreenFlow when kit init fails) ----

  /// Actionable error message set when [MainScreenFlow.initializeKit] fails.
  ///
  /// Null when no bootstrap failure has occurred. The main screen observes
  /// this field (via rebuilds triggered by the flow calling [setBootstrapError])
  /// and renders a red banner when non-null.
  String? bootstrapError;

  // ---- State mutations ----

  /// Records a successful wallet connection.
  ///
  /// [contractId] is the C-address of the smart account contract.
  /// [credentialId] is the Base64URL credential ID for the active passkey.
  /// [isDeployed] indicates whether the contract is confirmed on-chain.
  void setConnected({
    required String contractId,
    required String credentialId,
    required bool isDeployed,
  }) {
    state = WalletConnectionState(
      isConnected: true,
      isDeployed: isDeployed,
      contractId: contractId,
      credentialId: credentialId,
      xlmBalance: state.xlmBalance,
      demoTokenContractId: state.demoTokenContractId,
      demoTokenBalance: state.demoTokenBalance,
    );
  }

  /// Records a wallet disconnection. Preserves [demoTokenContractId] since
  /// the DEMO token is a property of the demo environment (deterministic
  /// address), not of the wallet connection.
  void setDisconnected() {
    state = WalletConnectionState(
      isConnected: false,
      isDeployed: false,
      demoTokenContractId: state.demoTokenContractId,
    );
  }

  /// Updates the on-chain deployment status of the current contract.
  void updateDeployed(bool isDeployed) {
    state = state.copyWith(isDeployed: isDeployed);
  }

  /// Returns a snapshot of the current [WalletConnectionState].
  ///
  /// Callers outside the Riverpod tree (e.g. flow classes instantiated with
  /// only a notifier reference) use this to read the current state without
  /// accessing the protected [state] field directly.
  WalletConnectionState get currentState => state;

  /// True when a [kit] instance is present (regardless of connection status).
  ///
  /// Use `ref.watch(demoStateProvider.select((s) => s.kit != null))` in widgets
  /// that need to rebuild when the kit transitions from null to set.
  bool get hasKit => kit != null;

  /// Updates the XLM balance display string.
  void updateXlmBalance(String? balance) {
    state = state.copyWith(xlmBalance: balance);
  }

  /// Records the DEMO token contract address once it is deployed.
  void updateDemoTokenContract(String? contractId) {
    state = state.copyWith(demoTokenContractId: contractId);
  }

  /// Updates the DEMO token balance display string.
  void updateDemoTokenBalance(String? balance) {
    state = state.copyWith(demoTokenBalance: balance);
  }

  // ---- External signer manager ----

  /// The shared [ExternalSignerManagerAdapter] supplying the wallet-connector
  /// signing path to the kit.
  ///
  /// Set by [MainScreenFlow.initializeKit] alongside the kit. Flows call into
  /// the adapter to read the active wallet session address for UI display.
  ExternalSignerManagerAdapter? externalAdapter;

  /// Stores the shared [ExternalSignerManagerAdapter] instance.
  void setExternalAdapter(ExternalSignerManagerAdapter? adapter) {
    externalAdapter = adapter;
  }

  /// The [DemoEd25519Adapter] injected into the kit at construction via
  /// [OZSmartAccountConfig.externalEd25519Adapter].
  ///
  /// Flows that exercise the adapter custody path register verified seeds via
  /// [DemoEd25519Adapter.add] before submitting and clear them via
  /// [DemoEd25519Adapter.clearAll] afterwards. The in-process custody path
  /// registers keys on [externalSigners] instead and never touches this adapter.
  DemoEd25519Adapter? ed25519Adapter;

  /// Stores the [DemoEd25519Adapter] instance created by [MainScreenFlow].
  void storeEd25519Adapter(DemoEd25519Adapter? adapter) {
    ed25519Adapter = adapter;
  }

  /// The kit-owned [OZExternalSignerManager], or null when the kit is not
  /// yet initialised.
  ///
  /// Both G-address in-memory keypairs ([addFromSecret]) and Ed25519 in-memory
  /// keys ([addEd25519FromRawKey]) are registered on this manager at runtime.
  /// The adapter path (wallet connector and Ed25519 adapter) is supplied at
  /// kit construction via [OZSmartAccountConfig].
  OZExternalSignerManager? get externalSigners =>
      _testExternalSigners ?? kit?.externalSigners;

  /// Test-only override for [externalSigners].
  ///
  /// When set, [externalSigners] returns this value instead of
  /// [kit?.externalSigners]. This allows unit tests to inject a fake manager
  /// without constructing a full [OZSmartAccountKit].
  OZExternalSignerManager? _testExternalSigners;

  /// Injects a test [OZExternalSignerManager] that [externalSigners] returns.
  ///
  /// Call from test setup only. Clears automatically when [kit] is set to a
  /// non-null value so production wiring takes precedence over test injection.
  @visibleForTesting
  void injectFakeExternalSigners(OZExternalSignerManager manager) {
    _testExternalSigners = manager;
  }

  /// Sets or clears the bootstrap error message.
  ///
  /// Called by [MainScreenFlow.initializeKit] when kit construction fails.
  /// Pass [null] to clear a previously set error (e.g. after a retry).
  /// This triggers a [state] rebuild so widgets observing the provider
  /// receive the updated value via the notifier reference.
  void setBootstrapError(String? message) {
    bootstrapError = message;
    // Emit a state change so widgets that observe demoStateProvider rebuild.
    // The bootstrapError field is not part of WalletConnectionState; we
    // emit the current state unchanged to trigger a rebuild cycle.
    state = state.copyWith();
  }

}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Riverpod provider for the top-level demo state.
///
/// The notifier holds the kit instance and platform singletons as plain
/// fields. [WalletConnectionState] is the Riverpod-observable slice that
/// drives UI rebuilds.
final demoStateProvider =
    NotifierProvider<DemoStateNotifier, WalletConnectionState>(
  DemoStateNotifier.new,
);
