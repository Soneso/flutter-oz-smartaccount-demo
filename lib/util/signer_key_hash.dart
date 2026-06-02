import 'dart:typed_data';

/// Returns a `hashCode` value for a `(verifierAddress, publicKey)` signer key
/// using a 31x polynomial accumulator.
///
/// Shared by [Ed25519SignerIdentity] and [DemoEd25519Adapter]'s internal
/// `_StorageKey` so both types hash identically for logically equal signer
/// tuples. The algorithm matches the standard Dart `Object.hashAll`-style
/// accumulator — not suitable for cryptographic purposes.
int hashSignerKey(String verifierAddress, Uint8List publicKey) {
  var h = verifierAddress.hashCode;
  for (final b in publicKey) {
    // 31-multiplier polynomial accumulator (Java String.hashCode style).
    h = 0x1fffffff & (31 * h + b);
  }
  return h;
}
