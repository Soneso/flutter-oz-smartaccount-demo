/// Reown Sign client implementation of [WalletConnector].
///
/// Mobile only (iOS and Android). This file must not be imported on Web
/// builds; the Reown packages are not designed for browser-side signing
/// workflows.
///
/// The handler uses [ReownSignClient] (dApp side) to:
///   1. Pair with a Stellar wallet via WalletConnect v2 URI.
///   2. Scope the session to [_chainId] + [_signMethod] only.
///   3. Forward signing requests as JSON-RPC method calls.
///
/// Session storage is managed by the Reown SDK (persistent across app
/// launches). On [disconnect] the session is deleted via [disconnectSession],
/// which also removes the underlying pairing — ensuring no stale relay
/// traffic and no stored credentials remain.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:reown_core/reown_core.dart';
import 'package:reown_sign/reown_sign.dart';

import '../config/demo_config.dart' as config;
import 'wallet_connector.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// WalletConnect chain ID for Stellar testnet.
///
/// Scoped to testnet only — this handler hard-fails (see [connect]) if the
/// wallet reports a different network.
const String _chainId = 'stellar:testnet';

/// The single JSON-RPC method this dApp may invoke on the wallet.
///
/// Sessions are scoped to this method and [_chainId] only. A wallet that
/// proposes additional permissions is accepted but only [_signMethod] is
/// ever called. A wallet that does not include [_signMethod] in its approved
/// methods will fail when [signAuthEntry] sends the request.
const String _signMethod = 'stellar_signAuthEntry';

/// WalletConnect error code for user rejection (CAIP-25 / WalletConnect spec).
const int _wcUserRejectedCode = 5000;

/// Timeout for awaiting wallet session approval after pairing URI is presented.
///
/// Set to 2 minutes: long enough for a user to switch to their wallet app,
/// review the proposal, and approve.
const Duration _sessionApprovalTimeout = Duration(minutes: 2);

/// Timeout for a single [signAuthEntry] round-trip to the wallet.
const Duration _signingTimeout = Duration(minutes: 2);

// ---------------------------------------------------------------------------
// ReownWalletHandler
// ---------------------------------------------------------------------------

/// Reown Sign client implementation of [WalletConnector] for iOS and Android.
///
/// Instantiate once per app session and inject via [DemoStateNotifier]. On
/// [connect], a WalletConnect v2 URI is produced and presented to the user
/// (via [onPairingUri]) for QR display or deep-link launch. The handler then
/// waits for the wallet to approve the session.
///
/// Web builds must not instantiate this class — [connect] throws immediately
/// with a clear error when [kIsWeb] is true.
class ReownWalletHandler implements WalletConnector {
  /// Constructs a handler.
  ///
  /// [onPairingUri] is called with the WalletConnect pairing URI once it is
  /// generated. The UI should display a QR code and offer a deep-link button
  /// for this URI. The callback is called from the main isolate.
  ///
  /// [projectId] defaults to [config.reownProjectId] but can be overridden
  /// for testing.
  ReownWalletHandler({
    required this.onPairingUri,
    this.onSigningRequested,
    String? projectId,
  }) : _projectId = projectId ?? config.reownProjectId;

  /// Called when a WalletConnect pairing URI is ready to display.
  ///
  /// The URI follows the WalletConnect URI format:
  /// `wc:<topic>@2?relay-protocol=irn&symKey=<key>`.
  /// Display it as a QR code and offer a deep-link button.
  final void Function(Uri pairingUri) onPairingUri;

  /// Called after a signing request has been dispatched to the wallet so the
  /// caller can bring the wallet app to the foreground. [walletRedirect] is
  /// the session's reported deep-link redirect (preferring `redirect.native`,
  /// then `redirect.universal`); it may be null if the wallet did not include
  /// a redirect in its pairing metadata. The callback is invoked fire-and-
  /// forget; its outcome does not block or fail the signing round-trip.
  final Future<void> Function(Uri? walletRedirect)? onSigningRequested;

  final String _projectId;

  // ---- Reown client ----
  ReownSignClient? _client;

  // ---- Session state ----
  SessionData? _activeSession;
  String? _connectedAddress;
  WalletMetadata? _walletMetadata;

  // ---- Event handler references (kept so they can be unsubscribed) ----
  void Function(SessionDelete)? _onSessionDeleteHandler;
  void Function(SessionExpire)? _onSessionExpireHandler;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Initialises the Reown Sign client.
  ///
  /// Must be called once before [connect] or [restoreSession]. Safe to call
  /// multiple times — subsequent calls are no-ops.
  Future<void> init() async {
    if (_client != null) return;

    _client = await ReownSignClient.createInstance(
      projectId: _projectId,
      metadata: const PairingMetadata(
        name: config.reownAppName,
        description: config.reownAppDescription,
        url: config.reownAppUrl,
        // Custom URL scheme owned by this app. Gives the paired wallet a
        // launchable target for its "return to dApp" button. Matches the
        // intent filter in android/app/src/main/AndroidManifest.xml and
        // the CFBundleURLSchemes entry in ios/Runner/Info.plist.
        redirect: Redirect(
          native: 'stellar-smartaccount-flutter://callback',
        ),
      ),
    );

    _hookSessionEvents(_client!);
  }

  /// Forces the relay WebSocket to reconnect if it has dropped. The
  /// underlying SDK connect is idempotent — a no-op when already
  /// connected. Call this on [AppLifecycleState.resumed] so queued relay
  /// messages surface immediately rather than waiting for the heartbeat
  /// to detect the dead socket on its own cadence.
  Future<void> ensureRelayConnected() async {
    final client = _client;
    if (client == null) return;
    final relay = client.core.relayClient;
    if (relay.isConnected) return;
    try {
      await relay.connect();
    } catch (error) {
      debugPrint('[wallet.reown] relay reconnect failed: $error');
    }
  }

  /// Hooks session-level events so in-app state tracks remote changes.
  ///
  /// [Event<T>.subscribe] from the `event` package returns void and stores
  /// the handler in an internal list. To avoid accumulating duplicate handlers
  /// across [init] calls (which are guarded to no-op after the first), we keep
  /// the handler references so we can unsubscribe via [Event<T>.unsubscribe]
  /// if the client is ever torn down.
  void _hookSessionEvents(ReownSignClient client) {
    // Wallet-initiated session deletion (e.g. user disconnects from wallet UI).
    if (_onSessionDeleteHandler != null) {
      client.onSessionDelete.unsubscribe(_onSessionDeleteHandler!);
    }
    _onSessionDeleteHandler = (event) {
      if (event.topic == _activeSession?.topic) {
        _clearSession();
      }
    };
    client.onSessionDelete.subscribe(_onSessionDeleteHandler!);

    // Session TTL expiry.
    if (_onSessionExpireHandler != null) {
      client.onSessionExpire.unsubscribe(_onSessionExpireHandler!);
    }
    _onSessionExpireHandler = (event) {
      if (event.topic == _activeSession?.topic) {
        _clearSession();
      }
    };
    client.onSessionExpire.subscribe(_onSessionExpireHandler!);
  }

  // ---------------------------------------------------------------------------
  // WalletConnector — connection
  // ---------------------------------------------------------------------------

  @override
  Future<String?> connect() async {
    // Reown Sign is not usable in browser builds; fail fast with a clear error.
    if (kIsWeb) {
      throw const WalletConnectionException(
        'ReownWalletHandler is not supported on Web. '
        'Use FreighterWalletHandler for browser-based wallet connections.',
      );
    }

    await init();
    final client = _client!;

    // If a session is already active for the expected chain and method,
    // return the existing address without re-pairing.
    final existing = _findExistingSession(client);
    if (existing != null) {
      _activateSession(existing);
      return _connectedAddress;
    }

    // Start a new pairing. The session is scoped to [_chainId] and
    // [_signMethod] only — no events, no other methods.
    final ConnectResponse response = await client.connect(
      optionalNamespaces: <String, RequiredNamespace>{
        'stellar': const RequiredNamespace(
          chains: <String>[_chainId],
          methods: <String>[_signMethod],
          events: <String>[],
        ),
      },
    );

    // Surface the pairing URI for the UI to display.
    final pairingUri = response.uri;
    if (pairingUri != null) {
      _validateAndDispatchPairingUri(pairingUri);
    }

    // Await the wallet's session approval.
    final SessionData session = await response.session.future
        .timeout(_sessionApprovalTimeout, onTimeout: () {
      throw WalletConnectionException(
        'Wallet did not respond within '
        '${_sessionApprovalTimeout.inMinutes} minutes. '
        'Check the wallet app and try again.',
      );
    });

    // Extract the G-address from the approved namespace accounts.
    final address = _extractAddress(session);
    if (address == null) {
      await _disconnectSession(client, session.topic);
      throw const WalletConnectionException(
        'Wallet approved the session but reported no Stellar account address. '
        'Ensure the wallet is configured with a funded testnet account.',
      );
    }

    // Verify the wallet is on testnet.
    final networkPassphrase = _extractNetworkPassphrase(session);
    if (networkPassphrase != null &&
        networkPassphrase != config.networkPassphrase) {
      await _disconnectSession(client, session.topic);
      throw WalletNetworkMismatchException(
        expected: config.networkPassphrase,
        actual: networkPassphrase,
      );
    }

    _activateSession(session, address: address);
    return _connectedAddress;
  }

  @override
  Future<void> disconnect() async {
    final client = _client;
    final topic = _activeSession?.topic;
    _clearSession();
    if (client == null) return;
    // Purge every active session and pairing to avoid orphan relay traffic.
    // Just clearing the active topic is not enough: stale sessions and
    // pairings from prior runs would otherwise persist in the SignClient
    // store and reappear on the next `restoreSession()`.
    await _purgeAllSessionsAndPairings(client, activeTopic: topic);
  }

  @override
  Future<bool> restoreSession() async {
    if (kIsWeb) return false;
    await init();
    final client = _client!;
    // Purge orphan sessions that are no longer valid for stellar:testnet
    // before restoring the first valid one.
    await _purgeOrphanSessions(client);
    final existing = _findExistingSession(client);
    if (existing == null) return false;
    _activateSession(existing);
    return _connectedAddress != null;
  }

  // ---------------------------------------------------------------------------
  // WalletConnector — signing
  // ---------------------------------------------------------------------------

  @override
  Future<SignedAuthEntry> signAuthEntry({
    required String authEntryXdr,
    required List<int> contextRuleIds,
  }) async {
    final client = _client;
    final session = _activeSession;
    final address = _connectedAddress;

    if (client == null || session == null || address == null) {
      throw StateError(
        'signAuthEntry called with no active Reown session. '
        'Call connect() first.',
      );
    }

    // Reject an empty auth-entry XDR before forwarding to the wallet.
    if (authEntryXdr.isEmpty) {
      throw const WalletSigningException('authEntryXdr must not be empty.');
    }

    // JSON-RPC request to the wallet. The Stellar WalletConnect method
    // accepts { entryXdr, address } and returns { signedAuthEntry }.
    //
    // Pre-generate a request id so the timeout watchdog can reference the
    // exact in-flight request when telling the wallet to dismiss its stale
    // prompt. JSON-RPC ids are `int`; `microsecondsSinceEpoch` fits and is
    // unique for the single in-flight signing request the handler permits.
    final int requestId = DateTime.now().microsecondsSinceEpoch;
    final String topic = session.topic;
    final dynamic result;
    try {
      final responseFuture = client.request(
        requestId: requestId,
        topic: topic,
        chainId: _chainId,
        request: SessionRequestParams(
          method: _signMethod,
          params: <String, dynamic>{
            'entryXdr': authEntryXdr,
            'address': address,
          },
        ),
      );

      // The relay delivers the request silently; the wallet stays in the
      // background unless the OS is told to foreground it. Fire the wake
      // callback (if supplied) as soon as the request is in flight so the
      // user sees the pending signing prompt rather than the spinner here.
      final wake = onSigningRequested;
      if (wake != null) {
        final redirect = session.peer.metadata.redirect;
        final raw = redirect?.native ?? redirect?.universal;
        final walletRedirect = (raw != null && raw.isNotEmpty)
            ? Uri.tryParse(raw)
            : null;
        unawaited(wake(walletRedirect));
      }

      result = await responseFuture.timeout(_signingTimeout, onTimeout: () {
        // Tell the wallet to dismiss the stale prompt at the relay layer.
        // Without this, Freighter keeps the signing sheet up after the dApp-
        // side timeout fires and the user has to dismiss it manually. Fire-
        // and-forget so the timeout error surfaces to the caller without
        // waiting on a relay round-trip; the wallet may already have
        // responded or disconnected, in which case `respond` is a best-
        // effort no-op.
        unawaited(
          client
              .respond(
                topic: topic,
                response: JsonRpcResponse<dynamic>(
                  id: requestId,
                  error: JsonRpcError.serverError('Request timed out'),
                ),
              )
              .catchError((Object error, StackTrace stackTrace) {
            debugPrint('[wallet.reown] sign-request timeout abort failed: $error');
          }),
        );
        throw WalletSigningException(
          'Wallet did not respond to signing request within '
          '${_signingTimeout.inMinutes} minutes.',
        );
      });
    } on JsonRpcError catch (e) {
      if (e.code == _wcUserRejectedCode) {
        throw const WalletSigningException(
          'Wallet rejected the signing request. '
          'Open the wallet app and approve the request.',
        );
      }
      throw WalletSigningException(
        'Wallet returned an error: ${e.message ?? "unknown error"} '
        '(code: ${e.code})',
        cause: e,
      );
    } catch (e) {
      if (e is WalletSigningException) rethrow;
      throw WalletSigningException(
        'Signing request failed: $e',
        cause: e,
      );
    }

    // Parse the response. Wallets return { signedAuthEntry: <base64> }.
    final String? signed = _extractSignedAuthEntry(result);
    if (signed == null || signed.isEmpty) {
      throw const WalletSigningException(
        'Wallet returned an empty or missing signedAuthEntry. '
        'The wallet may not support the stellar_signAuthEntry method.',
      );
    }

    return SignedAuthEntry(
      signedAuthEntry: signed,
      signerAddress: address,
    );
  }

  // ---------------------------------------------------------------------------
  // WalletConnector — state
  // ---------------------------------------------------------------------------

  @override
  String? get connectedAddress => _connectedAddress;

  @override
  WalletMetadata? get walletMetadata => _walletMetadata;

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Disconnects every active session and pairing.
  ///
  /// Called on [disconnect] to ensure no orphan relay sessions accumulate in
  /// shared persistent storage. [activeTopic], if provided, is disconnected
  /// last so any remote acknowledgement for it arrives in order.
  Future<void> _purgeAllSessionsAndPairings(
    ReownSignClient client, {
    String? activeTopic,
  }) async {
    final sessions = Map<String, SessionData>.from(client.getActiveSessions());
    for (final topic in sessions.keys) {
      if (topic == activeTopic) continue;
      await _disconnectSession(client, topic);
    }
    if (activeTopic != null) {
      await _disconnectSession(client, activeTopic);
    }
    // Disconnect any pairings not backed by a remaining active session.
    final pairings = List<PairingInfo>.from(client.pairings.getAll());
    final remainingSessions = client.getActiveSessions();
    for (final pairing in pairings) {
      final hasBacking = remainingSessions.values.any(
        (s) => s.pairingTopic == pairing.topic,
      );
      if (!hasBacking) {
        try {
          await client.core.pairing.disconnect(topic: pairing.topic);
        } catch (_) {
          // Pairing may already be gone — ignore.
        }
      }
    }
  }

  /// Disconnects sessions that fail [_isValidStellarTestnetSession] so they
  /// do not accumulate in persistent storage across app launches.
  ///
  /// Called during [restoreSession] before the first valid session is chosen.
  Future<void> _purgeOrphanSessions(ReownSignClient client) async {
    final sessions = Map<String, SessionData>.from(client.getActiveSessions());
    for (final entry in sessions.entries) {
      if (!_isValidStellarTestnetSession(entry.value)) {
        await _disconnectSession(client, entry.key);
      }
    }
  }

  /// Returns true when [session] is scoped to [_chainId] and [_signMethod].
  bool _isValidStellarTestnetSession(SessionData session) {
    final namespace = session.namespaces['stellar'];
    if (namespace == null) return false;
    final chains = namespace.chains ?? <String>[];
    if (!chains.contains(_chainId)) return false;
    return namespace.methods.contains(_signMethod);
  }

  /// Finds an existing active session scoped to [_chainId] and [_signMethod].
  SessionData? _findExistingSession(ReownSignClient client) {
    final sessions = client.getActiveSessions();
    for (final session in sessions.values) {
      if (_isValidStellarTestnetSession(session)) return session;
    }
    return null;
  }

  /// Activates a session, setting [_connectedAddress] and [_walletMetadata].
  void _activateSession(SessionData session, {String? address}) {
    _activeSession = session;
    _connectedAddress = address ?? _extractAddress(session);
    final peer = session.peer.metadata;
    _walletMetadata = WalletMetadata(
      name: peer.name,
      url: peer.url.isNotEmpty ? peer.url : null,
      iconUrl: peer.icons.isNotEmpty ? peer.icons.first : null,
    );
  }

  /// Clears all in-memory session state.
  void _clearSession() {
    _activeSession = null;
    _connectedAddress = null;
    _walletMetadata = null;
  }

  /// Sends a disconnect request to the relay and deletes the pairing.
  Future<void> _disconnectSession(ReownSignClient client, String topic) async {
    try {
      await client.disconnect(
        topic: topic,
        reason: const ReownSignError(
          code: _wcUserRejectedCode,
          message: 'User disconnected',
        ),
      );
    } catch (_) {
      // Ignore errors during cleanup — the local state is already cleared.
    }
  }

  /// Validates a pairing URI before dispatching to [onPairingUri].
  ///
  /// Rejects URIs that do not start with `wc:`, are empty, or exceed a
  /// reasonable length bound (4 096 characters). Malformed URIs are rejected
  /// with a [WalletConnectionException] rather than forwarded to the UI or
  /// deep-linked into another app.
  void _validateAndDispatchPairingUri(Uri pairingUri) {
    final raw = pairingUri.toString();
    if (!raw.startsWith('wc:') || raw.length > 4096 || raw.length < 10) {
      throw const WalletConnectionException(
        'Received an invalid WalletConnect pairing URI. '
        'This may indicate a relay misconfiguration.',
      );
    }
    onPairingUri(pairingUri);
  }

  /// Extracts the first Stellar G-address from the session namespace accounts.
  ///
  /// Account entries follow the CAIP-10 format: `stellar:testnet:<G-address>`.
  String? _extractAddress(SessionData session) {
    final namespace = session.namespaces['stellar'];
    if (namespace == null) return null;
    for (final account in namespace.accounts) {
      final parts = account.split(':');
      // CAIP-10: chain:network:address — need at least 3 parts.
      if (parts.length >= 3) {
        final address = parts.skip(2).join(':');
        if (address.startsWith('G') && address.length == 56) {
          return address;
        }
      }
    }
    return null;
  }

  /// Extracts the network passphrase from session properties if present.
  ///
  /// Some wallets include a `networkPassphrase` key in `sessionProperties`.
  /// Returns `null` when the property is absent.
  String? _extractNetworkPassphrase(SessionData session) {
    return session.sessionProperties?['networkPassphrase'];
  }

  /// Extracts the `signedAuthEntry` field from a wallet JSON-RPC response.
  ///
  /// Wallets return either a plain String or a Map with the key
  /// `signedAuthEntry`. Both shapes are handled.
  String? _extractSignedAuthEntry(dynamic result) {
    if (result is String && result.isNotEmpty) return result;
    if (result is Map) {
      final entry = result['signedAuthEntry'];
      if (entry is String && entry.isNotEmpty) return entry;
    }
    return null;
  }
}
