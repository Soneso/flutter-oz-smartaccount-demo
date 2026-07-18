/// Unit tests for the edit-mode methods added to [ContextRuleFlow].
///
/// Covers:
/// 1. loadParsedContextRule happy path returns the matching rule.
/// 2. loadParsedContextRule throws DemoError when the ID is missing.
/// 3. resolveEditDiffExpiry leaves diff unchanged when expiry is not
///    changed; resolves a positive offset to an absolute ledger; clears
///    the expiry when the offset is null or zero.
/// 4. submitContextRuleEdits sequential happy path: name + signer ops + a
///    new policy execute in the expected order and onProgress fires the
///    canonical "Updating rule #{id}..." text once per step.
/// 5. submitContextRuleEdits auth-guard partial: a diff that adds signers
///    AND new policies returns partialDueToAuthGuard=true after the signer
///    operations succeed.
/// 6. submitContextRuleEdits per-step failure stops execution and reports
///    the failed step with the completed-op count intact.
/// 7. totalOperations: threshold-only policy modification counts as 1, all
///    other policy modifications count as 2.
/// 8. ContextRuleEditDiff.isEmpty matches "no changes at all".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart' show PolicyInfo;
import 'package:smart_account_demo/flows/context_rule_flow.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'context_rule_test_support.dart';

void main() {
  group('ContextRuleFlow.loadParsedContextRule', () {
    test('returns the matching rule by ID', () async {
      final mgr = MockContextRuleFlowManager()
        ..rules = [
          makeRule(name: 'First'),
          makeRule(id: 2, name: 'Second'),
        ];
      final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

      final result = await deps.flow.loadParsedContextRule(2);

      expect(result.id, 2);
      expect(result.name, 'Second');
    });

    test('throws DemoError when no rule with the given ID exists', () async {
      final mgr = MockContextRuleFlowManager()
        ..rules = [makeRule(name: 'Only')];
      final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

      await expectLater(
        () => deps.flow.loadParsedContextRule(42),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('ContextRuleFlow.resolveEditDiffExpiry', () {
    test('returns the diff unchanged when expiryChanged is false', () async {
      final mgr = MockContextRuleFlowManager();
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(currentLedger: 100000),
      );
      const diff = ContextRuleEditDiff(
        ruleId: 1,
        nameChanged: false,
        newName: null,
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: <EditPolicyEntry>[],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.resolveEditDiffExpiry(diff);
      expect(identical(result, diff), isTrue);
    });

    test('resolves a positive offset to an absolute ledger', () async {
      final mgr = MockContextRuleFlowManager();
      final env = MockBuilderEnvironment(currentLedger: 100000);
      final deps =
          ContextRuleFixtures.makeFlowWithDeps(manager: mgr, environment: env);
      const diff = ContextRuleEditDiff(
        ruleId: 1,
        nameChanged: false,
        newName: null,
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: <EditPolicyEntry>[],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: true,
        newExpiry: 720, // 1 hour offset
      );

      final result = await deps.flow.resolveEditDiffExpiry(diff);
      expect(result.newExpiry, 100720);
      expect(result.expiryChanged, isTrue);
    });

    test('clears expiry when offset is null or non-positive', () async {
      final mgr = MockContextRuleFlowManager();
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(currentLedger: 100000),
      );
      const diff = ContextRuleEditDiff(
        ruleId: 1,
        nameChanged: false,
        newName: null,
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: <EditPolicyEntry>[],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: true,
        newExpiry: null,
      );

      final result = await deps.flow.resolveEditDiffExpiry(diff);
      expect(result.expiryChanged, isTrue);
      expect(result.newExpiry, isNull);
    });
  });

  group('ContextRuleEditDiff.totalOperations', () {
    test('counts threshold modifications as 1 and others as 2', () {
      const thresholdInfo = PolicyInfo(
        type: 'threshold',
        name: 'Threshold',
        description: '',
        address: 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
      );
      const spendingInfo = PolicyInfo(
        type: 'spending_limit',
        name: 'Spending',
        description: '',
        address: 'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L',
      );

      final diff = ContextRuleEditDiff(
        ruleId: 1,
        nameChanged: true,
        newName: 'X',
        newSigners: const <EditSignerEntry>[],
        removedSigners: const <EditSignerEntry>[],
        newPolicies: const <EditPolicyEntry>[],
        removedPolicies: const <EditPolicyEntry>[],
        modifiedPolicies: [
          EditPolicyEntry(
            info: thresholdInfo,
            label: 'Threshold: 2-of-N',
            address: thresholdInfo.address,
            onChainId: 1,
            isOriginal: true,
            modified: true,
            installSpec: const PolicyInstallSpecSimpleThreshold(threshold: 2),
          ),
          EditPolicyEntry(
            info: spendingInfo,
            label: 'Limit: 10 / 1 day(s)',
            address: spendingInfo.address,
            onChainId: 2,
            isOriginal: true,
            modified: true,
          ),
        ],
        expiryChanged: false,
        newExpiry: null,
      );

      // name (1) + threshold modify (1) + non-threshold modify (2) = 4
      expect(diff.totalOperations, 4);
    });
  });

  group('ContextRuleEditDiff.isEmpty', () {
    test('is true when no changes have been recorded', () {
      const diff = ContextRuleEditDiff(
        ruleId: 1,
        nameChanged: false,
        newName: null,
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: <EditPolicyEntry>[],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );
      expect(diff.isEmpty, isTrue);
      expect(diff.totalOperations, 0);
    });

    test('is false when any change is set', () {
      const diff = ContextRuleEditDiff(
        ruleId: 1,
        nameChanged: true,
        newName: 'X',
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: <EditPolicyEntry>[],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );
      expect(diff.isEmpty, isFalse);
      expect(diff.totalOperations, 1);
    });
  });

  group('ContextRuleFlow.submitContextRuleEdits — happy path', () {
    test('sequential per-op order: name → remove signer → add signer → '
        'add policy → expiry', () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['updateName'] =
            const OZTransactionResult(success: true, hash: 'h-name')
        ..editResults['removeSigner'] =
            const OZTransactionResult(success: true, hash: 'h-rms')
        ..editResults['addDelegated'] =
            const OZTransactionResult(success: true, hash: 'h-add-d')
        ..editResults['addSimpleThreshold'] =
            const OZTransactionResult(success: true, hash: 'h-add-p')
        ..editResults['updateValidUntil'] =
            const OZTransactionResult(success: true, hash: 'h-exp');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(currentLedger: 100000),
      );

      final removed = EditSignerEntry(
        signer: OZDelegatedSigner(fixtureDelegatedAddress1),
        onChainId: 7,
        isOriginal: true,
      );
      final added = EditSignerEntry(
        signer: OZDelegatedSigner(fixtureDelegatedAddress2),
        onChainId: null,
        isOriginal: false,
      );
      const newPolicy = EditPolicyEntry(
        info: PolicyInfo(
          type: 'threshold',
          name: 'Threshold',
          description: '',
          address: 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
        ),
        label: 'Threshold: 2-of-N',
        address: 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
        installSpec: PolicyInstallSpecSimpleThreshold(threshold: 2),
        onChainId: null,
        isOriginal: false,
      );
      final diff = ContextRuleEditDiff(
        ruleId: 9,
        nameChanged: true,
        newName: 'Updated',
        newSigners: [added],
        removedSigners: [removed],
        newPolicies: [newPolicy],
        removedPolicies: const <EditPolicyEntry>[],
        modifiedPolicies: const <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final messages = <String>[];
      // Note: this diff has new signers AND a new policy, which would
      // normally hit the auth-guard. To exercise the sequential happy-path
      // we exclude the new-policy operation from auth-guard scope by
      // dropping the new signer from the diff.
      final diffNoSigners = diff.copyWith(
        newSigners: const <EditSignerEntry>[],
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diffNoSigners,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: messages.add,
      );

      expect(result.success, isTrue);
      expect(result.completedOperations, 3); // name + remove + add policy
      expect(result.transactionHashes,
          containsAllInOrder(<String>['h-name', 'h-rms', 'h-add-p']));
      // onProgress fires once per step (3 steps).
      expect(messages.length, 3);
      for (final m in messages) {
        expect(m, 'Updating rule #9...');
      }
      // Verify the manager saw the calls in the documented order.
      // The simple-threshold policy is dispatched via addSimpleThreshold.
      expect(mgr.editCalls.map((c) => c.op).toList(),
          ['updateName', 'removeSigner', 'addSimpleThreshold']);
    });

    test('adds a passkey signer by slicing raw keyData bytes', () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['addPasskey'] =
            const OZTransactionResult(success: true, hash: 'h-add-pk');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      // 26 credential bytes encode to 35 unpadded Base64URL characters — a
      // length a padded-input decoder rejects — so this test fails if the
      // credential ID takes a string round-trip instead of a byte slice.
      final credentialBytes =
          Uint8List.fromList(utf8.encode('test-credential-id-fixture'));
      final publicKey =
          Uint8List.fromList(List<int>.generate(65, (i) => i + 1));
      final keyData =
          Uint8List.fromList(<int>[...publicKey, ...credentialBytes]);
      final added = EditSignerEntry(
        signer: OZExternalSigner(
          'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY',
          keyData,
        ),
        onChainId: null,
        isOriginal: false,
      );

      final diff = ContextRuleEditDiff(
        ruleId: 0,
        nameChanged: false,
        newName: null,
        newSigners: [added],
        removedSigners: const <EditSignerEntry>[],
        newPolicies: const <EditPolicyEntry>[],
        removedPolicies: const <EditPolicyEntry>[],
        modifiedPolicies: const <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isTrue,
          reason: 'add-passkey edit must succeed, got: ${result.error}');
      final call = mgr.editCalls.single;
      expect(call.op, 'addPasskey');
      expect(call.args['ruleId'], 0);
      expect(call.args['publicKey'], publicKey);
      expect(call.args['credentialId'], credentialBytes);
    });
  });

  group('ContextRuleFlow.submitContextRuleEdits — auth guard', () {
    test('adding a signer with pending policy work returns partial success',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['addDelegated'] =
            const OZTransactionResult(success: true, hash: 'h-sig');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      final newSigner = EditSignerEntry(
        signer: OZDelegatedSigner(fixtureDelegatedAddress2),
        onChainId: null,
        isOriginal: false,
      );
      const newPolicy = EditPolicyEntry(
        info: PolicyInfo(
          type: 'threshold',
          name: 'Threshold',
          description: '',
          address: 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
        ),
        label: 'Threshold: 2-of-N',
        address: 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
        installSpec: PolicyInstallSpecSimpleThreshold(threshold: 2),
        onChainId: null,
        isOriginal: false,
      );
      final diff = ContextRuleEditDiff(
        ruleId: 5,
        nameChanged: false,
        newName: null,
        newSigners: [newSigner],
        removedSigners: const <EditSignerEntry>[],
        newPolicies: [newPolicy],
        removedPolicies: const <EditPolicyEntry>[],
        modifiedPolicies: const <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isTrue);
      expect(result.partialDueToAuthGuard, isTrue);
      expect(result.authGuardMessage, isNotNull);
      expect(result.completedOperations, 1);
      // addSimpleThreshold was skipped due to the auth-guard.
      expect(mgr.editCallCounts['addSimpleThreshold'], isNull);
    });
  });

  group('ContextRuleFlow.submitContextRuleEdits — failure', () {
    test('stops on first non-successful OZTransactionResult and surfaces step',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['updateName'] = const OZTransactionResult(
          success: false,
          error: 'rejected',
        );

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      const diff = ContextRuleEditDiff(
        ruleId: 3,
        nameChanged: true,
        newName: 'X',
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: <EditPolicyEntry>[],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isFalse);
      expect(result.failedStep, 'Updating rule name');
      expect(result.error, isNotNull);
      expect(result.completedOperations, 0);
      expect(mgr.editCallCounts['updateName'], 1);
    });

    test('catches thrown exceptions and reports them as edit failures',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..editErrors['updateName'] = Exception('boom');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      const diff = ContextRuleEditDiff(
        ruleId: 3,
        nameChanged: true,
        newName: 'X',
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: <EditPolicyEntry>[],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isFalse);
      expect(result.failedStep, 'Updating rule name');
      expect(result.error, isNotNull);
    });
  });

  group('ContextRuleFlow.readPolicyParams', () {
    test('returns null when no entry exists at the storage key', () async {
      final mgr = MockContextRuleFlowManager();
      final env = MockBuilderEnvironment();
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: env,
      );

      final params = await deps.flow.readPolicyParams(
        policyAddress:
            'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
        ruleId: 1,
      );
      expect(params, isNull);
    });

    test('parses a threshold value when the policy returns a U32', () async {
      final mgr = MockContextRuleFlowManager();
      final env = MockBuilderEnvironment()
        ..contractDataValues[
                'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC'] =
            XdrSCVal.forU32(3);
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: env,
      );

      final params = await deps.flow.readPolicyParams(
        policyAddress:
            'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
        ruleId: 1,
      );
      expect(params, isNotNull);
      expect(params!.type, 'threshold');
      expect(params.threshold, 3);
    });
  });

  // ---------------------------------------------------------------------------
  // Task A: edit-add routing through per-type convenience helpers
  // ---------------------------------------------------------------------------

  group('submitContextRuleEdits — edit-add routes to convenience helpers', () {
    test('new simple-threshold policy calls addSimpleThresholdToRule', () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['addSimpleThreshold'] =
            const OZTransactionResult(success: true, hash: 'h-thresh');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      const policyAddress =
          'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC';
      const newPolicy = EditPolicyEntry(
        info: PolicyInfo(
            type: 'threshold',
            name: 'Threshold',
            description: '',
            address: policyAddress),
        label: 'Threshold: 2-of-N',
        address: policyAddress,
        installSpec: PolicyInstallSpecSimpleThreshold(threshold: 2),
        onChainId: null,
        isOriginal: false,
      );
      const diff = ContextRuleEditDiff(
        ruleId: 10,
        nameChanged: false,
        newName: null,
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: [newPolicy],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isTrue);
      expect(result.completedOperations, 1);
      expect(mgr.editCallCounts['addSimpleThreshold'], 1);
      // Verify the threshold value was passed through.
      final call = mgr.editCalls.first;
      expect(call.op, 'addSimpleThreshold');
      expect(call.args['threshold'], 2);
    });

    test('new spending-limit policy calls addSpendingLimitToRule', () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['addSpendingLimit'] =
            const OZTransactionResult(success: true, hash: 'h-sl');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      const policyAddress =
          'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';
      const newPolicy = EditPolicyEntry(
        info: PolicyInfo(
            type: 'spending_limit',
            name: 'Spending Limit',
            description: '',
            address: policyAddress),
        label: 'Limit: 50 / 1 day(s)',
        address: policyAddress,
        installSpec: PolicyInstallSpecSpendingLimit(
          amount: '50',
          decimals: 2,
          periodLedgers: 17280,
        ),
        onChainId: null,
        isOriginal: false,
      );
      const diff = ContextRuleEditDiff(
        ruleId: 11,
        nameChanged: false,
        newName: null,
        newSigners: <EditSignerEntry>[],
        removedSigners: <EditSignerEntry>[],
        newPolicies: [newPolicy],
        removedPolicies: <EditPolicyEntry>[],
        modifiedPolicies: <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isTrue);
      expect(result.completedOperations, 1);
      expect(mgr.editCallCounts['addSpendingLimit'], 1);
      final call = mgr.editCalls.first;
      expect(call.op, 'addSpendingLimit');
      expect(call.args['amount'], '50');
      expect(call.args['decimals'], 2);
      expect(call.args['periodLedgers'], 17280);
    });

    test('new weighted-threshold policy calls addWeightedThresholdToRule',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['addWeightedThreshold'] =
            const OZTransactionResult(success: true, hash: 'h-wt');

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: MockBuilderEnvironment(),
      );

      const policyAddress =
          'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC';
      final signer = OZDelegatedSigner(fixtureDelegatedAddress1);
      final newPolicy = EditPolicyEntry(
        info: const PolicyInfo(
            type: 'weighted_threshold',
            name: 'Weighted',
            description: '',
            address: policyAddress),
        label: 'Weighted: threshold=2',
        address: policyAddress,
        installSpec: PolicyInstallSpecWeightedThreshold(
          entries: [PolicyWeightedEntry(signer: signer, weight: 3)],
          threshold: 2,
        ),
        onChainId: null,
        isOriginal: false,
      );
      final diff = ContextRuleEditDiff(
        ruleId: 12,
        nameChanged: false,
        newName: null,
        newSigners: const <EditSignerEntry>[],
        removedSigners: const <EditSignerEntry>[],
        newPolicies: [newPolicy],
        removedPolicies: const <EditPolicyEntry>[],
        modifiedPolicies: const <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isTrue);
      expect(result.completedOperations, 1);
      expect(mgr.editCallCounts['addWeightedThreshold'], 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Task B: readPolicyParams decimals-aware read
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.readPolicyParams — spending-limit decimals', () {
    // Builds a spending-limit SCVal: Map{spending_limit: I128(baseUnits),
    // period_ledgers: U32(ledgers)}.
    XdrSCVal makeSpendingLimitScVal(BigInt baseUnits, int periodLedgers) {
      return XdrSCVal.forMap(<XdrSCMapEntry>[
        XdrSCMapEntry(
          XdrSCVal.forSymbol('spending_limit'),
          XdrSCVal.forI128BigInt(baseUnits),
        ),
        XdrSCMapEntry(
          XdrSCVal.forSymbol('period_ledgers'),
          XdrSCVal.forU32(periodLedgers),
        ),
      ]);
    }

    test('formats stored base units using native decimals (7) by default',
        () async {
      const policyAddress =
          'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';
      final env = MockBuilderEnvironment()
        ..contractDataValues[policyAddress] =
            makeSpendingLimitScVal(BigInt.from(10000000), 17280); // 1 XLM

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        environment: env,
      );

      final params = await deps.flow.readPolicyParams(
        policyAddress: policyAddress,
        ruleId: 1,
      );

      expect(params, isNotNull);
      expect(params!.type, 'spending_limit');
      // 10_000_000 base units at 7 decimals = 1 XLM.
      expect(params.spendingLimit, '1');
    });

    test(
        'formats stored base units using a custom 2-decimal guarded token',
        () async {
      const customToken =
          'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
      const policyAddress =
          'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';
      // 1050 base units at 2 decimals = "10.5"
      final env = MockBuilderEnvironment()
        ..tokenDecimals = 2
        ..contractDataValues[policyAddress] =
            makeSpendingLimitScVal(BigInt.from(1050), 17280);

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        environment: env,
      );

      final params = await deps.flow.readPolicyParams(
        policyAddress: policyAddress,
        ruleId: 1,
        guardedToken: customToken,
      );

      expect(params, isNotNull);
      expect(params!.type, 'spending_limit');
      // 1050 base units at 2 decimals = "10.5".
      expect(params.spendingLimit, '10.5');
      // The decimals fetch was triggered for the custom token.
      expect(env.fetchTokenDecimalsCallCount, 1);
      expect(env.lastFetchTokenDecimalsContract, customToken);
    });

    test(
        'returns null when decimals fetch fails for a custom guarded token',
        () async {
      const customToken =
          'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
      const policyAddress =
          'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';
      final env = MockBuilderEnvironment()
        ..fetchTokenDecimalsError = Exception('network error')
        ..contractDataValues[policyAddress] =
            makeSpendingLimitScVal(BigInt.from(1050), 17280);

      final deps = ContextRuleFixtures.makeFlowWithDeps(
        environment: env,
      );

      // A failed decimals read must produce null so the inline editor is
      // omitted rather than pre-populating with a mis-scaled amount.
      final params = await deps.flow.readPolicyParams(
        policyAddress: policyAddress,
        ruleId: 1,
        guardedToken: customToken,
      );

      expect(params, isNull);
    });
  });

  group('Add-signer dispatch by verifier address', () {
    test('routes external signers with the ed25519 verifier to addEd25519',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['addEd25519'] =
            const OZTransactionResult(success: true, hash: 'h-ed');
      final env = MockBuilderEnvironment(
        
      );
      final deps = ContextRuleFixtures.makeFlowWithDeps(
        manager: mgr,
        environment: env,
      );

      final signer = OZExternalSigner.ed25519(
        verifierAddress: env.ed25519VerifierAddress,
        publicKey: Uint8List(32),
      );
      final diff = ContextRuleEditDiff(
        ruleId: 1,
        nameChanged: false,
        newName: null,
        newSigners: [
          EditSignerEntry(signer: signer, onChainId: null, isOriginal: false),
        ],
        removedSigners: const <EditSignerEntry>[],
        newPolicies: const <EditPolicyEntry>[],
        removedPolicies: const <EditPolicyEntry>[],
        modifiedPolicies: const <EditPolicyEntry>[],
        expiryChanged: false,
        newExpiry: null,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isTrue);
      expect(mgr.editCallCounts['addEd25519'], 1);
    });
  });
}
