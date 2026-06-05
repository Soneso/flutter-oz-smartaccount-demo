/// Abstract wallet connector interface.
///
/// Provides a platform-agnostic abstraction for connecting an external Stellar
/// wallet and signing Soroban auth entries. Concrete implementations target
/// specific platforms:
///
/// - Mobile (iOS, Android): [ReownWalletHandler] via the Reown Sign client.
/// - Web: [FreighterWalletHandler] via the Freighter browser extension JS API.
///
/// Decision — why this interface is distinct from the SDK's [OZExternalWalletAdapter]:
///
/// The SDK's [OZExternalWalletAdapter] is the *inbound* contract that
/// [OZExternalSignerManager] calls into; it handles multi-signer routing and
/// persistence. [WalletConnector] is the *outbound* transport layer — it owns
/// the live wallet session and translates Reown / Freighter protocol details
/// into plain Dart. The two have different lifetimes and different callers:
/// [ExternalSignerManagerAdapter] bridges them. Merging the two would force
/// Reown / Freighter types into the SDK contract, which must remain
/// platform-agnostic.
///
/// Neither this file nor any type exported from it may reference Reown,
/// Freighter, or any third-party wallet library type. SDK-native and plain
/// Dart types only.
library;

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// Result returned by [WalletConnector.signAuthEntry].
///
/// [signedAuthEntry] is the base64-encoded signed authorization entry XDR
/// returned by the wallet. [signerAddress] is the G-address of the signer
/// that produced the signature, as reported by the wallet; may match the
/// address that was passed in, but callers must not assume it without checking.
final class SignedAuthEntry {
  /// Constructs a signed auth entry result.
  const SignedAuthEntry({
    required this.signedAuthEntry,
    required this.signerAddress,
  });

  /// Base64-encoded signed Soroban authorization entry XDR returned by the wallet.
  final String signedAuthEntry;

  /// G-address of the signer that produced the signature.
  final String signerAddress;
}

/// Human-readable metadata reported by the connected wallet.
final class WalletMetadata {
  /// Constructs wallet metadata.
  const WalletMetadata({
    required this.name,
    this.url,
    this.iconUrl,
  });

  /// Human-readable wallet name (e.g. "Freighter", "LOBSTR").
  final String name;

  /// Wallet homepage or deep-link URI, if available.
  final String? url;

  /// URL of a wallet icon image, if available.
  final String? iconUrl;
}

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

/// Thrown when wallet connection cannot be established.
///
/// Distinct from user cancellation — user cancellation is indicated by
/// [WalletConnector.connect] returning `null`.
final class WalletConnectionException implements Exception {
  /// Constructs a wallet connection exception with the given [message] and
  /// optional [cause].
  const WalletConnectionException(this.message, {this.cause});

  /// Human-readable description of the connection failure.
  final String message;

  /// Underlying exception or error that caused the failure, if any.
  final Object? cause;

  @override
  String toString() =>
      cause != null
          ? 'WalletConnectionException: $message (cause: $cause)'
          : 'WalletConnectionException: $message';
}

/// Thrown when the wallet rejects or fails to sign an auth entry.
///
/// Distinct from user cancellation. If the user explicitly cancelled the
/// signing dialog inside the wallet, the wallet is expected to surface that as
/// a [WalletSigningException] with an appropriate message, because wallet UX
/// varies too widely to model cancellation separately at this abstraction level.
final class WalletSigningException implements Exception {
  /// Constructs a wallet signing exception with the given [message] and
  /// optional [cause].
  const WalletSigningException(this.message, {this.cause});

  /// Human-readable description of the signing failure.
  final String message;

  /// Underlying exception or error that caused the failure, if any.
  final Object? cause;

  @override
  String toString() =>
      cause != null
          ? 'WalletSigningException: $message (cause: $cause)'
          : 'WalletSigningException: $message';
}

/// Thrown when the connected wallet is on a different Stellar network.
///
/// Indicates the wallet reports a network passphrase that does not match the
/// demo's expected testnet passphrase. The user must switch the wallet to
/// testnet before proceeding.
final class WalletNetworkMismatchException implements Exception {
  /// Constructs a network mismatch exception.
  const WalletNetworkMismatchException({
    required this.expected,
    required this.actual,
  });

  /// The network passphrase this demo requires.
  final String expected;

  /// The passphrase reported by the connected wallet.
  final String actual;

  @override
  String toString() =>
      'WalletNetworkMismatchException: wallet is on "$actual" but demo '
      'requires "$expected". Switch your wallet to Testnet and reconnect.';
}

// ---------------------------------------------------------------------------
// Abstract interface
// ---------------------------------------------------------------------------

/// Platform-agnostic interface for connecting an external Stellar wallet and
/// signing Soroban auth entries.
///
/// Implementations must be safe to call from any async context. Methods that
/// trigger UI (connect, signAuthEntry) must be called from the main isolate.
///
/// Lifecycle:
///   1. Construct and optionally call [restoreSession] on app start.
///   2. Call [connect] when the user requests a wallet connection.
///   3. Call [signAuthEntry] for each signing request.
///   4. Call [disconnect] when the user disconnects or the session expires.
abstract class WalletConnector {
  // ---- Connection ----

  /// Initiates a wallet connection and returns the connected wallet address.
  ///
  /// Returns `null` if the user cancelled the connection dialog or if no
  /// wallet is available.
  ///
  /// Throws [WalletConnectionException] on connection failure.
  /// Throws [WalletNetworkMismatchException] if the wallet is on the wrong network.
  Future<String?> connect();

  /// Disconnects the active session and purges any persisted session state.
  ///
  /// Safe to call when no session is active — implementations must be
  /// idempotent.
  Future<void> disconnect();

  /// Restores a previously active session from persistent storage without
  /// prompting the user.
  ///
  /// Implementations that do not support session restoration return `false`
  /// immediately. Returns `true` when a session was restored and
  /// [connectedAddress] is now non-null.
  Future<bool> restoreSession() async => false;

  // ---- Signing ----

  /// Signs a Soroban authorization entry using the connected wallet.
  ///
  /// [authEntryXdr] is the base64-encoded `HashIDPreimage::SorobanAuthorization`
  /// XDR for the auth entry to sign. For Ed25519 wallets (Reown-paired or
  /// Freighter) the expected response is an Ed25519 signature over
  /// `SHA-256(preimage)` where `preimage` is the raw XDR passed in
  /// [authEntryXdr], encoded as a 64-byte raw signature in base64.
  ///
  /// [contextRuleIds] are forwarded to the wallet for display or audit
  /// purposes. They do NOT alter what an Ed25519 wallet signs — the wallet
  /// always signs `SHA-256(preimage)`. The OZ auth-digest recipe
  /// `SHA-256(signature_payload || context_rule_ids.to_xdr())` is used by the
  /// WebAuthn signer path only, inside the SDK, and does NOT flow through this
  /// interface.
  ///
  /// The calling adapter performs the cryptographic recheck after this returns.
  ///
  /// Returns a [SignedAuthEntry] carrying the base64 signature and signer
  /// address.
  ///
  /// Throws [WalletSigningException] if signing fails or is rejected.
  /// Throws [StateError] if no wallet session is active.
  Future<SignedAuthEntry> signAuthEntry({
    required String authEntryXdr,
    required List<int> contextRuleIds,
  });

  // ---- State accessors ----

  /// The G-address of the currently connected wallet, or `null` when
  /// disconnected.
  String? get connectedAddress;

  /// Human-readable metadata for the connected wallet, or `null` when
  /// disconnected or unavailable.
  WalletMetadata? get walletMetadata;
}
