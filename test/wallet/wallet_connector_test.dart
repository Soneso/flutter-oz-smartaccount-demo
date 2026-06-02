import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/wallet/wallet_connector.dart';

// ---------------------------------------------------------------------------
// Minimal stub for WalletConnector
// ---------------------------------------------------------------------------

/// A minimal in-memory [WalletConnector] used to test the shared value types
/// and exception hierarchy. Does not perform any actual network operations.
class _StubConnector implements WalletConnector {
  _StubConnector({
    String? address,
    bool rejectNextSign = false,
  }) : _address = address,
       _rejectNextSign = rejectNextSign;

  String? _address;
  final bool _rejectNextSign;

  @override
  Future<String?> connect() async => _address;

  @override
  Future<void> disconnect() async => _address = null;

  @override
  Future<bool> restoreSession() async => _address != null;

  @override
  String? get connectedAddress => _address;

  @override
  WalletMetadata? get walletMetadata =>
      _address != null ? const WalletMetadata(name: 'Stub') : null;

  @override
  Future<SignedAuthEntry> signAuthEntry({
    required String authEntryXdr,
    required List<int> contextRuleIds,
  }) async {
    if (_rejectNextSign) {
      throw const WalletSigningException('User rejected signing request.');
    }
    return SignedAuthEntry(
      signedAuthEntry: 'base64-stub-signature',
      signerAddress: _address!,
    );
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SignedAuthEntry', () {
    test('holds signedAuthEntry and signerAddress', () {
      const entry = SignedAuthEntry(
        signedAuthEntry: 'AAAAAA==',
        signerAddress: 'GABC123',
      );
      expect(entry.signedAuthEntry, 'AAAAAA==');
      expect(entry.signerAddress, 'GABC123');
    });
  });

  group('WalletMetadata', () {
    test('can be constructed with name only', () {
      const meta = WalletMetadata(name: 'TestWallet');
      expect(meta.name, 'TestWallet');
      expect(meta.url, isNull);
      expect(meta.iconUrl, isNull);
    });

    test('can be constructed with all fields', () {
      const meta = WalletMetadata(
        name: 'Freighter',
        url: 'https://www.freighter.app',
        iconUrl: 'https://www.freighter.app/icon.png',
      );
      expect(meta.url, 'https://www.freighter.app');
      expect(meta.iconUrl, 'https://www.freighter.app/icon.png');
    });
  });

  group('WalletConnectionException', () {
    test('stores message', () {
      const e = WalletConnectionException('not installed');
      expect(e.message, 'not installed');
      expect(e.cause, isNull);
    });

    test('stores message and cause', () {
      final inner = Exception('inner');
      final e = WalletConnectionException('outer', cause: inner);
      expect(e.cause, same(inner));
    });

    test('toString includes message', () {
      const e = WalletConnectionException('test error');
      expect(e.toString(), contains('test error'));
    });
  });

  group('WalletSigningException', () {
    test('stores message and optional cause', () {
      const e = WalletSigningException('rejected');
      expect(e.message, 'rejected');
      expect(e.cause, isNull);
    });

    test('cause is stored when provided', () {
      final inner = StateError('boom');
      final e = WalletSigningException('failed', cause: inner);
      expect(e.cause, same(inner));
    });
  });

  group('WalletNetworkMismatchException', () {
    test('stores expected and actual', () {
      const e = WalletNetworkMismatchException(
        expected: 'Test SDF Network ; September 2015',
        actual: 'Public Global Stellar Network ; September 2015',
      );
      expect(e.expected, 'Test SDF Network ; September 2015');
      expect(e.actual, 'Public Global Stellar Network ; September 2015');
    });

    test('toString mentions both passphrases', () {
      const e = WalletNetworkMismatchException(
        expected: 'testnet',
        actual: 'mainnet',
      );
      expect(e.toString(), contains('testnet'));
      expect(e.toString(), contains('mainnet'));
    });
  });

  group('_StubConnector (integration of interface)', () {
    test('connect returns configured address', () async {
      final c = _StubConnector(address: 'GABC1234');
      expect(await c.connect(), 'GABC1234');
    });

    test('disconnect clears address', () async {
      final c = _StubConnector(address: 'GABC1234');
      await c.disconnect();
      expect(c.connectedAddress, isNull);
    });

    test('restoreSession returns true when address is set', () async {
      final c = _StubConnector(address: 'G123');
      expect(await c.restoreSession(), isTrue);
    });

    test('restoreSession returns false when address is null', () async {
      final c = _StubConnector();
      expect(await c.restoreSession(), isFalse);
    });

    test('signAuthEntry returns signed entry on success', () async {
      final c = _StubConnector(address: 'GABC');
      final result = await c.signAuthEntry(
        authEntryXdr: 'AAAAAA==',
        contextRuleIds: const [],
      );
      expect(result.signedAuthEntry, isNotEmpty);
      expect(result.signerAddress, 'GABC');
    });

    test('signAuthEntry throws WalletSigningException on rejection', () async {
      final c = _StubConnector(address: 'GABC', rejectNextSign: true);
      expect(
        () => c.signAuthEntry(authEntryXdr: 'A==', contextRuleIds: const []),
        throwsA(isA<WalletSigningException>()),
      );
    });

    test('walletMetadata returns non-null when connected', () {
      final c = _StubConnector(address: 'GABC');
      expect(c.walletMetadata?.name, 'Stub');
    });

    test('walletMetadata returns null when disconnected', () {
      final c = _StubConnector();
      expect(c.walletMetadata, isNull);
    });
  });
}
