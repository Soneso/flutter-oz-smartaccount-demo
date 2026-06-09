/// Unit tests for the create-mode methods added to [ContextRuleFlow].
///
/// Covers:
/// 1. addContextRule happy path (single passkey, default, no expiry, no policies)
/// 2. addContextRule with multi-signer + simple threshold policy
/// 3. addContextRule with expiry resolves to current + offset
/// 4. addContextRule failure surfaces sanitised error
/// 5. addContextRule WebAuthnCancelled returns typed result, no log leak
/// 6. registerPasskeySigner happy path uses configured verifier
/// 7. registerPasskeySigner WebAuthnCancelled rethrows
/// 8. registerPasskeySigner throws DemoError when no provider
/// 9. loadAvailablePasskeySigners filters by verifier and exclude id
/// 10. resolveAbsoluteLedger returns current + offset; null on offset = 0
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart' as config;
import 'package:smart_account_demo/flows/context_rule_builder_types.dart'
    show FlowPolicyEntry;
import 'package:smart_account_demo/flows/context_rule_flow.dart';
import 'package:smart_account_demo/util/format_utils.dart'
    show nativeTokenDecimals;
import 'package:smart_account_demo/flows/ed25519_signer_identity.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/util/error_utils.dart'
    show DemoError, DemoErrorCategory;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'context_rule_test_support.dart';

// Stellar contract address fixture for a fake Ed25519 verifier. Uses only
// the legal base32 alphabet (A-Z + 2-7) so StrKey decoding succeeds.
const String _fakeEd25519Verifier =
    'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6';

void main() {
  // ---------------------------------------------------------------------------
  // addContextRule
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.addContextRule', () {
    test('happy path: single delegated signer, default, no expiry, no policies',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(success: true, hash: 'abc123');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      final result = await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'DefaultRule',
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: const <FlowPolicyEntry>[],
      );

      expect(result.success, isTrue);
      expect(result.hash, 'abc123');
      expect(mgr.addCallCount, 1);
      expect(mgr.lastAddedName, 'DefaultRule');
      expect(mgr.lastAddedSigners?.length, 1);
      expect(mgr.lastAddedPolicies, isEmpty);
      expect(mgr.lastAddedSelectedSigners, isEmpty);
      expect(mgr.lastAddedValidUntil, isNull);
      expect(
        deps.logEntries.any(
          (e) =>
              e.level == LogLevel.success &&
              e.message.contains('Context rule created successfully'),
        ),
        isTrue,
      );
    });

    test('forwards multi-signer selectedSigners list verbatim', () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(success: true, hash: 'deadbeef');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      final result = await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'MultiSig',
        signers: [
          OZDelegatedSigner(fixtureDelegatedAddress1),
          OZDelegatedSigner(fixtureDelegatedAddress2),
        ],
        policies: [
          const FlowPolicyEntry(
            address:
                'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
            installParams: OZSimpleThresholdPolicyParams(threshold: 2),
          ),
        ],
        selectedSigners: const <OZSelectedSigner>[
          OZSelectedSignerPasskey(),
          OZSelectedSignerWallet(fixtureDelegatedAddress2),
        ],
      );

      expect(result.success, isTrue);
      expect(mgr.lastAddedSelectedSigners?.length, 2);
      expect(mgr.lastAddedPolicies?.length, 1);
      expect(
        mgr.lastAddedPolicies?.keys.first,
        'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
      );
    });

    test('failure: SDK result with success=false surfaces the raw on-chain '
        'error verbatim under the "Failed to create context rule" prefix',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(
          success: false,
          error: 'on-chain rejected: bad XDR payload',
        );

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      final result = await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'rule',
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: const <FlowPolicyEntry>[],
      );

      expect(result.success, isFalse);
      expect(
        result.error,
        'Failed to create context rule: on-chain rejected: bad XDR payload',
      );
      expect(
        deps.logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
      );
    });

    test('WebAuthnCancelled returns typed failure without leaking message',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..addError = const WebAuthnCancelled(message: 'user dismissed');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      final result = await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'rule',
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: const <FlowPolicyEntry>[],
      );

      expect(result.success, isFalse);
      expect(result.error, 'Passkey authentication cancelled');
      expect(
        deps.logEntries.any(
          (e) => e.message.contains('Passkey authentication cancelled'),
        ),
        isTrue,
      );
    });

    test('skips policies whose SCVal is null', () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(success: true, hash: 'h');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'rule',
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: const [
          FlowPolicyEntry(
            address:
                'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
            installParams: null,
          ),
        ],
      );

      expect(mgr.lastAddedPolicies, isEmpty);
    });

    test('re-entry guard: concurrent calls throw StateError', () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(success: true, hash: 'h');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      // First call is in-flight (manager future is microtask-immediate but
      // we await sequentially) — the second call before the first resolves
      // should throw. Use Future.wait to start both before either resolves.
      final f1 = deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'rule',
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: const <FlowPolicyEntry>[],
      );
      expect(
        () => deps.flow.addContextRule(
          contextType: const OZContextRuleTypeDefault(),
          name: 'rule2',
          signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
          policies: const <FlowPolicyEntry>[],
        ),
        throwsA(isA<StateError>()),
      );
      await f1;
    });
  });

  // ---------------------------------------------------------------------------
  // registerPasskeySigner
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.registerPasskeySigner', () {
    test('builds an OZExternalSigner with the configured verifier', () async {
      final provider = MockWebAuthnProvider(
        registerResult: WebAuthnRegistrationResult(
          credentialId: ContextRuleFixtures.makeCredentialIdBytes(),
          publicKey: ContextRuleFixtures.makeWebAuthnPublicKey(),
          attestationObject: Uint8List(8),
        ),
      );
      final env = MockBuilderEnvironment(webauthnProvider: provider);
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final signer = await deps.flow.registerPasskeySigner('My Recovery Key');

      expect(signer, isA<OZExternalSigner>());
      final ext = signer as OZExternalSigner;
      expect(ext.verifierAddress, env.webauthnVerifierAddress);
      expect(provider.registerCallCount, 1);
      expect(provider.lastRegisterUserName, 'My Recovery Key');
      expect(
        deps.logEntries.any(
          (e) => e.message.contains('Starting passkey registration'),
        ),
        isTrue,
      );
    });

    test('throws DemoError when no WebAuthn provider is configured', () async {
      final env = MockBuilderEnvironment();
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      await expectLater(
        () => deps.flow.registerPasskeySigner('Recovery'),
        throwsA(
          isA<DemoError>().having(
            (e) => e.category,
            'category',
            DemoErrorCategory.unexpected,
          ),
        ),
      );
    });

    test('rethrows WebAuthnCancelled when user dismisses prompt', () async {
      final provider = MockWebAuthnProvider(
        registerError: const WebAuthnCancelled(message: 'dismissed'),
      );
      final env = MockBuilderEnvironment(webauthnProvider: provider);
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      await expectLater(
        () => deps.flow.registerPasskeySigner('rk'),
        throwsA(isA<WebAuthnCancelled>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // loadAvailablePasskeySigners
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.loadAvailablePasskeySigners', () {
    test('filters out signers whose verifier does not match WebAuthn',
        () async {
      final env = MockBuilderEnvironment();
      final webauthnPasskey = OZExternalSigner.webAuthn(
        verifierAddress: env.webauthnVerifierAddress,
        publicKey: ContextRuleFixtures.makeWebAuthnPublicKey(),
        credentialId: ContextRuleFixtures.makeCredentialIdBytes(seed: 0x30),
      );
      final ed25519 = OZExternalSigner.ed25519(
        verifierAddress: _fakeEd25519Verifier,
        publicKey: Uint8List(32),
      );

      final mgr = MockContextRuleFlowManager()
        ..rules = [
          makeRule(
            id: 1,
            signers: [
              webauthnPasskey,
              ed25519,
            ],
          ),
        ];

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: env,
      );

      final loaded = await deps.flow.loadAvailablePasskeySigners();
      expect(loaded.length, 1);
      expect(loaded.first.verifierAddress, env.webauthnVerifierAddress);
    });

    test('excludes the entry whose credential id matches excludeCredentialId',
        () async {
      final env = MockBuilderEnvironment();
      final excluded = OZExternalSigner.webAuthn(
        verifierAddress: env.webauthnVerifierAddress,
        publicKey: ContextRuleFixtures.makeWebAuthnPublicKey(),
        credentialId: ContextRuleFixtures.makeCredentialIdBytes(seed: 0x40),
      );
      final excludedCredId =
          OZSmartAccountBuilders.getCredentialIdStringFromSigner(excluded);
      final kept = OZExternalSigner.webAuthn(
        verifierAddress: env.webauthnVerifierAddress,
        publicKey: ContextRuleFixtures.makeWebAuthnPublicKey(seed: 0xCC),
        credentialId: ContextRuleFixtures.makeCredentialIdBytes(seed: 0x50),
      );

      final mgr = MockContextRuleFlowManager()
        ..rules = [
          makeRule(id: 1, signers: [excluded, kept]),
        ];

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: env,
      );

      final loaded = await deps.flow.loadAvailablePasskeySigners(
        excludeCredentialId: excludedCredId,
      );
      expect(loaded.length, 1);
      final keptCredId =
          OZSmartAccountBuilders.getCredentialIdStringFromSigner(loaded.first);
      expect(keptCredId, isNot(excludedCredId));
    });

    test('deduplicates passkeys across multiple rules', () async {
      final env = MockBuilderEnvironment();
      final passkey = OZExternalSigner.webAuthn(
        verifierAddress: env.webauthnVerifierAddress,
        publicKey: ContextRuleFixtures.makeWebAuthnPublicKey(seed: 0x21),
        credentialId: ContextRuleFixtures.makeCredentialIdBytes(seed: 0x22),
      );

      final mgr = MockContextRuleFlowManager()
        ..rules = [
          makeRule(id: 1, signers: [passkey]),
          makeRule(id: 2, signers: [passkey]),
        ];

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: env,
      );

      final loaded = await deps.flow.loadAvailablePasskeySigners();
      expect(loaded.length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // resolveAbsoluteLedger
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.resolveAbsoluteLedger', () {
    test('returns current ledger + offset', () async {
      final env = MockBuilderEnvironment(currentLedger: 12000);
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final resolved = await deps.flow.resolveAbsoluteLedger(720);
      expect(resolved, 12720);
      expect(env.getCurrentLedgerCallCount, 1);
    });

    test('returns null when offset is zero', () async {
      final env = MockBuilderEnvironment();
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final resolved = await deps.flow.resolveAbsoluteLedger(0);
      expect(resolved, isNull);
      expect(env.getCurrentLedgerCallCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // resolveSpendingLimitDecimals
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.resolveSpendingLimitDecimals', () {
    const customToken =
        'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC';

    test('null guarded token resolves to native decimals without a fetch',
        () async {
      final env = MockBuilderEnvironment();
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final resolved = await deps.flow.resolveSpendingLimitDecimals(null);
      expect(resolved, nativeTokenDecimals);
      expect(env.fetchTokenDecimalsCallCount, 0);
    });

    test('native token resolves to native decimals without a fetch', () async {
      final env = MockBuilderEnvironment();
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final resolved = await deps.flow
          .resolveSpendingLimitDecimals(config.nativeTokenContract);
      expect(resolved, nativeTokenDecimals);
      expect(env.fetchTokenDecimalsCallCount, 0);
    });

    test('custom guarded token fetches the on-chain decimals', () async {
      final env = MockBuilderEnvironment()..tokenDecimals = 6;
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final resolved =
          await deps.flow.resolveSpendingLimitDecimals(customToken);
      expect(resolved, 6);
      expect(env.fetchTokenDecimalsCallCount, 1);
      expect(env.lastFetchTokenDecimalsContract, customToken);
    });

    test('malformed guarded token falls back to native decimals', () async {
      final env = MockBuilderEnvironment();
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final resolved =
          await deps.flow.resolveSpendingLimitDecimals('not-an-address');
      expect(resolved, nativeTokenDecimals);
      expect(env.fetchTokenDecimalsCallCount, 0);
    });

    test('a fetch failure propagates so the caller can gate the form',
        () async {
      final env = MockBuilderEnvironment()
        ..fetchTokenDecimalsError = StateError('rpc down');
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      await expectLater(
        deps.flow.resolveSpendingLimitDecimals(customToken),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // buildDelegatedSigner / buildEd25519Signer
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.buildDelegatedSigner', () {
    test('constructs OZDelegatedSigner for a valid G-address', () {
      final env = MockBuilderEnvironment();
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final signer = deps.flow.buildDelegatedSigner(fixtureDelegatedAddress1);
      expect(signer, isA<OZDelegatedSigner>());
      expect((signer as OZDelegatedSigner).address, fixtureDelegatedAddress1);
    });
  });

  group('ContextRuleFlow.buildEd25519Signer', () {
    test('uses environment verifier address', () {
      final env = MockBuilderEnvironment(
        ed25519VerifierAddress: _fakeEd25519Verifier,
      );
      final deps = ContextRuleFixtures.makeFlowWithDeps(environment: env);

      final signer = deps.flow.buildEd25519Signer(Uint8List(32));
      expect(signer, isA<OZExternalSigner>());
      expect(
        (signer as OZExternalSigner).verifierAddress,
        _fakeEd25519Verifier,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Environment guard
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow without environment', () {
    test('resolveAbsoluteLedger throws StateError when env is null', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      await expectLater(
        () => deps.flow.resolveAbsoluteLedger(100),
        throwsA(isA<StateError>()),
      );
    });

    test('loadAvailablePasskeySigners throws StateError when env is null',
        () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      await expectLater(
        () => deps.flow.loadAvailablePasskeySigners(),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // classifyAddRuleError
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.classifyAddRuleError', () {
    test('maps WebAuthnCancelled to user-facing string', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyAddRuleError(
        const WebAuthnCancelled(message: 'dismissed'),
      );
      expect(msg, 'Passkey authentication cancelled');
    });

    test('maps StateError to in-progress message', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyAddRuleError(StateError('busy'));
      expect(msg, contains('already in progress'));
    });

    test('passes DemoError validation messages through verbatim', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyAddRuleError(
        const DemoError(
          message: 'Rule name is required.',
          category: DemoErrorCategory.validation,
        ),
      );
      expect(msg, 'Rule name is required.');
    });

    test('prefixes non-validation DemoError messages with "Transaction failed:"',
        () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyAddRuleError(
        const DemoError(
          message: 'No passkey provider is available on this device.',
          category: DemoErrorCategory.unexpected,
        ),
      );
      expect(msg, contains('Transaction failed:'));
      expect(msg, contains('No passkey provider is available on this device.'));
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 3 — addContextRule with expiry resolves to current + offset
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.addContextRule — with expiry', () {
    test('validUntil resolves to current ledger + supplied offset', () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(success: true, hash: 'expiryhash');
      final env = MockBuilderEnvironment(currentLedger: 10000);
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: env,
      );

      final resolved = await deps.flow.resolveAbsoluteLedger(720);
      expect(resolved, 10720);

      final result = await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'WithExpiry',
        validUntil: resolved,
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: const <FlowPolicyEntry>[],
      );

      expect(result.success, isTrue);
      expect(mgr.lastAddedValidUntil, 10720);
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 4 — multi-signer delegated-keypair registration lifecycle
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow — multi-signer delegated keypair lifecycle', () {
    test('registerDelegatedKeypairs no-ops when kit is absent', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      // No kit in unit-test mode — must complete without throwing.
      await expectLater(
        deps.flow.registerDelegatedKeypairs({'GABC...': 'any-value'}),
        completes,
      );
    });

    test('no-ops when kit is absent (invalid seed)', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      await expectLater(
        deps.flow.registerDelegatedKeypairs({'GABC...': 'invalid-seed'}),
        completes,
      );
      await deps.flow.clearDelegatedKeypairs();
    });

    test('registers and clears delegated keypairs via fake manager', () async {
      final deps = ContextRuleFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      await deps.flow.registerDelegatedKeypairs({kp.accountId: kp.secretSeed});
      expect(deps.fakeManager.registeredAddresses, hasLength(1));

      await deps.flow.clearDelegatedKeypairs();
      expect(deps.fakeManager.registeredAddresses, isEmpty);
    });

    test('withCleanupOfDelegatedKeypairs clears delegated addresses on body success', () async {
      final deps = ContextRuleFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      await deps.flow.registerDelegatedKeypairs({kp.accountId: kp.secretSeed});
      await deps.flow.withCleanupOfDelegatedKeypairs(() async {});

      expect(deps.fakeManager.registeredAddresses, isEmpty);
    });

    test('withCleanupOfDelegatedKeypairs clears delegated addresses when body throws', () async {
      final deps = ContextRuleFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      await deps.flow.registerDelegatedKeypairs({kp.accountId: kp.secretSeed});

      await expectLater(
        deps.flow.withCleanupOfDelegatedKeypairs(
          () async => throw Exception('body error'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(deps.fakeManager.registeredAddresses, isEmpty);
    });

    // Regression (cancel-leak guard): when Ed25519 registration throws after
    // the delegated keypairs were already registered, withMultiSignerRegistration
    // must clear the delegated keypairs itself — without the test calling any
    // cleanup. This drives the method that OWNS the wrap-both-registrations
    // sequence, so it fails if Ed25519 registration is moved outside the wrapper.
    test('withMultiSignerRegistration clears delegated keypairs when Ed25519 '
        'registration throws (no manual cleanup)', () async {
      final deps = ContextRuleFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      // A bad (non-32-byte) seed makes the in-process Ed25519 registration throw.
      final ed25519Kp = KeyPair.random();
      final pubKey = Uint8List.fromList(ed25519Kp.publicKey);
      final identity = Ed25519SignerIdentity(
        verifierAddress: fixtureContractId,
        publicKey: pubKey,
      );

      var bodyRan = false;
      await expectLater(
        deps.flow.withMultiSignerRegistration<void>(
          delegatedKeyPairs: {kp.accountId: kp.secretSeed},
          ed25519Secrets: {identity: Uint8List(4)},
          body: () async {
            bodyRan = true;
          },
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Body must not run when registration fails.
      expect(bodyRan, isFalse,
          reason: 'body must not run when Ed25519 registration throws');

      // The method itself cleaned up the delegated keypair registered first;
      // the test performed no cleanup of its own. If Ed25519 registration were
      // moved outside the guarded region, the delegated keypair would leak and
      // this assertion would fail.
      expect(
        deps.fakeManager.registeredAddresses,
        isEmpty,
        reason: 'delegated keypairs must not leak when Ed25519 registration throws',
      );
    });
  });


  // ---------------------------------------------------------------------------
  // Scenario 8 — addContextRule input validation surfacing
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.addContextRule — validation surfacing', () {
    test('on-chain "invalid input" error is surfaced verbatim with the '
        '"Failed to create context rule" prefix', () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(
          success: false,
          error: 'invocation failed: invalid input bytes 0xDEADBEEF',
        );
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      final result = await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'rule',
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: const <FlowPolicyEntry>[],
      );

      expect(result.success, isFalse);
      expect(
        result.error,
        'Failed to create context rule: invocation failed: '
        'invalid input bytes 0xDEADBEEF',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 9 — policy SCVal round-trip preserves bytes
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.addContextRule — policy SCVal round-trip', () {
    test('FlowPolicyEntry.installParams is encoded into the manager.policies '
        'map', () async {
      final mgr = MockContextRuleFlowManager()
        ..addResult = OZTransactionResult(success: true, hash: 'policyhash');
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      const policyAddress =
          'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC';

      await deps.flow.addContextRule(
        contextType: const OZContextRuleTypeDefault(),
        name: 'PolicyRule',
        signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        policies: [
          const FlowPolicyEntry(
            address: policyAddress,
            installParams: OZSimpleThresholdPolicyParams(threshold: 3),
          ),
        ],
      );

      expect(mgr.lastAddedPolicies?.length, 1);
      final encoded = mgr.lastAddedPolicies?[policyAddress];
      expect(encoded, isNotNull);
      // The flow encodes the typed params to the on-chain
      // `{ symbol("threshold"): u32(3) }` map.
      final entries = encoded!.map;
      expect(entries, isNotNull);
      expect(entries!.length, 1);
      expect(entries.first.key.sym, 'threshold');
      expect(entries.first.val.u32?.uint32, 3);
    });
  });

  // ---------------------------------------------------------------------------
  // Context-type builders
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow context-type builders', () {
    test('buildDefaultContextType returns a Default marker', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final result = deps.flow.buildDefaultContextType();
      expect(result, isA<OZContextRuleTypeDefault>());
    });

    test('buildCallContractContextType trims surrounding whitespace', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final result =
          deps.flow.buildCallContractContextType('   $fixtureContractId   ');
      expect(result, isA<OZContextRuleTypeCallContract>());
      expect(
        (result as OZContextRuleTypeCallContract).contractAddress,
        fixtureContractId,
      );
    });

    test('buildCreateContractContextType keeps the supplied WASM hash bytes',
        () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final hash = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final result = deps.flow.buildCreateContractContextType(hash);
      expect(result, isA<OZContextRuleTypeCreateContract>());
      expect(
        (result as OZContextRuleTypeCreateContract).wasmHash,
        equals(hash),
      );
    });
  });
}
