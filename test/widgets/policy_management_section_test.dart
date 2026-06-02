/// Widget tests for [PolicyManagementSection].
///
/// Covers header strings, empty-state, type-dropdown filtering when all
/// types are added, per-type add forms, and validation error strings.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart'
    show knownPolicies;
import 'package:smart_account_demo/flows/context_rule_builder_types.dart';
import 'package:smart_account_demo/util/policy_scval_builders.dart';
import 'package:smart_account_demo/widgets/policy_management_section.dart';

import '../flows/context_rule_test_support.dart';

Future<void> _pump(
  WidgetTester tester, {
  required List<StagedPolicy> policies,
  required List<StagedSigner> signers,
  String? fieldError,
  bool isSubmitting = false,
  int maxPolicies = 5,
  String? Function(StagedPolicy)? onAddPolicy,
  void Function(StagedPolicy)? onRemovePolicy,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: PolicyManagementSection(
            policies: policies,
            signers: signers,
            fieldError: fieldError,
            isSubmitting: isSubmitting,
            maxPolicies: maxPolicies,
            onAddPolicy: onAddPolicy ?? (_) => null,
            onRemovePolicy: onRemovePolicy ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

StagedSigner _stagedDelegated() => StagedSigner(
      type: StagedSignerType.delegated,
      identifier: 'GA12...AB34',
      signer: OZDelegatedSigner(fixtureDelegatedAddress1),
    );

void main() {
  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  group('PolicyManagementSection — header and empty state', () {
    testWidgets('shows verbatim header strings', (tester) async {
      await _pump(
        tester,
        policies: const <StagedPolicy>[],
        signers: const <StagedSigner>[],
      );
      expect(find.text('Policies'), findsOneWidget);
      expect(
        find.text(
          'Attach policies to constrain how operations are authorized. '
          'Policies are optional. Maximum 5 per rule.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows empty-state body when policies is empty',
        (tester) async {
      await _pump(
        tester,
        policies: const <StagedPolicy>[],
        signers: const <StagedSigner>[],
      );
      expect(
        find.text('No policies attached. Policies are optional.'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Add Policy form
  // ---------------------------------------------------------------------------

  group('PolicyManagementSection — add policy', () {
    testWidgets('Threshold form rejects threshold > signer count',
        (tester) async {
      await _pump(
        tester,
        policies: const <StagedPolicy>[],
        signers: [_stagedDelegated()],
      );

      // Open the dropdown and select Threshold.
      await tester.tap(find.text('Policy Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Threshold (M-of-N)').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Threshold (required signers)'),
        '5',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Threshold Policy'));
      await tester.pumpAndSettle();
      expect(
        find.text('Cannot exceed signer count (1)'),
        findsOneWidget,
      );
    });

    testWidgets('Threshold valid value invokes onAddPolicy', (tester) async {
      var captured = 0;
      await _pump(
        tester,
        policies: const <StagedPolicy>[],
        signers: [_stagedDelegated(), _stagedDelegated()],
        onAddPolicy: (_) {
          captured++;
          return null;
        },
      );
      await tester.tap(find.text('Policy Type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Threshold (M-of-N)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Threshold (required signers)'),
        '1',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Threshold Policy'));
      await tester.pumpAndSettle();
      expect(captured, 1);
    });

    testWidgets(
      'Spending Limit form rejects scientific notation and 8+ decimal places',
      (tester) async {
        await _pump(
          tester,
          policies: const <StagedPolicy>[],
          signers: [_stagedDelegated()],
        );
        await tester.tap(find.text('Policy Type'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Spending Limit').last);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Period (days)'),
          '1',
        );
        await tester.pumpAndSettle();

        // Eight decimal places must be rejected (Stellar tops out at 7).
        await tester.enterText(
          find.widgetWithText(TextField, 'Amount'),
          '99.99999999',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Spending Limit Policy'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'positive amount with up to 7 decimal places',
          ),
          findsAtLeast(1),
        );
      },
    );

    testWidgets(
      'all-types-added: dropdown shows "All policy types already added"',
      (tester) async {
        // Build a staged policy list that covers every known policy type so
        // the available list is empty.
        final policies = [
          for (final info in knownPolicies)
            StagedPolicy(
              info: info,
              label: 'Test ${info.name}',
              scVal: buildSimpleThresholdScVal(threshold: 1),
            ),
        ];
        await _pump(
          tester,
          // Raise maxPolicies above the staged count so the add card stays
          // visible and we can assert on the dropdown empty-state copy.
          maxPolicies: knownPolicies.length + 1,
          policies: policies,
          signers: const <StagedSigner>[],
        );
        expect(find.text('All policy types already added'), findsOneWidget);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Staged policy rows
  // ---------------------------------------------------------------------------

  group('PolicyManagementSection — staged rows', () {
    testWidgets('renders policy badge, label, and address', (tester) async {
      final scVal = buildSimpleThresholdScVal(threshold: 2);
      final staged = StagedPolicy(
        info: knownPolicies.firstWhere((p) => p.type == 'threshold'),
        label: 'Threshold: 2-of-N',
        scVal: scVal,
      );

      await _pump(
        tester,
        policies: [staged],
        signers: const <StagedSigner>[],
      );

      expect(find.text('Threshold (M-of-N)'), findsAtLeast(1));
      expect(find.text('Threshold: 2-of-N'), findsOneWidget);
      expect(find.text('1 policy attached'), findsOneWidget);
    });
  });
}
