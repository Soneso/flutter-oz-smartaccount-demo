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

    test('accountWasmHash is the OZ stellar-contracts v0.8.0 build', () {
      expect(
        accountWasmHash,
        'c514d35ea67eaea9bfc1fb3327854c0c06111bc1ddebd4fe217c504c1004b9e1',
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

    test('knownPolicies offers the OZ stellar-contracts v0.8.0 deployments',
        () {
      expect(
        {for (final p in knownPolicies) p.type: p.address},
        {
          'threshold': 'CAZ2WFUDXGX265LOEARFEOYYUL6F4BYWXZLGUAWZNJY3MRFPNLSZVS4S',
          'spending_limit':
              'CC3CEYQAP6NPNFIYSWL5MVZRCPJZGWX4XO7WDEJOUVGO2FZX5OONYPA5',
          'weighted_threshold':
              'CDBYLFLUNPAYGE3AHZSMB4TFWECFCCHX6CJFMFO6HRPKK2W5PFU2LCKE',
        },
      );
    });

    test(
        'recognizedPolicies lists the offered policies, then the v0.7.0 '
        'deployments labeled "(v0.7.0)"', () {
      expect(recognizedPolicies.take(3), orderedEquals(knownPolicies));
      final legacy = recognizedPolicies.skip(3).toList();
      expect(
        [for (final p in legacy) (p.type, p.name, p.address)],
        [
          (
            'threshold',
            'Threshold (M-of-N) (v0.7.0)',
            'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
          ),
          (
            'spending_limit',
            'Spending Limit (v0.7.0)',
            'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L',
          ),
          (
            'weighted_threshold',
            'Weighted Threshold (v0.7.0)',
            'CAF4OCRIB73T5777UWAQS7KGOG6WVIZ3EFXNNUYSPFSBKW2Q5XEIOSPW',
          ),
        ],
      );
      for (var i = 0; i < legacy.length; i++) {
        expect(legacy[i].description, knownPolicies[i].description);
      }
    });

    // -------------------------------------------------------------------------
    // Coordination server ship-blocker guard
    // -------------------------------------------------------------------------

    group('coordinationConfigShipBlocker', () {
      test('blocks the development token', () {
        // The default token argument is the development token.
        final blocker = coordinationConfigShipBlocker(
          url: 'https://coordination.example.com',
        );
        expect(blocker, isNotNull);
        expect(blocker, contains('development coordination token'));
      });

      test('blocks an empty token', () {
        final blocker = coordinationConfigShipBlocker(
          token: '',
          url: 'https://coordination.example.com',
        );
        expect(blocker, isNotNull);
      });

      test('blocks a cleartext (non-HTTPS) endpoint', () {
        // The default URL argument is the cleartext localhost endpoint.
        final blocker = coordinationConfigShipBlocker(
          token: 'a-real-secret-token',
        );
        expect(blocker, isNotNull);
        expect(blocker, contains('HTTPS'));
      });

      test('allows a real token over HTTPS', () {
        final blocker = coordinationConfigShipBlocker(
          token: 'a-real-secret-token',
          url: 'https://coordination.example.com',
        );
        expect(blocker, isNull);
      });

      test('the shipped defaults are unsafe (so a release build is blocked)',
          () {
        // The compile-time defaults are the local-dev token + cleartext
        // localhost; the guard must flag them so they cannot ship silently.
        expect(coordinationToken, devCoordinationToken);
        expect(coordinationServerUrl, startsWith('http://'));
        expect(coordinationConfigShipBlocker(), isNotNull);
      });
    });
  });
}
