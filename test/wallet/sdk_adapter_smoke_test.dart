/// SDK adapter smoke test.
///
/// Verifies the integration between:
///   [ExternalSignerManagerAdapter] → [OZExternalSignerManager] → SDK
///
/// This test uses only in-memory structures (no network, no disk I/O). It
/// confirms:
///   1. Keypair signers can be added and queried.
///   2. Wallet signers are routed through the adapter.
///   3. The SDK's [OZExternalSignerManager] delegates correctly to both.
///   4. Missing signers surface as [SignerException.notFound].
///   5. The adapter rejects a wrong-payload wallet response before it reaches
///      the SDK — both the structural recheck (length, non-zero) and the
///      cryptographic recheck (Ed25519 verify against the registered
///      G-address's public key over SHA-256(preimage)). A wallet returning a
///      valid 64-byte Ed25519 signature over a DIFFERENT payload is caught
///      by the cryptographic recheck before the signature reaches the SDK.
///
/// This file must stay in sync with the ExternalWalletAdapter contract
/// defined in `oz_storage_adapter.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/wallet/external_signer_manager_adapter.dart';
import 'package:smart_account_demo/wallet/wallet_connector.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// Mock WalletConnector
// ---------------------------------------------------------------------------

/// A minimal mock [WalletConnector] that returns a fixed signature for any
/// auth entry. Used to verify the adapter's wallet routing path without a
/// live Reown or Freighter session.
class _MockWalletConnector implements WalletConnector {
  _MockWalletConnector({
    required this.address,
    required this.signedAuthEntryBase64,
  });

  final String address;
  final String signedAuthEntryBase64;

  int signCallCount = 0;
  String? lastAuthEntryXdr;

  @override
  Future<String?> connect() async => address;

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> restoreSession() async => true;

  @override
  String? get connectedAddress => address;

  @override
  WalletMetadata? get walletMetadata => const WalletMetadata(name: 'Mock');

  @override
  Future<SignedAuthEntry> signAuthEntry({
    required String authEntryXdr,
    required List<int> contextRuleIds,
  }) async {
    signCallCount++;
    lastAuthEntryXdr = authEntryXdr;
    return SignedAuthEntry(
      signedAuthEntry: signedAuthEntryBase64,
      signerAddress: address,
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Signs `SHA-256(preimage)` with [keypair] and returns the base64 Ed25519
/// signature — the same shape an honest wallet would return for [preimage].
///
/// Used by the wallet-connector path tests so the adapter's cryptographic
/// recheck (`KeyPair.fromAccountId(address).verify(...)`) accepts the
/// signature. For wrong-payload tests, sign over a different preimage.
String _signPreimageBase64(KeyPair keypair, Uint8List preimage) {
  final payload = Uint8List.fromList(crypto.sha256.convert(preimage).bytes);
  return base64Encode(keypair.sign(payload));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  const networkPassphrase = 'Test SDF Network ; September 2015';

  // Generate a fresh keypair for each test group.
  KeyPair makeKeypair() => KeyPair.random();

  group('OZExternalSignerManager — in-memory keypair path via addFromSecret', () {
    late ExternalSignerManagerAdapter adapter;
    late OZExternalSignerManager manager;
    late KeyPair keypair;

    setUp(() {
      keypair = makeKeypair();
      adapter = ExternalSignerManagerAdapter();
      manager = OZExternalSignerManager(
        networkPassphrase: networkPassphrase,
        walletAdapter: adapter,
      );
    });

    test('addFromSecret registers address and canSignFor returns true', () async {
      final address = await manager.addFromSecret(keypair.secretSeed);
      expect(address, equals(keypair.accountId));
      expect(await manager.canSignFor(keypair.accountId), isTrue);
    });

    test('canSignFor returns false for unknown address', () async {
      expect(await manager.canSignFor(KeyPair.random().accountId), isFalse);
    });

    test('getAll includes keypair signers added via addFromSecret', () async {
      await manager.addFromSecret(keypair.secretSeed);
      final signers = await manager.getAll();
      expect(
        signers.any((s) => s.address == keypair.accountId),
        isTrue,
      );
    });

    test('remove via manager.remove removes the signer from getAll', () async {
      await manager.addFromSecret(keypair.secretSeed);
      await manager.remove(keypair.accountId);
      final signers = await manager.getAll();
      expect(
        signers.any((s) => s.address == keypair.accountId),
        isFalse,
      );
    });

    test(
      'signAuthEntry with in-memory keypair produces a valid base64-encoded result',
      () async {
        await manager.addFromSecret(keypair.secretSeed);

        // Build a minimal preimage XDR — just 32 zero bytes, base64-encoded.
        final fakePreimageXdr = base64Encode(Uint8List(32));

        final result = await manager.signAuthEntry(
          keypair.accountId,
          fakePreimageXdr,
        );
        expect(result.signedAuthEntry, isNotEmpty);
        expect(result.signerAddress, keypair.accountId);

        final decoded = base64Decode(result.signedAuthEntry);
        expect(decoded, isNotEmpty);
      },
    );

    test('signAuthEntry for missing address throws SignerException', () async {
      expect(
        () => manager.signAuthEntry(
          KeyPair.random().accountId,
          base64Encode(Uint8List(32)),
        ),
        throwsA(isA<SignerException>()),
      );
    });
  });

  group('ExternalSignerManagerAdapter — wallet connector path', () {
    late _MockWalletConnector mockConnector;
    late ExternalSignerManagerAdapter adapter;
    late OZExternalSignerManager manager;
    late KeyPair walletKeypair;
    // Fixed preimage used by every test in this group so the mock's
    // signature can be pre-computed and the cryptographic recheck passes.
    final Uint8List fixedPreimage = Uint8List(32);
    late String fixedPreimageXdr;

    setUp(() {
      walletKeypair = makeKeypair();
      fixedPreimageXdr = base64Encode(fixedPreimage);

      // Mock connector returns a REAL Ed25519 signature over the same
      // SHA-256(preimage) the adapter will recheck against — required by
      // the adapter's cryptographic recheck.
      mockConnector = _MockWalletConnector(
        address: walletKeypair.accountId,
        signedAuthEntryBase64: _signPreimageBase64(walletKeypair, fixedPreimage),
      );

      adapter = ExternalSignerManagerAdapter()
        ..walletConnector = mockConnector;

      manager = OZExternalSignerManager(
        networkPassphrase: networkPassphrase,
        walletAdapter: adapter,
      );
    });

    test('canSignFor returns true when connector address matches', () async {
      expect(await manager.canSignFor(walletKeypair.accountId), isTrue);
    });

    test('canSignFor returns false for address not matching connector', () async {
      expect(await manager.canSignFor(KeyPair.random().accountId), isFalse);
    });

    test('getConnectedWallets includes the connector address', () {
      final wallets = adapter.getConnectedWallets();
      expect(wallets.any((w) => w.address == walletKeypair.accountId), isTrue);
    });

    test('getWalletForAddress returns wallet info when connector is active', () {
      final wallet = adapter.getWalletForAddress(walletKeypair.accountId);
      expect(wallet, isNotNull);
      expect(wallet!.address, walletKeypair.accountId);
    });

    test('getWalletForAddress returns null for unknown address', () {
      final wallet = adapter.getWalletForAddress(KeyPair.random().accountId);
      expect(wallet, isNull);
    });

    test(
      'signAuthEntry with wallet connector routes to mock and returns result',
      () async {
        final fakePreimageXdr = fixedPreimageXdr;
        final result = await manager.signAuthEntry(
          walletKeypair.accountId,
          fakePreimageXdr,
        );

        expect(result.signedAuthEntry, isNotEmpty);
        expect(result.signerAddress, walletKeypair.accountId);
      },
    );

    test('mock connector signAuthEntry was called once', () async {
      final fakePreimageXdr = fixedPreimageXdr;
      await manager.signAuthEntry(walletKeypair.accountId, fakePreimageXdr);
      expect(mockConnector.signCallCount, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Wrong-payload rejection test
  // ---------------------------------------------------------------------------
  //
  // The demo adapter performs the cryptographic recheck in
  // _signWithConnector(...) itself, using the registered G-address's public
  // key, so a wallet that signs the wrong payload is caught before the
  // signature reaches the SDK.
  //
  // These three tests cover both the structural recheck (length, non-zero)
  // and the cryptographic recheck (a real 64-byte Ed25519 signature over the
  // WRONG payload is caught by the adapter before the signature reaches the
  // SDK or the network).

  group('smokeTestWrongPayloadRejected — adapter rejection', () {
    test(
      'wallet connector returning wrong-length signature is rejected '
      'by adapter structural recheck with TransactionException',
      () async {
        // A 63-byte signature — shorter than the 64 bytes required for Ed25519.
        // This simulates a misbehaving wallet returning a truncated or otherwise
        // malformed response.
        final shortSig = base64Encode(Uint8List(63)..fillRange(0, 63, 0x42));

        final walletKeypair = KeyPair.random();
        final badConnector = _MockWalletConnector(
          address: walletKeypair.accountId,
          signedAuthEntryBase64: shortSig,
        );
        final adapter = ExternalSignerManagerAdapter()
          ..walletConnector = badConnector;
        final manager = OZExternalSignerManager(
          networkPassphrase: networkPassphrase,
          walletAdapter: adapter,
        );

        expect(
          () => manager.signAuthEntry(
            walletKeypair.accountId,
            base64Encode(Uint8List(32)),
          ),
          throwsA(isA<TransactionException>()),
        );
      },
    );

    test(
      'wallet connector returning all-zero 64-byte signature is rejected '
      'by adapter structural recheck with TransactionException',
      () async {
        // An all-zero 64-byte signature is structurally correct in length but
        // is not a valid Ed25519 signature for any honest signer. The adapter's
        // structural recheck detects this and rejects it.
        final zeroSig = base64Encode(Uint8List(64)); // all zeros

        final walletKeypair = KeyPair.random();
        final badConnector = _MockWalletConnector(
          address: walletKeypair.accountId,
          signedAuthEntryBase64: zeroSig,
        );
        final adapter = ExternalSignerManagerAdapter()
          ..walletConnector = badConnector;
        final manager = OZExternalSignerManager(
          networkPassphrase: networkPassphrase,
          walletAdapter: adapter,
        );

        expect(
          () => manager.signAuthEntry(
            walletKeypair.accountId,
            base64Encode(Uint8List(32)),
          ),
          throwsA(isA<TransactionException>()),
        );
      },
    );

    test(
      'wallet connector returning a real Ed25519 signature over the WRONG '
      'payload is rejected by adapter cryptographic recheck with '
      'TransactionException',
      () async {
        // Setup: the registered wallet G-address has its own keypair.
        // The mock connector signs an ATTACKER-CHOSEN payload (not the
        // preimage the adapter sent). The signature is structurally valid
        // (64 non-zero bytes from a real Ed25519 sign), so the structural
        // recheck passes. The cryptographic recheck must then catch the
        // mismatch by verifying signature against SHA-256(realPreimage).

        final walletKeypair = KeyPair.random();
        final attackerPayload = Uint8List.fromList(
          crypto.sha256.convert(utf8.encode('attacker-chosen-bytes')).bytes,
        );
        final wrongSignature = walletKeypair.sign(attackerPayload);

        final maliciousConnector = _MockWalletConnector(
          address: walletKeypair.accountId,
          signedAuthEntryBase64: base64Encode(wrongSignature),
        );
        final adapter = ExternalSignerManagerAdapter()
          ..walletConnector = maliciousConnector;
        final manager = OZExternalSignerManager(
          networkPassphrase: networkPassphrase,
          walletAdapter: adapter,
        );

        // A real (different) preimage — what the adapter actually sends to
        // the wallet. The wallet (mock) returns a signature over the wrong
        // payload above. Cryptographic verify must reject.
        final realPreimageXdr = base64Encode(
          Uint8List.fromList(utf8.encode('honest-auth-entry-preimage')),
        );

        expect(
          () => manager.signAuthEntry(
            walletKeypair.accountId,
            realPreimageXdr,
          ),
          throwsA(isA<TransactionException>()),
        );
      },
    );
  });

  group('ExternalSignerManagerAdapter — addFromSecret via SDK', () {
    late ExternalSignerManagerAdapter adapter;
    late OZExternalSignerManager manager;

    setUp(() {
      adapter = ExternalSignerManagerAdapter();
      manager = OZExternalSignerManager(
        networkPassphrase: networkPassphrase,
        walletAdapter: adapter,
      );
    });

    test('addFromSecret registers keypair signer in the SDK manager', () async {
      final kp = makeKeypair();
      final address = await manager.addFromSecret(kp.secretSeed);
      expect(address, kp.accountId);
      expect(await manager.canSignFor(address), isTrue);
    });

    test(
      'addFromSecret with invalid seed throws SignerException',
      () async {
        expect(
          () => manager.addFromSecret('NOTAVALIDSEED'),
          throwsA(isA<SignerException>()),
        );
      },
    );
  });

  group('ExternalSignerManagerAdapter — hasSigners', () {
    late ExternalSignerManagerAdapter adapter;
    late OZExternalSignerManager manager;

    setUp(() {
      adapter = ExternalSignerManagerAdapter();
      manager = OZExternalSignerManager(
        networkPassphrase: networkPassphrase,
        walletAdapter: adapter,
      );
    });

    test('hasSigners is false with empty adapter', () async {
      expect(await manager.hasSigners(), isFalse);
    });

    test('hasSigners is true after adding keypair via addFromSecret', () async {
      // hasSigners() reflects the manager's keypair signers, populated via
      // manager.addFromSecret().
      await manager.addFromSecret(makeKeypair().secretSeed);
      expect(await manager.hasSigners(), isTrue);
    });
  });
}
