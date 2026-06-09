import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/ed25519_signer_identity.dart';
import '../util/signer_key_hash.dart';

// ---------------------------------------------------------------------------
// DemoEd25519Adapter
// ---------------------------------------------------------------------------

/// Demonstrates the [OZExternalEd25519SignerAdapter] callback path for Ed25519
/// signing.
///
/// Stores verified 32-byte Ed25519 seeds in an in-memory registry keyed by
/// ([Ed25519SignerIdentity.verifierAddress], [Ed25519SignerIdentity.publicKey])
/// tuple. The signing secret lives inside this adapter, never in the SDK
/// manager's in-process registry. The SDK's multi-signer pipeline calls
/// [canSignFor] first; when it returns true the pipeline calls [signAuthDigest]
/// on this adapter instead of the manager's in-process keypair registry.
///
/// Usage pattern:
/// 1. After the user verifies secrets in the signer picker, call [add] for
///    each secret seed before submission.
/// 2. Submit the multi-signer operation; the manager invokes [signAuthDigest]
///    for covered keys.
/// 3. After submission (success or failure) call [clearAll] so raw seed
///    material is not retained beyond its needed lifetime.
///
/// Concurrency: Dart is single-threaded per isolate, so no locking is needed.
/// All mutations are synchronous and confined to this adapter's own methods.
class DemoEd25519Adapter implements OZExternalEd25519SignerAdapter {
  /// Creates an empty adapter with no registered secrets.
  DemoEd25519Adapter();

  /// Full keypair registry, keyed by (verifierAddress, publicKey) tuple.
  final Map<_StorageKey, KeyPair> _keypairs = <_StorageKey, KeyPair>{};

  // ---- Registration ----

  /// Registers an Ed25519 signing secret for the given signer [identity].
  ///
  /// [seedBytes] must be exactly 32 raw Ed25519 seed bytes. The secret bytes
  /// never leave this adapter; [OZExternalSignerManager]'s in-process registry
  /// does not see them. Registering a second secret for the same
  /// ([verifierAddress], [publicKey]) tuple overwrites the previous entry.
  ///
  /// Throws [ArgumentError] when [seedBytes] is not exactly 32 bytes; any
  /// [KeyPair] construction error for invalid key material is propagated.
  void add(Ed25519SignerIdentity identity, Uint8List seedBytes) {
    if (seedBytes.length != SmartAccountConstants.ed25519SecretSeedSize) {
      throw ArgumentError.value(
        seedBytes.length,
        'seedBytes',
        'Ed25519 secret key must be exactly '
            '${SmartAccountConstants.ed25519SecretSeedSize} bytes',
      );
    }
    final keypair = KeyPair.fromSecretSeedList(seedBytes);
    _keypairs[_StorageKey(identity.verifierAddress, identity.publicKey)] =
        keypair;
  }

  /// Removes all registered secrets.
  ///
  /// Must be called after submission (success or failure) so raw seed material
  /// is not retained across operations.
  void clearAll() => _keypairs.clear();

  // ---- OZExternalEd25519SignerAdapter ----

  @override
  bool canSignFor(String verifierAddress, Uint8List publicKey) {
    return _keypairs.containsKey(_StorageKey(verifierAddress, publicKey));
  }

  @override
  Future<Uint8List> signAuthDigest(
    Uint8List authDigest,
    Uint8List publicKey,
  ) async {
    // signAuthDigest does not receive verifierAddress per the protocol, so
    // locate by publicKey only. The demo registers at most one (verifier,
    // publicKey) pair per signer, so the first match is unambiguous.
    for (final entry in _keypairs.entries) {
      if (listEquals(entry.key.publicKey, publicKey)) {
        final signature = entry.value.sign(authDigest);
        return Uint8List.fromList(signature);
      }
    }
    throw DemoAdapterError.keypairNotFound(publicKey);
  }
}

// ---------------------------------------------------------------------------
// _StorageKey
// ---------------------------------------------------------------------------

/// Composite key for the adapter's keypair registry.
///
/// Two entries with the same public key but different verifier addresses are
/// distinct on-chain signers and are stored separately.
class _StorageKey {
  _StorageKey(this.verifierAddress, this.publicKey);

  final String verifierAddress;
  final Uint8List publicKey;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _StorageKey) return false;
    if (verifierAddress != other.verifierAddress) return false;
    return listEquals(publicKey, other.publicKey);
  }

  @override
  int get hashCode => hashSignerKey(verifierAddress, publicKey);
}

// ---------------------------------------------------------------------------
// DemoAdapterError
// ---------------------------------------------------------------------------

/// Errors thrown by [DemoEd25519Adapter.signAuthDigest].
final class DemoAdapterError implements Exception {
  const DemoAdapterError._(this.message);

  /// No keypair is registered for the requested public key.
  factory DemoAdapterError.keypairNotFound(Uint8List publicKey) {
    // Truncate to 8 bytes for log brevity; full keys are non-secret but
    // unwieldy in error messages.
    final prefix = Util.bytesToHex(Uint8List.fromList(publicKey.take(8).toList()));
    return DemoAdapterError._(
      'No keypair registered for public key $prefix...',
    );
  }

  /// Short, actionable description of the error.
  final String message;

  @override
  String toString() => 'DemoAdapterError: $message';
}

