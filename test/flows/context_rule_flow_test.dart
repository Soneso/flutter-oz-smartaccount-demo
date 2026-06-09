/// Unit tests for [ContextRuleFlow].
///
/// Covers the 9 functional scenarios for the context-rules screen:
/// 1. List happy path
/// 2. View expanded details (flow level: signer extraction)
/// 3. Remove with >= 2 rules
/// 4. Remove last rule blocked
/// 5. Multi-signer removal path
/// 6. Parser malformed SCVal fallback
/// 7. Passkey auth cancelled
/// 8. Hard error handling
/// 9. Not connected state
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart' show PolicyInfo;
import 'package:smart_account_demo/flows/context_rule_edit_types.dart'
    show
        PolicyInstallSpec,
        PolicyInstallSpecSpendingLimit,
        PolicyWeightedEntry;
import 'package:smart_account_demo/flows/context_rule_flow.dart';
import 'package:smart_account_demo/flows/signer_info.dart' show SignerKind;
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/util/error_utils.dart'
    show DemoError, DemoErrorCategory;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'context_rule_test_support.dart';

// ---------------------------------------------------------------------------
// _makeFlowWithCustomManager — builds a [ContextRuleFlow] backed by an
// arbitrary [ContextRuleFlowManagerType] implementation (not constrained to
// the concrete [MockContextRuleFlowManager] subtype that
// [ContextRuleFixtures.makeFlowWithDeps] requires).
// ---------------------------------------------------------------------------

ContextRuleFlow _makeFlowWithCustomManager(
  ContextRuleFlowManagerType manager,
) {
  final container = ProviderContainer();
  addTearDown(container.dispose);

  final demoState = container.read(demoStateProvider.notifier);
  final activityLog = container.read(activityLogProvider.notifier);
  demoState.setConnected(
    contractId: fixtureContractId,
    credentialId: fixtureCredentialId,
    isDeployed: true,
  );

  return ContextRuleFlow(
    demoState: demoState,
    activityLog: activityLog,
    contextRuleManager: manager,
  );
}

// ---------------------------------------------------------------------------
// Shared fixtures for the submitContextRuleEdits failure-mode tests.
// ---------------------------------------------------------------------------

const String _thresholdPolicyAddress =
    'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC';

const String _spendingPolicyAddress =
    'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';

const PolicyInfo _thresholdInfo = PolicyInfo(
  type: 'threshold',
  name: 'Threshold',
  description: '',
  address: _thresholdPolicyAddress,
);

const PolicyInfo _spendingInfo = PolicyInfo(
  type: 'spending_limit',
  name: 'Spending',
  description: '',
  address: _spendingPolicyAddress,
);

EditPolicyEntry _thresholdPolicyEntry({
  required int? onChainId,
  PolicyInstallSpec? installSpec,
  bool modified = false,
  bool isOriginal = true,
}) {
  return EditPolicyEntry(
    info: _thresholdInfo,
    label: 'Threshold: 2-of-N',
    address: _thresholdPolicyAddress,
    onChainId: onChainId,
    isOriginal: isOriginal,
    installSpec: installSpec,
    modified: modified,
  );
}

EditPolicyEntry _spendingPolicyEntry({
  required int? onChainId,
  PolicyInstallSpec? installSpec,
  bool modified = true,
  bool isOriginal = true,
}) {
  return EditPolicyEntry(
    info: _spendingInfo,
    label: 'Limit: 10 / 1 day(s)',
    address: _spendingPolicyAddress,
    onChainId: onChainId,
    isOriginal: isOriginal,
    installSpec: installSpec,
    modified: modified,
  );
}

ContextRuleEditDiff _emptyDiff({int ruleId = 1}) => ContextRuleEditDiff(
      ruleId: ruleId,
      nameChanged: false,
      newName: null,
      newSigners: const <EditSignerEntry>[],
      removedSigners: const <EditSignerEntry>[],
      newPolicies: const <EditPolicyEntry>[],
      removedPolicies: const <EditPolicyEntry>[],
      modifiedPolicies: const <EditPolicyEntry>[],
      expiryChanged: false,
      newExpiry: null,
    );

ContextRuleFlow _makeFlowForCleanupTests() {
  final container = ProviderContainer();
  addTearDown(container.dispose);

  final demoState = container.read(demoStateProvider.notifier);
  final activityLog = container.read(activityLogProvider.notifier);
  demoState.setConnected(
    contractId: fixtureContractId,
    credentialId: fixtureCredentialId,
    isDeployed: true,
  );
  // No kit is wired in unit-test mode — externalSigners returns null and
  // all registration/cleanup methods no-op. These tests verify body execution
  // and exception propagation, which are independent of the manager.

  return ContextRuleFlow(
    demoState: demoState,
    activityLog: activityLog,
    contextRuleManager: MockContextRuleFlowManager(),
  );
}

void main() {
  // ---------------------------------------------------------------------------
  // Scenario 1: List happy path
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.listContextRules — happy path', () {
    test('returns 3 rules sorted by ID', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.rules = [
        makeRule(id: 3, name: 'c'),
        makeRule(id: 1, name: 'a'),
        makeRule(id: 2, name: 'b'),
      ];

      final rules = await deps.flow.listContextRules();

      expect(rules.length, 3);
      expect(rules.map((r) => r.id).toList(), [1, 2, 3]);
    });

    test('logs info and success messages', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.rules = [makeRule()];

      await deps.flow.listContextRules();

      final entries = deps.logEntries;
      expect(
        entries.any((e) => e.message.contains('Loading context rules')),
        isTrue,
      );
      expect(
        entries.any(
          (e) =>
              e.level == LogLevel.success &&
              e.message.contains('1 context rule(s) loaded'),
        ),
        isTrue,
      );
    });

    test('calls manager exactly once', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.rules = [makeRule()];

      await deps.flow.listContextRules();

      expect(deps.manager.listCallCount, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 2: Signer extraction (expanded detail)
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.loadAvailableSigners', () {
    test('extracts delegated signers from rules', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.rules = [
        makeRule(
          id: 1,
          signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        ),
        makeRule(
          id: 2,
          signers: [OZDelegatedSigner(fixtureDelegatedAddress2)],
        ),
      ];

      final result = await deps.flow.loadAvailableSigners();

      expect(result.isSuccess, isTrue);
      expect(result.signers.length, 2);
      expect(
        result.signers.every((s) => s.kind == SignerKind.delegated),
        isTrue,
      );
    });

    test('deduplicates signers appearing in multiple rules', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.rules = [
        makeRule(
          id: 1,
          signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        ),
        makeRule(
          id: 2,
          signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
        ),
      ];

      final result = await deps.flow.loadAvailableSigners();

      expect(result.isSuccess, isTrue);
      expect(result.signers.length, 1);
    });

    test('returns empty success when not connected', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps(isConnected: false);

      final result = await deps.flow.loadAvailableSigners();

      expect(result.isSuccess, isTrue);
      expect(result.signers, isEmpty);
    });

    test('returns failure result on manager error', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.listError = MockNetworkError();

      final result = await deps.flow.loadAvailableSigners();

      expect(result.isSuccess, isFalse);
      expect(result.signers, isEmpty);
      expect(result.error, isNotNull);
      expect(result.error!.message, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 3: Remove with >= 2 rules
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.removeContextRule — success', () {
    test('calls manager.removeContextRule with correct id', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = successResult();

      await deps.flow.removeContextRule(ruleId: 5);

      expect(deps.manager.removeCallCount, 1);
      expect(deps.manager.lastRemovedId, 5);
    });

    test('logs success message with truncated hash', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = successResult(hash: 'aabbcc' * 10);

      await deps.flow.removeContextRule(ruleId: 1);

      expect(
        deps.logEntries.any(
          (e) =>
              e.level == LogLevel.success &&
              e.message.contains('Context rule removed'),
        ),
        isTrue,
      );
    });

    test('passes selectedSigners to manager', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = successResult();
      final selectedSigners = [
        OZSelectedSignerWallet(fixtureDelegatedAddress1),
      ];

      await deps.flow.removeContextRule(
        ruleId: 2,
        selectedSigners: selectedSigners,
      );

      expect(
        deps.manager.lastSelectedSigners,
        equals(selectedSigners),
      );
    });

    test('throws DemoError when result.success is false', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = failureResult();

      expect(
        () => deps.flow.removeContextRule(ruleId: 1),
        throwsA(isA<DemoError>()),
      );
    });

    test(
        'surfaces raw SDK error verbatim: DemoError.message preserves '
        'the simulation re-error and event log detail', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      const rawError =
          'Soroban host error: Storage(MissingValue) at frame 12 — raw xdr blob';
      deps.manager.removeResult = failureResult(errorMessage: rawError);

      DemoError? caught;
      try {
        await deps.flow.removeContextRule(ruleId: 1);
      } on DemoError catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      expect(caught!.message, rawError);
      expect(caught.category, DemoErrorCategory.onChain);
      expect(caught.cause, rawError);
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 4: Remove last rule blocked (flow-level guard)
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow — last rule safety', () {
    test('isSinglePasskeyRemoval returns true for single passkey', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final singlePasskey = [const OZSelectedSignerPasskey()];

      expect(deps.flow.isSinglePasskeyRemoval(singlePasskey), isTrue);
    });

    test('isSinglePasskeyRemoval returns false for multiple signers', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final multi = [
        const OZSelectedSignerPasskey(),
        OZSelectedSignerWallet(fixtureDelegatedAddress1),
      ];

      expect(deps.flow.isSinglePasskeyRemoval(multi), isFalse);
    });

    test('isSinglePasskeyRemoval returns false for wallet signer', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final walletOnly = [OZSelectedSignerWallet(fixtureDelegatedAddress1)];

      expect(deps.flow.isSinglePasskeyRemoval(walletOnly), isFalse);
    });

    test('removeContextRule rejects when currentRuleCount is 1', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = successResult();

      await expectLater(
        deps.flow.removeContextRule(ruleId: 1, currentRuleCount: 1),
        throwsA(isA<DemoError>().having(
          (e) => e.category,
          'category',
          DemoErrorCategory.validation,
        )),
      );
      expect(deps.manager.removeCallCount, 0,
          reason: 'flow must not call manager when guard trips');
    });

    test('removeContextRule rejects when currentRuleCount is 0', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = successResult();

      await expectLater(
        deps.flow.removeContextRule(ruleId: 1, currentRuleCount: 0),
        throwsA(isA<DemoError>()),
      );
      expect(deps.manager.removeCallCount, 0);
    });

    test('removeContextRule proceeds when currentRuleCount is null',
        () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = successResult();

      await deps.flow.removeContextRule(ruleId: 1);

      expect(deps.manager.removeCallCount, 1);
    });

    test('removeContextRule proceeds when currentRuleCount is 2', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.removeResult = successResult();

      await deps.flow.removeContextRule(ruleId: 1, currentRuleCount: 2);

      expect(deps.manager.removeCallCount, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 5: Multi-signer removal path
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow — multi-signer removal', () {
    test('buildSelectedSigners maps passkey signer correctly', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final selected = await deps.flow.buildSelectedSigners(
        [ContextRuleFixtures.connectedPasskeySigner()],
      );

      expect(selected.length, 1);
      expect(selected.first, isA<OZSelectedSignerPasskey>());
    });

    test('buildSelectedSigners maps delegated signer correctly', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final selected = await deps.flow.buildSelectedSigners(
        [ContextRuleFixtures.delegatedSigner()],
      );

      expect(selected.length, 1);
      expect(selected.first, isA<OZSelectedSignerWallet>());
      expect((selected.first as OZSelectedSignerWallet).address,
          fixtureDelegatedAddress1);
    });

    test('buildSelectedSigners handles mixed signers', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final selected = await deps.flow.buildSelectedSigners([
        ContextRuleFixtures.connectedPasskeySigner(),
        ContextRuleFixtures.delegatedSigner(),
      ]);

      expect(selected.length, 2);
      expect(selected[0], isA<OZSelectedSignerPasskey>());
      expect(selected[1], isA<OZSelectedSignerWallet>());
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 6: Malformed SCVal fallback (flow-level)
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.listContextRules — graceful on manager error', () {
    test('propagates manager exception to caller', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.listError = MockNetworkError();

      expect(
        () => deps.flow.listContextRules(),
        throwsA(isA<MockNetworkError>()),
      );
    });

    test(
        'loadAvailableSigners surfaces failure result on manager error',
        () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.manager.listError = MockNetworkError();

      final result = await deps.flow.loadAvailableSigners();

      expect(result.isSuccess, isFalse);
      expect(result.signers, isEmpty);
      expect(result.error, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 7: Passkey auth cancelled
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.classifyRemovalError — WebAuthnCancelled', () {
    test('returns "Passkey authentication cancelled"', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyRemovalError(makeCancelledError());

      expect(msg, 'Passkey authentication cancelled');
    });

    test('logs info level on cancellation', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.flow.classifyRemovalError(makeCancelledError());

      expect(
        deps.logEntries.any(
          (e) =>
              e.level == LogLevel.info &&
              e.message.contains('cancelled'),
        ),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 8: Hard error handling
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.classifyRemovalError — generic error', () {
    test('returns sanitised message for network error', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyRemovalError(MockNetworkError());

      expect(msg, isNotEmpty);
      expect(msg, contains('Removal failed'));
    });

    test('logs error level on generic failure', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      deps.flow.classifyRemovalError(MockRuleRemovalError());

      expect(
        deps.logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
      );
    });

    test('StateError from re-entrancy guard returns in-progress message', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final msg =
          deps.flow.classifyRemovalError(StateError('removal in progress'));

      expect(msg, contains('already in progress'));
    });
  });

  // ---------------------------------------------------------------------------
  // Scenario 9: Not connected state
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow — not connected', () {
    test('listContextRules returns empty list when not connected', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps(isConnected: false);

      final rules = await deps.flow.listContextRules();

      expect(rules, isEmpty);
    });

    test('does not call manager when not connected', () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps(isConnected: false);

      await deps.flow.listContextRules();

      expect(deps.manager.listCallCount, 0);
    });

    test('loadAvailableSigners returns empty success when not connected',
        () async {
      final deps = ContextRuleFixtures.makeFlowWithDeps(isConnected: false);

      final result = await deps.flow.loadAvailableSigners();

      expect(result.isSuccess, isTrue);
      expect(result.signers, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // validateDelegatedSecret
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.validateDelegatedSecret', () {
    test('returns error when seed is empty', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final err = deps.flow.validateDelegatedSecret(
        fixtureDelegatedAddress1,
        '',
      );

      expect(err, isNotNull);
      expect(err, contains('required'));
    });

    test('returns error for invalid format', () {
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final err = deps.flow.validateDelegatedSecret(
        fixtureDelegatedAddress1,
        'not-a-seed',
      );

      expect(err, isNotNull);
    });

    test('returns null for valid matching seed', () {
      final kp = KeyPair.random();
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final err = deps.flow.validateDelegatedSecret(
        kp.accountId,
        kp.secretSeed,
      );

      expect(err, isNull);
    });

    test('returns error when seed does not match address', () {
      final kp1 = KeyPair.random();
      final kp2 = KeyPair.random();
      final deps = ContextRuleFixtures.makeFlowWithDeps();
      final err = deps.flow.validateDelegatedSecret(
        kp1.accountId,
        kp2.secretSeed,
      );

      expect(err, isNotNull);
      expect(err, contains("does not match"));
    });
  });

  // ---------------------------------------------------------------------------
  // withCleanupOfDelegatedKeypairs
  // ---------------------------------------------------------------------------

  group('ContextRuleFlow.withCleanupOfDelegatedKeypairs', () {
    test('runs body and returns body result on success', () async {
      final flow = _makeFlowForCleanupTests();

      var bodyCalls = 0;
      final result = await flow.withCleanupOfDelegatedKeypairs<String>(() async {
        bodyCalls++;
        return 'ok';
      });

      expect(result, equals('ok'));
      expect(bodyCalls, equals(1));
    });

    test('propagates body exception', () async {
      final flow = _makeFlowForCleanupTests();

      var bodyCalls = 0;
      final bodyError = StateError('body failed');

      await expectLater(
        flow.withCleanupOfDelegatedKeypairs<void>(() async {
          bodyCalls++;
          throw bodyError;
        }),
        throwsA(same(bodyError)),
      );

      expect(bodyCalls, equals(1));
    });

    test('wrapper never invokes registration (no key material added)', () async {
      final flow = _makeFlowForCleanupTests();
      // withCleanupOfDelegatedKeypairs must not register any signers —
      // registration is the caller's responsibility.
      await flow.withCleanupOfDelegatedKeypairs<void>(() async {});
      // No assertion needed beyond not throwing; no signers were registered.
    });

    test('exactly one body call on success path', () async {
      final flow = _makeFlowForCleanupTests();
      var bodyCalls = 0;
      await flow.withCleanupOfDelegatedKeypairs<void>(() async {
        bodyCalls++;
      });
      expect(bodyCalls, equals(1));
    });

    test('exactly one body call on body-throws path', () async {
      final flow = _makeFlowForCleanupTests();
      var bodyCalls = 0;
      await expectLater(
        flow.withCleanupOfDelegatedKeypairs<void>(() async {
          bodyCalls++;
          throw StateError('x');
        }),
        throwsA(isA<StateError>()),
      );
      expect(bodyCalls, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Baseline tests for the submitContextRuleEdits orchestrator's failure
  // modes. These pin down the failure paths of the current implementation so
  // a future refactor of the per-step block cannot regress any one of them.
  // ---------------------------------------------------------------------------

  group('submitContextRuleEdits — failure modes', () {
    // -----------------------------------------------------------------------
    // Generic step behaviour
    // -----------------------------------------------------------------------

    test('step succeeds then next step runs; completed and hashes advance',
        () async {
      final mgr = MockContextRuleFlowManager()
        ..editResults['updateName'] =
            const OZTransactionResult(success: true, hash: 'h-name')
        ..editResults['updateValidUntil'] =
            const OZTransactionResult(success: true, hash: 'h-exp');
      final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

      final diff = _emptyDiff(ruleId: 9).copyWith(
        nameChanged: true,
        newName: 'Renamed',
        expiryChanged: true,
        newExpiry: 12345,
      );

      final result = await deps.flow.submitContextRuleEdits(
        diff: diff,
        selectedSigners: const <OZSelectedSigner>[],
        onProgress: (_) {},
      );

      expect(result.success, isTrue);
      expect(result.partialDueToAuthGuard, isFalse);
      expect(result.failedStep, isNull);
      expect(result.completedOperations, 2);
      expect(result.totalOperations, 2);
      expect(result.transactionHashes, <String>['h-name', 'h-exp']);
      expect(mgr.editCalls.map((c) => c.op).toList(),
          <String>['updateName', 'updateValidUntil']);
    });

    test(
      'step returns !success with error: failedStep is set, downstream '
      'steps are skipped, partialDueToAuthGuard is false',
      () async {
        final mgr = MockContextRuleFlowManager()
          ..editResults['updateName'] = const OZTransactionResult(
            success: true,
            hash: 'h-name',
          )
          ..editResults['removeSigner'] = const OZTransactionResult(
            success: false,
            error: 'rejected on chain',
          )
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never',
          );
        final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

        final removed = EditSignerEntry(
          signer: OZDelegatedSigner(fixtureDelegatedAddress1),
          onChainId: 7,
          isOriginal: true,
        );

        final diff = _emptyDiff(ruleId: 11).copyWith(
          nameChanged: true,
          newName: 'X',
          removedSigners: [removed],
          expiryChanged: true,
          newExpiry: 999,
        );

        final result = await deps.flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        expect(result.partialDueToAuthGuard, isFalse);
        expect(result.failedStep, 'Removing signer 1 of 1');
        expect(result.error, 'rejected on chain');
        // Only the first step (name) succeeded before the signer removal
        // failed; expiry was never attempted.
        expect(result.completedOperations, 1);
        expect(result.totalOperations, 3);
        expect(result.transactionHashes, <String>['h-name']);
        expect(mgr.editCallCounts['updateName'], 1);
        expect(mgr.editCallCounts['removeSigner'], 1);
        expect(mgr.editCallCounts['updateValidUntil'], isNull,
            reason: 'downstream step must be skipped after a step failure');
      },
    );

    test(
      'step throws: failure is wrapped with the right failedStep and '
      'downstream steps are skipped',
      () async {
        final thrown = Exception('boom from manager');
        final mgr = MockContextRuleFlowManager()
          ..editResults['updateName'] = const OZTransactionResult(
            success: true,
            hash: 'h-name',
          )
          ..editErrors['removeSigner'] = thrown
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never',
          );
        final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

        final removed = EditSignerEntry(
          signer: OZDelegatedSigner(fixtureDelegatedAddress1),
          onChainId: 12,
          isOriginal: true,
        );

        final diff = _emptyDiff(ruleId: 14).copyWith(
          nameChanged: true,
          newName: 'X',
          removedSigners: [removed],
          expiryChanged: true,
          newExpiry: 88888,
        );

        final result = await deps.flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        expect(result.partialDueToAuthGuard, isFalse);
        expect(result.failedStep, 'Removing signer 1 of 1');
        expect(result.error, isNotNull);
        expect(result.error, isNotEmpty);
        expect(result.completedOperations, 1);
        expect(result.totalOperations, 3);
        expect(result.transactionHashes, <String>['h-name']);
        expect(mgr.editCallCounts['updateValidUntil'], isNull,
            reason: 'downstream step must be skipped after a thrown step');
      },
    );

    // -----------------------------------------------------------------------
    // Loop iteration behaviour
    // -----------------------------------------------------------------------

    test(
      'loop step: item 1 succeeds and item 2 fails — completed and hashes '
      'reflect partial progress; failedStep names item 2',
      () async {
        // Drive two modified non-threshold policies in sequence. The first
        // iteration succeeds (remove + re-add). The second fails on its
        // remove. Each iteration produces two on-chain ops, totalling four.
        final mgr = _SequentialMockManager(
          removePolicyResults: const <OZTransactionResult>[
            OZTransactionResult(success: true, hash: 'h-rm-1'),
            OZTransactionResult(success: false, error: 'second remove failed'),
          ],
          addPolicyResults: const <OZTransactionResult>[
            OZTransactionResult(success: true, hash: 'h-add-1'),
          ],
        );
        final flow = _makeFlowWithCustomManager(mgr);

        final policy1 = _spendingPolicyEntry(
          onChainId: 100,
          installSpec: const PolicyInstallSpecSpendingLimit(
            amount: '10',
            decimals: 7,
            periodLedgers: 17280,
          ),
        );
        final policy2 = _spendingPolicyEntry(
          onChainId: 200,
          installSpec: const PolicyInstallSpecSpendingLimit(
            amount: '20',
            decimals: 7,
            periodLedgers: 17280,
          ),
        );

        final diff = _emptyDiff(ruleId: 21).copyWith(
          modifiedPolicies: [policy1, policy2],
        );

        // sanity: each modified non-threshold policy is 2 ops, total 4.
        expect(diff.totalOperations, 4);

        final result = await flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        expect(result.failedStep,
            'Updating policy 2 of 2 (remove)');
        expect(result.error, 'second remove failed');
        // Item 1: remove + re-add = 2 ops. Item 2: zero completed.
        expect(result.completedOperations, 2);
        expect(result.totalOperations, 4);
        expect(result.transactionHashes, <String>['h-rm-1', 'h-add-1']);
        expect(mgr.removePolicyCalls, 2);
        expect(mgr.addPolicyCalls, 1,
            reason: 're-add must not run on the failed iteration');
      },
    );

    // -----------------------------------------------------------------------
    // Pre-flight null checks: one per distinct precondition site.
    // -----------------------------------------------------------------------

    test(
      'remove-signer pre-flight: onChainId == null short-circuits the step',
      () async {
        final mgr = MockContextRuleFlowManager()
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never',
          );
        final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

        final orphan = EditSignerEntry(
          signer: OZDelegatedSigner(fixtureDelegatedAddress1),
          onChainId: null,
          isOriginal: true,
        );

        final diff = _emptyDiff(ruleId: 30).copyWith(
          removedSigners: [orphan],
          expiryChanged: true,
          newExpiry: 42,
        );

        final result = await deps.flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        expect(result.failedStep, 'Removing signer 1 of 1');
        expect(result.error, contains('on-chain ID'));
        expect(result.completedOperations, 0,
            reason: 'precondition must not advance completed');
        expect(result.totalOperations, 2);
        expect(result.transactionHashes, isEmpty,
            reason: 'precondition must not append a hash');
        expect(mgr.editCallCounts['removeSigner'], isNull,
            reason: 'precondition must not call the manager');
        expect(mgr.editCallCounts['updateValidUntil'], isNull,
            reason: 'downstream step must be skipped');
      },
    );

    test(
      'remove-policy pre-flight: onChainId == null short-circuits the step',
      () async {
        final mgr = MockContextRuleFlowManager()
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never',
          );
        final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

        final orphanPolicy = _thresholdPolicyEntry(
          onChainId: null,
          installSpec: null,
        );

        final diff = _emptyDiff(ruleId: 31).copyWith(
          removedPolicies: [orphanPolicy],
          expiryChanged: true,
          newExpiry: 55,
        );

        final result = await deps.flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        expect(result.failedStep, 'Removing policy 1 of 1');
        expect(result.error, contains('on-chain ID'));
        expect(result.completedOperations, 0);
        expect(result.totalOperations, 2);
        expect(result.transactionHashes, isEmpty);
        expect(mgr.editCallCounts['removePolicy'], isNull);
        expect(mgr.editCallCounts['updateValidUntil'], isNull);
      },
    );

    test(
      'add-policy pre-flight: installSpec == null short-circuits the step',
      () async {
        final mgr = MockContextRuleFlowManager()
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never',
          );
        final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

        final unpreparedPolicy = _thresholdPolicyEntry(
          onChainId: null,
          installSpec: null,
          isOriginal: false,
        );

        final diff = _emptyDiff(ruleId: 32).copyWith(
          newPolicies: [unpreparedPolicy],
          expiryChanged: true,
          newExpiry: 77,
        );

        final result = await deps.flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        expect(result.failedStep, 'Adding policy 1 of 1');
        expect(result.error, contains('install parameters'));
        expect(result.completedOperations, 0);
        expect(result.totalOperations, 2);
        expect(result.transactionHashes, isEmpty);
        expect(mgr.editCallCounts['addPolicy'], isNull);
        expect(mgr.editCallCounts['updateValidUntil'], isNull);
      },
    );

    test(
      'modified-threshold pre-flight: newThreshold == null short-circuits',
      () async {
        final mgr = MockContextRuleFlowManager()
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never',
          );
        final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

        // Threshold-type policy with null install params — the orchestrator
        // passes it to _extractThreshold which returns null for null input
        // and the precondition trips.
        final brokenThresholdPolicy = _thresholdPolicyEntry(
          onChainId: 500,
          installSpec: null,
          modified: true,
        );

        final diff = _emptyDiff(ruleId: 33).copyWith(
          modifiedPolicies: [brokenThresholdPolicy],
          expiryChanged: true,
          newExpiry: 90,
        );

        // Threshold policy counts as 1 op, plus 1 op for expiry = 2 total.
        expect(diff.totalOperations, 2);

        final result = await deps.flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        expect(result.failedStep, 'Updating policy 1 of 1');
        expect(result.error, contains('threshold'));
        expect(result.completedOperations, 0);
        expect(result.totalOperations, 2);
        expect(result.transactionHashes, isEmpty);
        expect(mgr.editCallCounts['setPolicyThreshold'], isNull);
        expect(mgr.editCallCounts['updateValidUntil'], isNull);
      },
    );

    test(
      'modified non-threshold dual pre-flight: onChainId == null short-'
      'circuits both remove and re-add for the iteration',
      () async {
        final mgr = MockContextRuleFlowManager()
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never',
          );
        final deps = ContextRuleFixtures.makeFlowWithDeps(manager: mgr);

        // Spending-limit policy is non-threshold; null onChainId trips the
        // first of the two pre-flight checks (the remove-step short-circuit).
        final brokenPolicy = _spendingPolicyEntry(
          onChainId: null,
          installSpec: const PolicyInstallSpecSpendingLimit(
            amount: '10',
            decimals: 7,
            periodLedgers: 17280,
          ),
        );

        final diff = _emptyDiff(ruleId: 41).copyWith(
          modifiedPolicies: [brokenPolicy],
          expiryChanged: true,
          newExpiry: 101,
        );

        // Non-threshold modified policy = 2 ops plus expiry 1 op = 3 total.
        expect(diff.totalOperations, 3);

        final result = await deps.flow.submitContextRuleEdits(
          diff: diff,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result.success, isFalse);
        // Current behaviour: the onChainId precondition trips and the failed
        // step is the remove half ("(remove)"). Both the remove and the
        // re-add must be skipped.
        expect(result.failedStep, 'Updating policy 1 of 1 (remove)');
        expect(result.error, contains('on-chain ID'));
        expect(result.completedOperations, 0,
            reason: 'neither remove nor re-add may advance completed');
        expect(result.totalOperations, 3);
        expect(result.transactionHashes, isEmpty,
            reason: 'no hash may be appended for either tx in the iteration');
        expect(mgr.editCallCounts['removePolicy'], isNull,
            reason: 'remove must not execute');
        expect(mgr.editCallCounts['addSpendingLimit'], isNull,
            reason: 're-add must be skipped when remove is skipped');
        expect(mgr.editCallCounts['updateValidUntil'], isNull,
            reason: 'downstream step must be skipped');

        // And again with the other pre-flight: installSpec == null while
        // onChainId is set. Current behaviour: the installSpec precondition
        // trips and the failed step is the re-add half ("(re-add)"). Both txs
        // are still skipped.
        final mgr2 = MockContextRuleFlowManager()
          ..editResults['updateValidUntil'] = const OZTransactionResult(
            success: true,
            hash: 'h-exp-never-2',
          );
        final deps2 = ContextRuleFixtures.makeFlowWithDeps(manager: mgr2);

        final brokenPolicy2 = _spendingPolicyEntry(
          onChainId: 700,
          installSpec: null,
        );

        final diff2 = _emptyDiff(ruleId: 42).copyWith(
          modifiedPolicies: [brokenPolicy2],
          expiryChanged: true,
          newExpiry: 102,
        );

        final result2 = await deps2.flow.submitContextRuleEdits(
          diff: diff2,
          selectedSigners: const <OZSelectedSigner>[],
          onProgress: (_) {},
        );

        expect(result2.success, isFalse);
        expect(result2.failedStep, 'Updating policy 1 of 1 (re-add)');
        expect(result2.error, contains('install parameters'));
        expect(result2.completedOperations, 0);
        expect(result2.totalOperations, 3);
        expect(result2.transactionHashes, isEmpty);
        expect(mgr2.editCallCounts['removePolicy'], isNull,
            reason: 'installSpec precondition must short-circuit remove too');
        expect(mgr2.editCallCounts['addSpendingLimit'], isNull);
        expect(mgr2.editCallCounts['updateValidUntil'], isNull);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// _SequentialMockManager — drives sequential per-call OZTransactionResult
// outcomes for removePolicy / addPolicy, used by the loop-iteration baseline
// test which needs a different result on each invocation of the same
// operation. Other methods throw [UnimplementedError] because the orchestrator
// does not call them in the loop-iteration test scenario.
// ---------------------------------------------------------------------------

final class _SequentialMockManager implements ContextRuleFlowManagerType {
  _SequentialMockManager({
    required this.removePolicyResults,
    required this.addPolicyResults,
  });

  final List<OZTransactionResult> removePolicyResults;
  final List<OZTransactionResult> addPolicyResults;

  int removePolicyCalls = 0;
  // Counts addSpendingLimitToRule calls (the dispatch path for spending-limit
  // PolicyInstallSpecSpendingLimit entries used in the loop-iteration tests).
  int addPolicyCalls = 0;

  Never _notUsed(String name) => throw UnimplementedError(
        '_SequentialMockManager.$name is not used in the loop-iteration '
        'baseline test.',
      );

  @override
  Future<List<OZParsedContextRule>> listContextRules() => _notUsed('listContextRules');

  @override
  Future<OZTransactionResult> removeContextRule({
    required int id,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('removeContextRule');

  @override
  Future<OZTransactionResult> addContextRule({
    required OZContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    Map<String, XdrSCVal> policies = const <String, XdrSCVal>{},
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('addContextRule');

  @override
  Future<OZTransactionResult> updateContextRuleName({
    required int ruleId,
    required String name,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('updateContextRuleName');

  @override
  Future<OZTransactionResult> removeSignerFromRule({
    required int ruleId,
    required int signerId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('removeSignerFromRule');

  @override
  Future<OZTransactionResult> addDelegatedSignerToRule({
    required int ruleId,
    required String address,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('addDelegatedSignerToRule');

  @override
  Future<OZTransactionResult> addEd25519SignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('addEd25519SignerToRule');

  @override
  Future<OZTransactionResult> addPasskeySignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    required Uint8List credentialId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('addPasskeySignerToRule');

  @override
  Future<OZTransactionResult> updateContextRuleValidUntil({
    required int ruleId,
    int? validUntil,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('updateContextRuleValidUntil');

  @override
  Future<OZTransactionResult> setPolicyThreshold({
    required int ruleId,
    required String policyAddress,
    required int newThreshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('setPolicyThreshold');

  @override
  Future<OZTransactionResult> removePolicyFromRule({
    required int ruleId,
    required int policyId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) async {
    final i = removePolicyCalls++;
    if (i >= removePolicyResults.length) {
      throw StateError(
        '_SequentialMockManager: removePolicyFromRule called more times '
        '(${i + 1}) than results were configured '
        '(${removePolicyResults.length}).',
      );
    }
    return removePolicyResults[i];
  }

  @override
  Future<OZTransactionResult> addSimpleThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('addSimpleThresholdToRule');

  @override
  Future<OZTransactionResult> addWeightedThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required List<PolicyWeightedEntry> entries,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _notUsed('addWeightedThresholdToRule');

  @override
  Future<OZTransactionResult> addSpendingLimitToRule({
    required int ruleId,
    required String policyAddress,
    required String amount,
    required int decimals,
    required int periodLedgers,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) async {
    final i = addPolicyCalls++;
    if (i >= addPolicyResults.length) {
      throw StateError(
        '_SequentialMockManager: addSpendingLimitToRule called more times '
        '(${i + 1}) than results were configured '
        '(${addPolicyResults.length}).',
      );
    }
    return addPolicyResults[i];
  }
}
