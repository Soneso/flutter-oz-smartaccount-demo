/// Tests for [AccountSignersFlow].
///
/// Covers:
/// - Happy path: rules → deduplicated signer entries with rule memberships.
/// - Dedup preserves insertion order across rules.
/// - Empty rule list returns an empty result and logs `0 unique signer(s)`.
/// - Not-connected branch short-circuits without an SDK call.
/// - Failure path classifies and logs the error, then rethrows.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'account_signers_test_support.dart';
import 'transfer_test_support.dart' show MockNetworkError;

// ---------------------------------------------------------------------------
// Local rule fixture helper
// ---------------------------------------------------------------------------

/// Builds a [ParsedContextRule] for the signer-dedup tests.
///
/// Lets each test specify signers, name, and context type without depending
/// on the broader builder fixture set used elsewhere in the suite.
ParsedContextRule makeRule({
  required int id,
  required String name,
  required List<OZSmartAccountSigner> signers,
  ContextRuleType? contextType,
}) {
  return ParsedContextRule(
    id: id,
    contextType: contextType ?? const ContextRuleTypeDefault(),
    name: name,
    signers: signers,
    signerIds: List<int>.generate(signers.length, (i) => i + 1),
    policies: const [],
    policyIds: const [],
  );
}

void main() {
  // -------------------------------------------------------------------------
  // Scenario 1 — happy path with dedup across rules
  // -------------------------------------------------------------------------

  group('AccountSignersFlow.loadAccountSigners — happy path', () {
    test(
      '3 signer occurrences across 2 rules dedupe to 2 unique entries',
      () async {
        final deps = AccountSignersFixtures.makeFlowWithDeps();
        deps.contextRuleManager.rules = <ParsedContextRule>[
          makeRule(
            id: 1,
            name: 'rule-1',
            signers: [
              OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1),
              OZDelegatedSigner(AccountSignersFixtures.delegatedAddress2),
            ],
          ),
          makeRule(
            id: 2,
            name: 'rule-2',
            signers: [
              OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1),
            ],
          ),
        ];

        final entries = await deps.flow.loadAccountSigners();

        expect(entries.length, 2);
        final firstSigner = entries[0].signer as OZDelegatedSigner;
        expect(firstSigner.address, AccountSignersFixtures.delegatedAddress1);
        // The first delegate appears in both rules → 2 memberships.
        expect(entries[0].contextRules.length, 2);
        expect(entries[0].contextRules.map((r) => r.id), [1, 2]);

        final secondSigner = entries[1].signer as OZDelegatedSigner;
        expect(secondSigner.address, AccountSignersFixtures.delegatedAddress2);
        // The second delegate is only in rule 1 → 1 membership.
        expect(entries[1].contextRules.length, 1);
        expect(entries[1].contextRules.single.id, 1);
      },
    );

    test('preserves insertion order across rules', () async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = <ParsedContextRule>[
        makeRule(
          id: 1,
          name: 'r1',
          signers: [
            OZDelegatedSigner(AccountSignersFixtures.delegatedAddress2),
          ],
        ),
        makeRule(
          id: 2,
          name: 'r2',
          signers: [
            OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1),
            OZDelegatedSigner(AccountSignersFixtures.delegatedAddress2),
          ],
        ),
      ];

      final entries = await deps.flow.loadAccountSigners();

      // Address 2 appeared first → it is the first entry.
      expect(
        (entries[0].signer as OZDelegatedSigner).address,
        AccountSignersFixtures.delegatedAddress2,
      );
      expect(
        (entries[1].signer as OZDelegatedSigner).address,
        AccountSignersFixtures.delegatedAddress1,
      );
    });

    test('logs the unique / total counts at info level', () async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = <ParsedContextRule>[
        makeRule(
          id: 1,
          name: 'r1',
          signers: [
            OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1),
            OZDelegatedSigner(AccountSignersFixtures.delegatedAddress2),
          ],
        ),
        makeRule(
          id: 2,
          name: 'r2',
          signers: [
            OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1),
          ],
        ),
      ];

      await deps.flow.loadAccountSigners();

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.info &&
              e.message.contains('Loaded 2 unique signer(s) from 2 context'),
        ),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 2 — empty rule list
  // -------------------------------------------------------------------------

  group('AccountSignersFlow.loadAccountSigners — empty rules', () {
    test('returns empty list and logs zero / zero', () async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = const <ParsedContextRule>[];

      final entries = await deps.flow.loadAccountSigners();

      expect(entries, isEmpty);
      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.info &&
              e.message.contains('Loaded 0 unique signer(s) from 0 context'),
        ),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 3 — not connected branch
  // -------------------------------------------------------------------------

  group('AccountSignersFlow.loadAccountSigners — not connected', () {
    test('returns empty list without calling the SDK', () async {
      final deps = AccountSignersFixtures.makeFlowWithDeps(isConnected: false);

      final entries = await deps.flow.loadAccountSigners();

      expect(entries, isEmpty);
      expect(deps.contextRuleManager.callCount, 0);
      // No log entries emitted.
      expect(deps.logEntries, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 4 — load failure
  // -------------------------------------------------------------------------

  group('AccountSignersFlow.loadAccountSigners — failure path', () {
    test('rethrows and logs a sanitised error at error level', () async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.error = MockNetworkError();

      await expectLater(
        deps.flow.loadAccountSigners(),
        throwsA(isA<MockNetworkError>()),
      );

      final log = deps.logEntries;
      expect(
        log.any(
          (e) =>
              e.level == LogLevel.error &&
              e.message.contains('Failed to load signers:'),
        ),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 5 — Ed25519 + delegated mixed
  // -------------------------------------------------------------------------

  group('AccountSignersFlow.loadAccountSigners — mixed signer types', () {
    test('keeps signer instances reachable on each entry', () async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      final ed25519 = OZExternalSigner.ed25519(
        verifierAddress: 'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6',
        publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final delegated =
          OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1);

      deps.contextRuleManager.rules = <ParsedContextRule>[
        makeRule(id: 1, name: 'mixed', signers: [ed25519, delegated]),
      ];

      final entries = await deps.flow.loadAccountSigners();

      expect(entries.length, 2);
      expect(entries[0].signer, isA<OZExternalSigner>());
      expect(entries[1].signer, isA<OZDelegatedSigner>());
    });
  });
}
