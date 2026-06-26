// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// [OZExternalEd25519SignerAdapter] that signs with in-process Ed25519
/// keypairs, keyed by the on-chain `(verifierAddress, publicKey)` signer slot.
///
/// This mirrors the demo app's `lib/wallet/demo_ed25519_adapter.dart`: the
/// signing keypair lives inside the adapter, never in the SDK manager's
/// in-process registry. The kit's multi-signer pipeline calls [canSignFor]
/// first; when it returns `true` the pipeline calls [signAuthDigest] on this
/// adapter (adapter-first precedence) rather than its own keypair registry.
///
/// Supply one instance to [OZSmartAccountConfig.externalEd25519Adapter] at kit
/// construction. Register the agent's keypair via [add] before submitting a
/// multi-signer call, and [clearAll] afterwards so the adapter does not retain
/// the key reference beyond its needed lifetime.
///
/// Concurrency: Dart is single-threaded per isolate, so no locking is needed —
/// all mutations are synchronous and confined to this adapter's own methods.
class AgentEd25519SignerAdapter implements OZExternalEd25519SignerAdapter {
  /// Creates an empty adapter with no registered keypair.
  AgentEd25519SignerAdapter();

  /// Signing keypairs keyed by the `(verifierAddress, publicKey)` slot.
  final Map<_SignerSlot, KeyPair> _keypairs = <_SignerSlot, KeyPair>{};

  /// Registers [keypair] for the on-chain signer slot identified by
  /// [verifierAddress] and the keypair's public key.
  ///
  /// Registering a second keypair for the same slot overwrites the previous
  /// entry. [keypair] must be able to sign (constructed from a secret seed),
  /// otherwise [signAuthDigest] would later fail.
  void add(String verifierAddress, KeyPair keypair) {
    if (!keypair.canSign()) {
      throw ArgumentError.value(
        keypair,
        'keypair',
        'Ed25519 signer keypair is public-only and cannot sign',
      );
    }
    final publicKey = Uint8List.fromList(keypair.publicKey);
    _keypairs[_SignerSlot(verifierAddress, publicKey)] = keypair;
  }

  /// Removes every registered keypair.
  void clearAll() => _keypairs.clear();

  @override
  bool canSignFor(String verifierAddress, Uint8List publicKey) {
    return _keypairs.containsKey(_SignerSlot(verifierAddress, publicKey));
  }

  @override
  Future<Uint8List> signAuthDigest(
    Uint8List authDigest,
    Uint8List publicKey,
  ) async {
    // signAuthDigest receives only the publicKey (not the verifier address),
    // so locate by public key. A single agent registers one slot, so the first
    // match is unambiguous.
    for (final entry in _keypairs.entries) {
      if (_bytesEqual(entry.key.publicKey, publicKey)) {
        return Uint8List.fromList(entry.value.sign(authDigest));
      }
    }
    final prefix = Util.bytesToHex(
      Uint8List.fromList(publicKey.take(8).toList()),
    );
    throw AgentSignerException(
      'No Ed25519 keypair registered for public key $prefix...',
    );
  }
}

/// Thrown by [AgentEd25519SignerAdapter.signAuthDigest] when no keypair is
/// registered for the requested public key.
class AgentSignerException implements Exception {
  /// Constructs a signer exception with a [message].
  const AgentSignerException(this.message);

  /// Short, actionable description of the error.
  final String message;

  @override
  String toString() => 'AgentSignerException: $message';
}

/// Composite key mirroring the on-chain `External(verifierAddress, publicKey)`
/// signer identity.
class _SignerSlot {
  _SignerSlot(this.verifierAddress, this.publicKey);

  final String verifierAddress;
  final Uint8List publicKey;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _SignerSlot) return false;
    if (verifierAddress != other.verifierAddress) return false;
    return _bytesEqual(publicKey, other.publicKey);
  }

  @override
  int get hashCode => Object.hash(verifierAddress, Object.hashAll(publicKey));
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
