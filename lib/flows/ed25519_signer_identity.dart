import 'dart:typed_data';

import '../util/signer_key_hash.dart';

// ---------------------------------------------------------------------------
// Ed25519SignerIdentity — picker-to-flow key for Ed25519 secret material
// ---------------------------------------------------------------------------

/// Composite key that uniquely identifies an Ed25519 signer across the
/// picker/flow boundary.
///
/// The picker collects one [Ed25519SignerIdentity] → raw-secret-bytes entry
/// per verified Ed25519 signer and passes the whole map to [onConfirm].
/// The flow receives the map and registers each keypair into the kit-owned
/// [OZExternalSignerManager] immediately before submission.
///
/// Equality is defined by [verifierAddress] and byte-level equality of
/// [publicKey].
final class Ed25519SignerIdentity {
  /// Creates an identity for the given verifier contract address and public key.
  const Ed25519SignerIdentity({
    required this.verifierAddress,
    required this.publicKey,
  });

  /// C-strkey of the Ed25519 verifier contract.
  final String verifierAddress;

  /// 32-byte Ed25519 public key.
  final Uint8List publicKey;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Ed25519SignerIdentity) return false;
    if (verifierAddress != other.verifierAddress) return false;
    final a = publicKey;
    final b = other.publicKey;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => hashSignerKey(verifierAddress, publicKey);
}
