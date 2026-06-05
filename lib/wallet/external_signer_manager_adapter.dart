/// Adapter bridging [WalletConnector] to the SDK's [OZExternalWalletAdapter].
///
/// [ExternalSignerManagerAdapter] implements the SDK's [OZExternalWalletAdapter]
/// so that the kit's external signer manager can route wallet-connected signing
/// requests to the active [WalletConnector] session (Reown on mobile, Freighter
/// on web) when the requested address matches [WalletConnector.connectedAddress].
///
/// In-memory G-address keypair signing is handled natively by the kit's
/// [OZExternalSignerManager] via its [addFromSecret] method — the demo adapter
/// only handles the wallet-connector path.
///
/// Signature verification:
///
/// The adapter performs both a structural recheck (signature is exactly 64
/// bytes and non-zero) and a full cryptographic recheck (Ed25519 verify of
/// the returned signature against `SHA-256(preimage)` using the registered
/// G-address's public key via `KeyPair.fromAccountId(address).verify(...)`).
/// A wallet that signs the wrong payload (or returns a signature that does not
/// match the registered address's public key) is rejected here before the
/// signature reaches the SDK or the network.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'wallet_connector.dart';

// ---------------------------------------------------------------------------
// Typed exception for recheck failures
// ---------------------------------------------------------------------------

/// Thrown when the adapter's signature recheck fails.
///
/// This is thrown when the wallet-connector signature either (a) fails the
/// structural recheck (wrong length / all-zero bytes) or (b) fails the
/// cryptographic recheck (signature does not verify against
/// `SHA-256(preimage)` with the registered G-address's public key). A
/// failure means the wallet returned a malformed or wrong-payload response
/// rather than a valid Ed25519 signature over what the adapter sent.
///
/// This exception is wrapped as [SmartAccountTransactionException.signingFailed] before
/// propagating to the SDK caller.
final class AdapterSignatureRecheckException implements Exception {
  /// Constructs a recheck exception.
  const AdapterSignatureRecheckException(this.message, {this.cause});

  /// Human-readable description of the mismatch.
  final String message;

  /// Optional underlying exception.
  final Object? cause;

  @override
  String toString() =>
      cause != null
          ? 'AdapterSignatureRecheckException: $message (cause: $cause)'
          : 'AdapterSignatureRecheckException: $message';
}

// ---------------------------------------------------------------------------
// ExternalSignerManagerAdapter
// ---------------------------------------------------------------------------

/// [OZExternalWalletAdapter] implementation that bridges [WalletConnector] to
/// the kit's external signer manager for the wallet-connector signing path.
///
/// Construct one instance per app session and supply it via
/// [OZSmartAccountConfig.externalWallet] at kit construction.
///
/// In-memory G-address keypairs are not managed here — they are registered
/// at runtime via [OZExternalSignerManager.addFromSecret].
///
/// Thread safety: Dart's single-isolate model ensures method calls are
/// serialised as long as callers do not use [Isolate.run]. This adapter does
/// not use any additional synchronisation primitives.
class ExternalSignerManagerAdapter extends OZExternalWalletAdapter {
  /// Constructs an adapter with no active wallet connector.
  ExternalSignerManagerAdapter();

  // ---- Active wallet connector ----

  /// The platform wallet connector for the current session.
  ///
  /// When set, signing requests whose target address equals
  /// [WalletConnector.connectedAddress] are routed to this connector.
  WalletConnector? walletConnector;

  // ---------------------------------------------------------------------------
  // OZExternalWalletAdapter — connection
  // ---------------------------------------------------------------------------

  /// Not used — this adapter does not initiate wallet connections directly.
  /// Connections are managed by [walletConnector]; see [DemoStateNotifier].
  ///
  /// Returns `null` to signal that no connection was established via this path.
  @override
  Future<OZConnectedWallet?> connect() async => null;

  /// Disconnects the active wallet connector session.
  ///
  /// Called by the kit's [OZExternalSignerManager.removeAll]. Clears the
  /// connector's own session (its [WalletConnector.connectedAddress] drops to
  /// null) but keeps the [walletConnector] reference. The connector is a
  /// long-lived app singleton shared with the picker UI: keeping the reference
  /// lets the adapter observe a later reconnection made through that same
  /// singleton, so [canSignFor] reflects the live connector session.
  @override
  Future<void> disconnect() async {
    await walletConnector?.disconnect();
  }

  /// Disconnects the active connector session if its address matches [address].
  ///
  /// Clears the connector session but keeps the [walletConnector] reference,
  /// for the same reason as [disconnect]. Does not affect in-memory G-address
  /// keypairs registered on the kit-owned manager — those are managed via
  /// [OZExternalSignerManager.remove].
  @override
  Future<void> disconnectByAddress(String address) async {
    final connector = walletConnector;
    if (connector != null && connector.connectedAddress == address) {
      await connector.disconnect();
    }
  }

  // ---------------------------------------------------------------------------
  // OZExternalWalletAdapter — signing
  // ---------------------------------------------------------------------------

  /// Signs the given [preimageXdr] for [address] via the active wallet connector.
  ///
  /// [preimageXdr] is a base64-encoded `HashIDPreimage` XDR supplied by the
  /// SDK. [options.address] identifies which signer must sign.
  ///
  /// Routes to the active [walletConnector] when its connected address matches
  /// [options.address]. Throws [SmartAccountSignerException.notFound] when no connector
  /// session is active for the requested address.
  @override
  Future<OZSignAuthEntryResult> signAuthEntry(
    String preimageXdr, {
    OZSignAuthEntryOptions? options,
  }) async {
    final address = options?.address;
    if (address == null || address.isEmpty) {
      throw SmartAccountTransactionException.signingFailed(
        'signAuthEntry requires options.address to identify the signer',
      );
    }

    // Decode the preimage bytes — needed for the SHA-256 payload computation.
    final Uint8List preimageBytes;
    try {
      preimageBytes = base64Decode(preimageXdr);
    } catch (e) {
      throw SmartAccountTransactionException.signingFailed(
        'Failed to base64-decode auth entry preimage for $address',
        cause: e,
      );
    }

    // Compute SHA-256(preimage) — the Ed25519 payload the wallet must sign.
    final expectedPayload = Uint8List.fromList(
      crypto.sha256.convert(preimageBytes).bytes,
    );

    // Route to wallet connector when it is connected for this address.
    final connector = walletConnector;
    if (connector != null && connector.connectedAddress == address) {
      return _signWithConnector(
        connector: connector,
        preimageXdr: preimageXdr,
        expectedPayload: expectedPayload,
        address: address,
      );
    }

    throw SmartAccountSignerException.notFound(
      '$address — no wallet connector is active for this address.',
    );
  }

  // ---------------------------------------------------------------------------
  // OZExternalWalletAdapter — query
  // ---------------------------------------------------------------------------

  @override
  List<OZConnectedWallet> getConnectedWallets() {
    final connector = walletConnector;
    if (connector == null) return const <OZConnectedWallet>[];
    final address = connector.connectedAddress;
    if (address == null) return const <OZConnectedWallet>[];
    final meta = connector.walletMetadata;
    return <OZConnectedWallet>[
      OZConnectedWallet(
        address: address,
        walletId: meta?.name ?? 'external-wallet',
        walletName: meta?.name ?? 'External Wallet',
      ),
    ];
  }

  @override
  bool canSignFor(String address) {
    final connector = walletConnector;
    return connector != null && connector.connectedAddress == address;
  }

  @override
  OZConnectedWallet? getWalletForAddress(String address) {
    final connector = walletConnector;
    if (connector == null || connector.connectedAddress != address) return null;
    final meta = connector.walletMetadata;
    return OZConnectedWallet(
      address: address,
      walletId: meta?.name ?? 'external-wallet',
      walletName: meta?.name ?? 'External Wallet',
    );
  }

  // ---------------------------------------------------------------------------
  // Private signing helpers
  // ---------------------------------------------------------------------------

  /// Routes signing to [connector] and performs a full cryptographic recheck
  /// on the returned signature.
  ///
  /// After the wallet returns a signature, the adapter:
  ///   1. Structurally validates the signature (base64 decode, 64 bytes,
  ///      non-zero) — fast-rejects obviously malformed wallet responses.
  ///   2. Cryptographically verifies the signature with the registered
  ///      G-address's public key over the expected `SHA-256(preimage)`
  ///      payload via `KeyPair.fromAccountId(address).verify(...)`.
  ///
  /// This is the "what you sign is what you see" guarantee at the demo layer.
  /// A wrong-payload or wrong-key wallet response is caught here before
  /// reaching the SDK or the network.
  Future<OZSignAuthEntryResult> _signWithConnector({
    required WalletConnector connector,
    required String preimageXdr,
    required Uint8List expectedPayload,
    required String address,
  }) async {
    final SignedAuthEntry result;
    try {
      result = await connector.signAuthEntry(
        authEntryXdr: preimageXdr,
        contextRuleIds: const <int>[],
      );
    } on WalletSigningException catch (e) {
      throw SmartAccountTransactionException.signingFailed(
        'Wallet connector signing failed for $address: ${e.message}',
        cause: e,
      );
    } catch (e) {
      throw SmartAccountTransactionException.signingFailed(
        'Wallet connector signing failed for $address: $e',
        cause: e,
      );
    }

    // Structural recheck (length + non-zero) — cheap fast-fail.
    _structuralRecheckEd25519(result.signedAuthEntry, address);

    // Cryptographic recheck: verify the signature is over the exact payload
    // the adapter sent, using the registered G-address's public key. This is
    // the demo-layer defense against a wallet returning a signature over a
    // different payload (e.g. an attacker-substituted auth entry).
    final signatureBytes = base64Decode(result.signedAuthEntry);
    final KeyPair verifier;
    try {
      verifier = KeyPair.fromAccountId(address);
    } catch (e) {
      throw AdapterSignatureRecheckException(
        'Cannot derive verifier keypair from address $address: $e',
        cause: e,
      );
    }
    final bool isValid;
    try {
      isValid = verifier.verify(expectedPayload, signatureBytes);
    } catch (e) {
      throw AdapterSignatureRecheckException(
        'Ed25519 verification raised an error for $address: $e',
        cause: e,
      );
    }
    if (!isValid) {
      throw AdapterSignatureRecheckException(
        'Wallet returned an Ed25519 signature for $address that does not '
        'verify against the expected SHA-256(preimage). The wallet may have '
        'signed a different payload than the one sent.',
      );
    }

    return OZSignAuthEntryResult(
      signedAuthEntry: result.signedAuthEntry,
      signerAddress: result.signerAddress,
    );
  }

  // ---------------------------------------------------------------------------
  // Structural recheck helpers
  // ---------------------------------------------------------------------------

  /// Structurally rechecks an Ed25519 signature from an external wallet.
  ///
  /// Verifies that [signedAuthEntryBase64] base64-decodes to exactly 64 bytes
  /// and is not all-zero. Throws [AdapterSignatureRecheckException] on failure,
  /// which propagates as [SmartAccountTransactionException.signingFailed] to the SDK caller.
  ///
  /// A full cryptographic verification against the wallet's public key is NOT
  /// performed here — it is enforced on-chain by the Soroban host.
  void _structuralRecheckEd25519(
    String signedAuthEntryBase64,
    String address,
  ) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(signedAuthEntryBase64);
    } catch (e) {
      throw AdapterSignatureRecheckException(
        'Wallet returned an invalid base64 signature for $address.',
        cause: e,
      );
    }

    if (bytes.isEmpty) {
      throw AdapterSignatureRecheckException(
        'Wallet returned an empty signature for $address.',
      );
    }

    // Ed25519 signatures are always exactly 64 bytes.
    if (bytes.length != 64) {
      throw AdapterSignatureRecheckException(
        'Wallet returned a signature of unexpected length '
        '(${bytes.length} bytes) for $address. '
        'Expected 64 bytes (Ed25519).',
      );
    }

    // An all-zero signature is not valid for any honest Ed25519 signer.
    var allZero = true;
    for (final b in bytes) {
      if (b != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) {
      throw AdapterSignatureRecheckException(
        'Wallet returned an all-zero signature for $address, '
        'which is never a valid Ed25519 signature.',
      );
    }
  }
}
