/// Unit tests for ExternalSignerManagerAdapter.
///
/// Tests the adapter's wallet-connector routing logic without requiring a live
/// wallet or network connection. In-memory G-address keypair signing is handled
/// by the kit-owned OZExternalSignerManager; this adapter covers only the
/// wallet-connector path.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/wallet/external_signer_manager_adapter.dart';
import 'package:smart_account_demo/wallet/wallet_connector.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Signs `SHA-256(preimage)` with [keypair] and returns the base64 Ed25519
/// signature — the same shape an honest wallet would return. Required so the
/// adapter's cryptographic recheck accepts the mock connector's response.
String _signPreimageBase64(KeyPair keypair, Uint8List preimage) {
  final payload = Uint8List.fromList(crypto.sha256.convert(preimage).bytes);
  return base64Encode(keypair.sign(payload));
}

/// Builds a structurally valid mock 64-byte Ed25519 signature (non-zero) but
/// NOT cryptographically valid. Used in disconnect tests that never call
/// signAuthEntry.
String _makeStructurallyValidSig() {
  final bytes = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    bytes[i] = (i % 127) + 1; // non-zero
  }
  return base64Encode(bytes);
}

/// A minimal [WalletConnector] that returns [signatureBase64] for every
/// signing request.
class _FakeConnector implements WalletConnector {
  _FakeConnector({
    required this.address,
    required String signatureBase64,
  }) : _sig = signatureBase64;

  final String address;
  final String _sig;

  bool _disconnected = false;

  @override
  String? get connectedAddress => _disconnected ? null : address;

  @override
  WalletMetadata? get walletMetadata => null;

  @override
  Future<String?> connect() async => address;

  @override
  Future<void> disconnect() async => _disconnected = true;

  @override
  Future<SignedAuthEntry> signAuthEntry({
    required String authEntryXdr,
    required List<int> contextRuleIds,
  }) async {
    return SignedAuthEntry(
      signedAuthEntry: _sig,
      signerAddress: address,
    );
  }

  @override
  Future<bool> restoreSession() async => false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('wallet connector routing', () {
    late ExternalSignerManagerAdapter adapter;
    late KeyPair walletKp;
    late _FakeConnector connector;
    // Fixed preimage so the mock's signature pre-computation can match what
    // the adapter cryptographically rechecks against.
    final Uint8List fixedPreimage = Uint8List(32);

    setUp(() {
      walletKp = KeyPair.random();
      connector = _FakeConnector(
        address: walletKp.accountId,
        signatureBase64: _signPreimageBase64(walletKp, fixedPreimage),
      );
      adapter = ExternalSignerManagerAdapter()..walletConnector = connector;
    });

    test('canSignFor returns true for the connector address', () {
      expect(adapter.canSignFor(walletKp.accountId), isTrue);
    });

    test('canSignFor returns false for another address', () {
      expect(adapter.canSignFor(KeyPair.random().accountId), isFalse);
    });

    test('canSignFor returns false when no connector is set', () {
      final bare = ExternalSignerManagerAdapter();
      expect(bare.canSignFor(walletKp.accountId), isFalse);
    });

    test('getConnectedWallets returns the connector address', () {
      final wallets = adapter.getConnectedWallets();
      expect(wallets.length, 1);
      expect(wallets.first.address, walletKp.accountId);
    });

    test('getWalletForAddress returns wallet info when address matches', () {
      final wallet = adapter.getWalletForAddress(walletKp.accountId);
      expect(wallet, isNotNull);
      expect(wallet!.address, walletKp.accountId);
    });

    test('getWalletForAddress returns null for unrecognised address', () {
      final wallet = adapter.getWalletForAddress(KeyPair.random().accountId);
      expect(wallet, isNull);
    });

    test(
      'signAuthEntry delegates to connector when address matches',
      () async {
        final preimageXdr = base64Encode(fixedPreimage);
        final result = await adapter.signAuthEntry(
          preimageXdr,
          options: SignAuthEntryOptions(
            networkPassphrase: 'Test SDF Network ; September 2015',
            address: walletKp.accountId,
          ),
        );
        expect(result.signedAuthEntry, isNotEmpty);
        expect(result.signerAddress, walletKp.accountId);
      },
    );

    test(
      'signAuthEntry throws SignerException for unknown address',
      () async {
        final preimageXdr = base64Encode(fixedPreimage);
        expect(
          () => adapter.signAuthEntry(
            preimageXdr,
            options: SignAuthEntryOptions(
              networkPassphrase: 'Test SDF Network ; September 2015',
              address: KeyPair.random().accountId,
            ),
          ),
          throwsA(isA<SignerException>()),
        );
      },
    );
  });

  group('disconnectByAddress', () {
    test('disconnects the connector when address matches', () async {
      final kp = KeyPair.random();
      final connector = _FakeConnector(
        address: kp.accountId,
        signatureBase64: _makeStructurallyValidSig(),
      );
      final adapter = ExternalSignerManagerAdapter()
        ..walletConnector = connector;

      expect(adapter.canSignFor(kp.accountId), isTrue);
      await adapter.disconnectByAddress(kp.accountId);
      // After disconnect, the connector is cleared.
      expect(adapter.walletConnector, isNull);
    });

    test('is a no-op when address does not match connector', () async {
      final kp = KeyPair.random();
      final other = KeyPair.random();
      final connector = _FakeConnector(
        address: kp.accountId,
        signatureBase64: _makeStructurallyValidSig(),
      );
      final adapter = ExternalSignerManagerAdapter()
        ..walletConnector = connector;

      // Disconnecting a different address should not clear the connector.
      await adapter.disconnectByAddress(other.accountId);
      expect(adapter.walletConnector, isNotNull);
    });
  });

  group('connect / disconnect', () {
    test('connect returns null when no connector is set', () async {
      final adapter = ExternalSignerManagerAdapter();
      final result = await adapter.connect();
      expect(result, isNull);
    });

    test('disconnect is a no-op when no connector is set', () async {
      final adapter = ExternalSignerManagerAdapter();
      await expectLater(adapter.disconnect(), completes);
    });

    test('disconnect clears the wallet connector', () async {
      final kp = KeyPair.random();
      final connector = _FakeConnector(
        address: kp.accountId,
        signatureBase64: _makeStructurallyValidSig(),
      );
      final adapter = ExternalSignerManagerAdapter()
        ..walletConnector = connector;
      expect(adapter.walletConnector, isNotNull);
      await adapter.disconnect();
      expect(adapter.walletConnector, isNull);
    });
  });
}
