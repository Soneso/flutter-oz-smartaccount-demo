/// Widget tests for [RemoveContextRuleDialog].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/widgets/remove_context_rule_dialog.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/context_rule_test_support.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pumps the dialog directly inside a [MaterialApp] to simulate an overlay.
Future<void> _pumpDialog(
  WidgetTester tester, {
  required OZParsedContextRule rule,
  required bool canRemove,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () {
            showDialog<bool>(
              context: context,
              builder: (_) => RemoveContextRuleDialog(
                rule: rule,
                canRemove: canRemove,
              ),
            );
          },
          child: const Text('Open'),
        );
      }),
    ),
  ));

  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  group('RemoveContextRuleDialog — content', () {
    testWidgets('title is "Remove Context Rule"', (tester) async {
      final rule = makeRule(id: 1, name: 'my-rule');
      await _pumpDialog(tester, rule: rule, canRemove: true);

      expect(find.text('Remove Context Rule'), findsOneWidget);
    });

    testWidgets('message contains rule id and name', (tester) async {
      final rule = makeRule(id: 3, name: 'special-rule');
      await _pumpDialog(tester, rule: rule, canRemove: true);

      expect(find.textContaining('#3'), findsOneWidget);
      expect(find.textContaining('"special-rule"'), findsOneWidget);
    });

    testWidgets('message contains authorization warning', (tester) async {
      final rule = makeRule(id: 1, name: 'r');
      await _pumpDialog(tester, rule: rule, canRemove: true);

      expect(
        find.textContaining('smart account authorization'),
        findsOneWidget,
      );
    });

    testWidgets('message contains "cannot be undone"', (tester) async {
      final rule = makeRule(id: 1, name: 'r');
      await _pumpDialog(tester, rule: rule, canRemove: true);

      expect(find.textContaining('cannot be undone'), findsOneWidget);
    });

    testWidgets('shows "Unnamed Rule" for empty rule name', (tester) async {
      final rule = makeRule(id: 1, name: '');
      await _pumpDialog(tester, rule: rule, canRemove: true);

      expect(find.textContaining('"Unnamed Rule"'), findsOneWidget);
    });
  });

  group('RemoveContextRuleDialog — canRemove = true', () {
    testWidgets('shows enabled "Remove" button', (tester) async {
      final rule = makeRule(id: 1, name: 'r');
      await _pumpDialog(tester, rule: rule, canRemove: true);

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Remove'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('shows "Cancel" button', (tester) async {
      final rule = makeRule(id: 1, name: 'r');
      await _pumpDialog(tester, rule: rule, canRemove: true);

      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('tapping Cancel dismisses without returning true',
        (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await RemoveContextRuleDialog.show(
                  context: context,
                  rule: makeRule(id: 1, name: 'r'),
                  canRemove: true,
                );
              },
              child: const Text('Open'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('tapping Remove returns true', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await RemoveContextRuleDialog.show(
                  context: context,
                  rule: makeRule(id: 1, name: 'r'),
                  canRemove: true,
                );
              },
              child: const Text('Open'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });
  });

  group('RemoveContextRuleDialog — canRemove = false', () {
    testWidgets('shows disabled "Last Rule" button', (tester) async {
      final rule = makeRule(id: 1, name: 'r');
      await _pumpDialog(tester, rule: rule, canRemove: false);

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Last Rule'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('shows "Cancel" button', (tester) async {
      final rule = makeRule(id: 1, name: 'r');
      await _pumpDialog(tester, rule: rule, canRemove: false);

      expect(find.text('Cancel'), findsOneWidget);
    });
  });
}
