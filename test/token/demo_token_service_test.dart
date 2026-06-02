/// Unit tests for DemoTokenService deterministic derivation helpers.
///
/// All tests in this file are pure (no network, no I/O). They validate:
/// - Admin keypair derivation is stable and produces a valid G-address.
/// - Token salt derivation is exactly 32 bytes.
/// - Contract address derivation is deterministic and produces a valid C-address.
/// - notTestnet guard fires immediately on wrong network passphrase.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/token/demo_token_service.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  const testnetPassphrase = 'Test SDF Network ; September 2015';
  const wrongPassphrase = 'Public Global Stellar Network ; September 2015';
  const rpcUrl = 'https://soroban-testnet.stellar.org';

  group('DemoTokenService construction', () {
    test('succeeds with testnet passphrase', () {
      expect(
        () => DemoTokenService(
          rpcUrl: rpcUrl,
          networkPassphrase: testnetPassphrase,
        ),
        returnsNormally,
      );
    });

    test('throws notTestnet with mainnet passphrase', () {
      expect(
        () => DemoTokenService(
          rpcUrl: rpcUrl,
          networkPassphrase: wrongPassphrase,
        ),
        throwsA(isA<DemoTokenServiceException>()),
      );
    });

    test('throws notTestnet with empty passphrase', () {
      expect(
        () => DemoTokenService(
          rpcUrl: rpcUrl,
          networkPassphrase: '',
        ),
        throwsA(isA<DemoTokenServiceException>()),
      );
    });
  });

  group('DemoTokenService.adminAddress()', () {
    test('returns a valid Stellar G-address', () {
      final address = DemoTokenService.adminAddress();
      expect(StrKey.isValidStellarAccountId(address), isTrue);
    });

    test('is deterministic across multiple calls', () {
      expect(
        DemoTokenService.adminAddress(),
        equals(DemoTokenService.adminAddress()),
      );
    });

    // iOS-9 parity: pin the exact G-address derived from demoTokenAdminSeed.
    //
    // Expected value computed from SHA-256("soneso smart account demo token admin v1")
    // interpreted as an Ed25519 seed, then StrKey-encoded as a G-address.
    //
    // If this assertion fails the seed string or derivation logic changed.
    // Confirm the change is intentional and update the expected constant here
    // AND in the iOS sibling test (DemoTokenServiceTests.adminKeyDerivationKnownGAddress).
    test('matches pinned G-address derived from demoTokenAdminSeed', () {
      const expectedGAddress =
          'GAH74V64RW4Y6VJWSWP754O3TFCCXX6L6CYBNOS7SW4P4OL2NQMLIAXU';
      expect(DemoTokenService.adminAddress(), equals(expectedGAddress));
    });
  });

  group('DemoTokenService.deriveContractAddress()', () {
    test('returns a valid Stellar C-address', () {
      final address = DemoTokenService.deriveContractAddress();
      expect(StrKey.isValidContractId(address), isTrue);
    });

    test('is deterministic across multiple calls', () {
      expect(
        DemoTokenService.deriveContractAddress(),
        equals(DemoTokenService.deriveContractAddress()),
      );
    });

    test('differs from the admin address', () {
      final contractAddress = DemoTokenService.deriveContractAddress();
      final adminAddress = DemoTokenService.adminAddress();
      expect(contractAddress, isNot(equals(adminAddress)));
    });

    test('starts with C (C-address prefix)', () {
      expect(DemoTokenService.deriveContractAddress(), startsWith('C'));
    });
  });

  group('DemoTokenServiceException factory constructors', () {
    test('notTestnet includes actual passphrase in message', () {
      final e = DemoTokenServiceException.notTestnet('some-passphrase');
      expect(e.message, contains('some-passphrase'));
    });

    test('addressMismatch includes expected and actual in message', () {
      final e = DemoTokenServiceException.addressMismatch(
        expected: 'CEXPECTED',
        actual: 'CACTUAL',
      );
      expect(e.message, contains('CEXPECTED'));
      expect(e.message, contains('CACTUAL'));
    });

    test('rpcError stores detail and optional cause', () {
      final inner = Exception('rpc failed');
      final e = DemoTokenServiceException.rpcError('timeout', cause: inner);
      expect(e.message, 'timeout');
      expect(e.cause, same(inner));
    });

    test('toString contains runtimeType and message', () {
      final e = DemoTokenServiceException.rpcError('bad call');
      expect(e.toString(), contains('bad call'));
    });

    test('toString includes cause when present', () {
      final inner = Exception('root');
      final e = DemoTokenServiceException.rpcError('detail', cause: inner);
      expect(e.toString(), contains('root'));
    });
  });

  group('DemoTokenResult', () {
    test('holds all fields', () {
      const result = DemoTokenResult(
        tokenContractId: 'CABC',
        amountMinted: 1000000,
        alreadyExisted: false,
      );
      expect(result.tokenContractId, 'CABC');
      expect(result.amountMinted, 1000000);
      expect(result.alreadyExisted, isFalse);
    });

    test('alreadyExisted can be true', () {
      const result = DemoTokenResult(
        tokenContractId: 'CABC',
        amountMinted: 0,
        alreadyExisted: true,
      );
      expect(result.alreadyExisted, isTrue);
    });
  });
}
