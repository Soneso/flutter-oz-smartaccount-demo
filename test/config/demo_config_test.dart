import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart';

void main() {
  group('DemoConfig constants — format validation', () {
    // -------------------------------------------------------------------------
    // Network
    // -------------------------------------------------------------------------

    test('rpcUrl is a valid HTTPS URL', () {
      expect(rpcUrl, startsWith('https://'));
      expect(Uri.tryParse(rpcUrl), isNotNull);
    });

    test('networkPassphrase is the Stellar testnet passphrase', () {
      expect(networkPassphrase, equals('Test SDF Network ; September 2015'));
    });

    // -------------------------------------------------------------------------
    // C-addresses (contract addresses start with 'C', length 56)
    // -------------------------------------------------------------------------

    void expectCAddress(String label, String value) {
      test('$label is a valid C-address', () {
        expect(
          value,
          allOf(
            startsWith('C'),
            hasLength(56),
            matches(RegExp(r'^[A-Z2-7]+$')),
          ),
          reason: '$label must be a valid Stellar contract address',
        );
      });
    }

    expectCAddress('webauthnVerifierAddress', webauthnVerifierAddress);
    expectCAddress('ed25519VerifierAddress', ed25519VerifierAddress);
    expectCAddress('nativeTokenContract', nativeTokenContract);

    // -------------------------------------------------------------------------
    // WASM hash (64 lowercase hex characters)
    // -------------------------------------------------------------------------

    test('accountWasmHash is 64 lowercase hex characters', () {
      expect(
        accountWasmHash,
        allOf(
          hasLength(64),
          matches(RegExp(r'^[0-9a-f]+$')),
        ),
        reason: 'accountWasmHash must be a SHA-256 hex digest',
      );
    });

    // -------------------------------------------------------------------------
    // Service URLs
    // -------------------------------------------------------------------------

    test('defaultRelayerUrl is a valid HTTPS URL', () {
      expect(defaultRelayerUrl, startsWith('https://'));
      expect(Uri.tryParse(defaultRelayerUrl), isNotNull);
    });

    test('defaultIndexerUrl is a valid HTTPS URL', () {
      expect(defaultIndexerUrl, startsWith('https://'));
      expect(Uri.tryParse(defaultIndexerUrl), isNotNull);
    });

    // -------------------------------------------------------------------------
    // WebAuthn RP
    // -------------------------------------------------------------------------

    test('defaultRpId is a non-empty domain', () {
      expect(defaultRpId, isNotEmpty);
      expect(defaultRpId, equals('soneso.com'));
    });

    test('rpName is non-empty', () {
      expect(rpName, isNotEmpty);
    });

    // -------------------------------------------------------------------------
    // Reown
    // -------------------------------------------------------------------------

    test('reownProjectId is blank by default, or a valid 32-hex ID when set',
        () {
      // Blank by default: external-wallet connect is disabled and the
      // connector is not created until a project ID is provided. When a
      // developer sets one, it must be a valid Reown project ID (32 lowercase
      // hex characters).
      if (reownProjectId.isEmpty) {
        expect(reownProjectId, isEmpty);
      } else {
        expect(
          reownProjectId,
          allOf(
            hasLength(32),
            matches(RegExp(r'^[0-9a-f]+$')),
          ),
          reason: 'Reown project IDs are 32 lowercase hex characters',
        );
      }
    });

    // -------------------------------------------------------------------------
    // Demo token
    // -------------------------------------------------------------------------

    test('demoTokenDecimals is 7', () {
      expect(demoTokenDecimals, equals(7));
    });

    test('demoTokenMintAmount is positive', () {
      expect(demoTokenMintAmount, greaterThan(0));
    });

    test('demoTokenAdminSeed is the expected non-empty string', () {
      expect(demoTokenAdminSeed, isNotEmpty);
      // The seed must be unique to avoid collisions with other demos
      // deployed on the same testnet using prefix-based derivation.
      expect(
        demoTokenAdminSeed.toLowerCase(),
        isNot(contains('kmp')),
        reason: 'Admin seed must be unique; sharing a prefix with another '
            'demo on the same testnet produces an identical contract address.',
      );
    });

    test('demoTokenSaltSeed is non-empty and differs from adminSeed', () {
      expect(demoTokenSaltSeed, isNotEmpty);
      expect(demoTokenSaltSeed, isNot(equals(demoTokenAdminSeed)));
    });

    // -------------------------------------------------------------------------
    // Context rule scan cap
    // -------------------------------------------------------------------------

    test('maxContextRuleScanId is positive and reasonable', () {
      expect(maxContextRuleScanId, greaterThan(0));
      expect(
        maxContextRuleScanId,
        lessThanOrEqualTo(1000),
        reason: 'Scan cap must not be unboundedly large',
      );
    });

    // -------------------------------------------------------------------------
    // Known policies
    // -------------------------------------------------------------------------

    test('knownPolicies has exactly 3 entries', () {
      expect(knownPolicies, hasLength(3));
    });

    test('each PolicyInfo has non-empty fields and valid C-address', () {
      for (final policy in knownPolicies) {
        expect(policy.type, isNotEmpty);
        expect(policy.name, isNotEmpty);
        expect(policy.description, isNotEmpty);
        expect(
          policy.address,
          allOf(
            startsWith('C'),
            hasLength(56),
            matches(RegExp(r'^[A-Z2-7]+$')),
          ),
          reason: 'Policy address ${policy.address} must be a valid C-address',
        );
      }
    });

    test('known policy types are the expected set', () {
      final types = knownPolicies.map((p) => p.type).toSet();
      expect(
        types,
        containsAll({'threshold', 'spending_limit', 'weighted_threshold'}),
      );
    });
  });
}
