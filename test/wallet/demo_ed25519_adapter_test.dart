/// Unit tests for [DemoEd25519Adapter].
///
/// The adapter is the Ed25519 adapter-custody path: secrets are held inside the
/// adapter, and the SDK's multi-signer pipeline consults [canSignFor] before
/// falling back to its own in-process registry. These tests assert the runtime
/// distinguishability that path depends on:
///
/// - a key added via [DemoEd25519Adapter.add] makes [canSignFor] return true;
/// - an identity/key never added makes [canSignFor] return false (so unrelated
///   keys fall through to the in-process registry);
/// - [DemoEd25519Adapter.clearAll] empties the registry so [canSignFor] returns
///   false again;
/// - [DemoEd25519Adapter.signAuthDigest] produces a cryptographically valid
///   Ed25519 signature for an added key.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/ed25519_signer_identity.dart';
import 'package:smart_account_demo/wallet/demo_ed25519_adapter.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// A valid testnet C-address fixture (base32 alphabet only: A-Z, 2-7).
const String _verifierAddress =
    'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';

/// A second distinct C-address fixture used for the never-added negative case.
const String _otherVerifierAddress =
    'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';

/// Builds an [Ed25519SignerIdentity] from a freshly derived keypair, returning
/// both the identity and the keypair so tests can verify signatures.
({Ed25519SignerIdentity identity, KeyPair keypair, Uint8List seed})
    _makeIdentity({String verifierAddress = _verifierAddress}) {
  final keypair = KeyPair.random();
  // The adapter expects the raw 32-byte Ed25519 seed (not the expanded
  // 64-byte private key). Decode it back from the StrKey-encoded secret seed.
  final seed = StrKey.decodeStellarSecretSeed(keypair.secretSeed);
  final publicKey = Uint8List.fromList(keypair.publicKey);
  final identity = Ed25519SignerIdentity(
    verifierAddress: verifierAddress,
    publicKey: publicKey,
  );
  return (identity: identity, keypair: keypair, seed: seed);
}

void main() {
  group('DemoEd25519Adapter.add / canSignFor', () {
    test('an added key makes canSignFor return true for that identity', () {
      final adapter = DemoEd25519Adapter();
      final fixture = _makeIdentity();

      adapter.add(fixture.identity, fixture.seed);

      expect(
        adapter.canSignFor(
          fixture.identity.verifierAddress,
          fixture.identity.publicKey,
        ),
        isTrue,
      );
    });

    test('a key that was never added makes canSignFor return false', () {
      final adapter = DemoEd25519Adapter();
      final never = _makeIdentity();

      expect(
        adapter.canSignFor(never.identity.verifierAddress, never.identity.publicKey),
        isFalse,
        reason: 'keys never added must fall through to the in-process registry',
      );
    });

    test('canSignFor is false for the same public key under a different '
        'verifier address', () {
      final adapter = DemoEd25519Adapter();
      final fixture = _makeIdentity();

      adapter.add(fixture.identity, fixture.seed);

      // Same public key, different verifier address — a distinct on-chain signer.
      expect(
        adapter.canSignFor(_otherVerifierAddress, fixture.identity.publicKey),
        isFalse,
        reason: '(verifierAddress, publicKey) is the composite identity',
      );
    });

    test('add throws ArgumentError when the seed is not exactly 32 bytes', () {
      final adapter = DemoEd25519Adapter();
      final fixture = _makeIdentity();

      expect(
        () => adapter.add(fixture.identity, Uint8List(4)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('DemoEd25519Adapter.clearAll', () {
    test('clearAll empties the registry so canSignFor returns false again', () {
      final adapter = DemoEd25519Adapter();
      final fixture = _makeIdentity();

      adapter.add(fixture.identity, fixture.seed);
      expect(
        adapter.canSignFor(
          fixture.identity.verifierAddress,
          fixture.identity.publicKey,
        ),
        isTrue,
      );

      adapter.clearAll();

      expect(
        adapter.canSignFor(
          fixture.identity.verifierAddress,
          fixture.identity.publicKey,
        ),
        isFalse,
        reason: 'clearAll must remove all registered secrets',
      );
    });
  });

  group('DemoEd25519Adapter.signAuthDigest', () {
    test('produces a signature that verifies under the added public key', () async {
      final adapter = DemoEd25519Adapter();
      final fixture = _makeIdentity();
      adapter.add(fixture.identity, fixture.seed);

      // An arbitrary 32-byte auth digest (the shape the pipeline passes in).
      final authDigest = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 7 + 3) & 0xff),
      );

      final signature = await adapter.signAuthDigest(
        authDigest,
        fixture.identity.publicKey,
      );

      expect(signature, hasLength(64));
      expect(
        fixture.keypair.verify(authDigest, signature),
        isTrue,
        reason: 'signAuthDigest must produce a valid Ed25519 signature',
      );
    });

    test('signs with the correct key when multiple identities are registered',
        () async {
      final adapter = DemoEd25519Adapter();
      final a = _makeIdentity();
      final b = _makeIdentity(verifierAddress: _otherVerifierAddress);
      adapter.add(a.identity, a.seed);
      adapter.add(b.identity, b.seed);

      final authDigest = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 5 + 1) & 0xff),
      );

      final signature = await adapter.signAuthDigest(
        authDigest,
        b.identity.publicKey,
      );

      expect(b.keypair.verify(authDigest, signature), isTrue);
      // The signature must not verify under the other key.
      expect(a.keypair.verify(authDigest, signature), isFalse);
    });

    test('throws DemoAdapterError when no keypair is registered for the key',
        () async {
      final adapter = DemoEd25519Adapter();
      final never = _makeIdentity();

      final authDigest = Uint8List(32);

      await expectLater(
        adapter.signAuthDigest(authDigest, never.identity.publicKey),
        throwsA(isA<DemoAdapterError>()),
      );
    });
  });
}
