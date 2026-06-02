/// Widget tests for [ContextRuleCard].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/widgets/context_rule_card.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/context_rule_test_support.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));
}

void main() {
  group('ContextRuleCard — collapsed state', () {
    testWidgets('shows rule ID badge', (tester) async {
      final rule = makeRule(id: 7, name: 'my-rule');
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('#7'), findsOneWidget);
    });

    testWidgets('shows rule name', (tester) async {
      final rule = makeRule(id: 1, name: 'my-rule');
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('my-rule'), findsOneWidget);
    });

    testWidgets('shows "Unnamed Rule" for empty name', (tester) async {
      final rule = makeRule(id: 1, name: '');
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Unnamed Rule'), findsOneWidget);
    });

    testWidgets('shows context type badge', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Default (Any Operation)'), findsOneWidget);
    });

    testWidgets('shows signer count badge', (tester) async {
      final rule = makeRule(
        id: 1,
        signers: [
          OZDelegatedSigner(fixtureDelegatedAddress1),
          OZDelegatedSigner(fixtureDelegatedAddress2),
        ],
      );
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('2 signers'), findsOneWidget);
    });

    testWidgets('shows singular "1 signer"', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('1 signer'), findsOneWidget);
    });

    testWidgets('shows policy count badge', (tester) async {
      final rule = makePolicyOnlyRule(
        id: 1,
        policies: [fixtureContractId, fixtureContractId],
      );
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('2 policies'), findsOneWidget);
    });

    testWidgets('shows expiry badge when validUntil is set', (tester) async {
      final rule = makeRuleWithExpiry(id: 1, validUntil: 12345);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Expires: ledger 12345'), findsOneWidget);
    });

    testWidgets('does not show expiry badge when validUntil is null',
        (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.textContaining('Expires'), findsNothing);
    });

    testWidgets('shows "Remove Rule" button when canRemove is true',
        (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Remove Rule'), findsOneWidget);
    });

    testWidgets('shows "Last Rule" button when canRemove is false',
        (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: false,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Last Rule'), findsOneWidget);
    });

    testWidgets('"Last Rule" button is disabled', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: false,
        isRemoving: false,
        onRemove: () {},
      )));

      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Last Rule'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('onRemove called when Remove Rule tapped', (tester) async {
      var tapped = false;
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () => tapped = true,
      )));

      await tester.tap(find.text('Remove Rule'));
      await tester.pump();

      expect(tapped, isTrue);
    });
  });

  group('ContextRuleCard — expanded state', () {
    testWidgets('shows "Signers" section header when expanded', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: true,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Signers'), findsOneWidget);
    });

    testWidgets('shows "Policies" section header when expanded', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: true,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Policies'), findsOneWidget);
    });

    testWidgets('shows "No signers (policy-only rule)" when no signers',
        (tester) async {
      final rule = makePolicyOnlyRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: true,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('No signers (policy-only rule)'), findsOneWidget);
    });

    testWidgets('shows "No policies (signer-only rule)" when no policies',
        (tester) async {
      final rule = makeSignerOnlyRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: true,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('No policies (signer-only rule)'), findsOneWidget);
    });

    testWidgets('shows "G-Address" type badge for delegated signer',
        (tester) async {
      final rule = makeSignerOnlyRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: true,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('G-Address'), findsOneWidget);
    });

    testWidgets('shows "P" policy badge for policy entry', (tester) async {
      final rule = makePolicyOnlyRule(id: 1, policies: [fixtureContractId]);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: true,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('P'), findsOneWidget);
    });

    testWidgets('Signers section not shown when collapsed', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Signers'), findsNothing);
    });

    testWidgets('onToggleExpanded called when expand icon tapped',
        (tester) async {
      var toggled = false;
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () => toggled = true,
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();

      expect(toggled, isTrue);
    });
  });

  group('ContextRuleCard — removing state', () {
    testWidgets('shows spinner when isRemoving is true', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: true,
        onRemove: null,
      )));

      expect(find.text('Removing...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('ContextRuleCard — Edit Rule button', () {
    testWidgets('Edit Rule button hidden when onEdit is null', (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
      )));

      expect(find.text('Edit Rule'), findsNothing);
    });

    testWidgets('Edit Rule button visible when onEdit is non-null',
        (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
        onEdit: () {},
      )));

      expect(find.text('Edit Rule'), findsOneWidget);
    });

    testWidgets('onEdit invoked when Edit Rule tapped', (tester) async {
      var editTapped = false;
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: false,
        onRemove: () {},
        onEdit: () => editTapped = true,
      )));

      await tester.tap(find.text('Edit Rule'));
      await tester.pump();

      expect(editTapped, isTrue);
    });

    testWidgets('Edit Rule button disabled while isRemoving is true',
        (tester) async {
      final rule = makeRule(id: 1);
      await tester.pumpWidget(_wrap(ContextRuleCard(
        rule: rule,
        isExpanded: false,
        onToggleExpanded: () {},
        canRemove: true,
        isRemoving: true,
        onRemove: null,
        onEdit: () {},
      )));

      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Edit Rule'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}
