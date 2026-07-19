/// Widget tests for [PolicyManagementSection].
///
/// Covers header strings, empty-state, type-dropdown filtering when all
/// types are added, per-type add forms, and validation error strings.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart'
    show PolicyInfo, knownPolicies;
import 'package:smart_account_demo/flows/context_rule_builder_types.dart';
import 'package:smart_account_demo/util/format_utils.dart'
    show nativeTokenDecimals;
import 'package:smart_account_demo/widgets/policy_management_section.dart';

import '../flows/context_rule_test_support.dart';

Future<void> _pump(
  WidgetTester tester, {
  required List<StagedPolicy> policies,
  required List<StagedSigner> signers,
  String? fieldError,
  bool isSubmitting = false,
  int maxPolicies = 5,
  int spendingLimitDecimals = nativeTokenDecimals,
  String? spendingLimitDecimalsError,
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
            spendingLimitDecimals: spendingLimitDecimals,
            spendingLimitDecimalsError: spendingLimitDecimalsError,
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
      'Spending Limit form rejects more fractional digits than the token '
      'decimals (7)',
      (tester) async {
        var captured = 0;
        await _pump(
          tester,
          policies: const <StagedPolicy>[],
          signers: [_stagedDelegated()],
          onAddPolicy: (_) {
            captured++;
            return null;
          },
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

        // Eight decimal places exceed the default native scale (7) and must
        // be rejected by the base-units conversion.
        await tester.enterText(
          find.widgetWithText(TextField, 'Amount'),
          '99.99999999',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Spending Limit Policy'));
        await tester.pumpAndSettle();

        expect(captured, 0);
        expect(
          find.textContaining('more than 7 fractional digits'),
          findsAtLeast(1),
        );
      },
    );

    testWidgets(
      'Spending Limit form converts the amount to the token base units',
      (tester) async {
        StagedPolicy? captured;
        await _pump(
          tester,
          policies: const <StagedPolicy>[],
          signers: [_stagedDelegated()],
          // A non-native scale exercises the resolved-decimals conversion.
          spendingLimitDecimals: 2,
          onAddPolicy: (p) {
            captured = p;
            return null;
          },
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
        await tester.enterText(
          find.widgetWithText(TextField, 'Amount'),
          '100.5',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Spending Limit Policy'));
        await tester.pumpAndSettle();

        final params = captured?.installParams;
        expect(params, isA<OZSpendingLimitPolicyParams>());
        // 100.5 at 2 decimals == 10050 base units.
        expect(
          (params! as OZSpendingLimitPolicyParams).spendingLimit,
          BigInt.from(10050),
        );
      },
    );

    testWidgets(
      'Weighted Threshold form rejects a per-signer weight below 1',
      (tester) async {
        var captured = 0;
        await _pump(
          tester,
          policies: const <StagedPolicy>[],
          signers: [_stagedDelegated()],
          onAddPolicy: (_) {
            captured++;
            return null;
          },
        );
        await tester.tap(find.text('Policy Type'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Weighted Threshold').last);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Weight Threshold'),
          '1',
        );
        await tester.pumpAndSettle();
        // Weight 0 is below the required minimum of 1.
        await tester.enterText(
          find.widgetWithText(TextField, 'Weight'),
          '0',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Weighted Threshold Policy'));
        await tester.pumpAndSettle();

        expect(captured, 0);
        expect(
          find.text('All signers must have a weight >= 1'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Weighted Threshold form rejects total weight below the threshold',
      (tester) async {
        var captured = 0;
        await _pump(
          tester,
          policies: const <StagedPolicy>[],
          signers: [_stagedDelegated()],
          onAddPolicy: (_) {
            captured++;
            return null;
          },
        );
        await tester.tap(find.text('Policy Type'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Weighted Threshold').last);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Weight Threshold'),
          '5',
        );
        await tester.pumpAndSettle();
        // Single signer weight 2 sums below the threshold of 5.
        await tester.enterText(
          find.widgetWithText(TextField, 'Weight'),
          '2',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Weighted Threshold Policy'));
        await tester.pumpAndSettle();

        expect(captured, 0);
        expect(
          find.text('Total weight (2) must be >= threshold (5)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Weighted Threshold form stages a valid weighted policy',
      (tester) async {
        StagedPolicy? captured;
        await _pump(
          tester,
          policies: const <StagedPolicy>[],
          signers: [_stagedDelegated()],
          onAddPolicy: (p) {
            captured = p;
            return null;
          },
        );
        await tester.tap(find.text('Policy Type'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Weighted Threshold').last);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Weight Threshold'),
          '2',
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Weight'),
          '3',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Weighted Threshold Policy'));
        await tester.pumpAndSettle();

        final params = captured?.installParams;
        expect(params, isA<OZWeightedThresholdPolicyParams>());
        final weighted = params! as OZWeightedThresholdPolicyParams;
        expect(weighted.threshold, 2);
        expect(weighted.signerWeights.values.single, 3);
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
              installParams: const OZSimpleThresholdPolicyParams(threshold: 1),
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
  // Submitting: add card disabled, not hidden
  // ---------------------------------------------------------------------------

  group('PolicyManagementSection — submitting', () {
    testWidgets(
      'add card stays visible with a disabled policy-type selector while '
      'submitting',
      (tester) async {
        await _pump(
          tester,
          policies: const <StagedPolicy>[],
          signers: const <StagedSigner>[],
          isSubmitting: true,
        );

        // The Add Policy card is rendered (disabled, not hidden).
        expect(find.text('Add Policy'), findsOneWidget);

        // The policy-type selector is disabled.
        final dropdown = tester.widget<DropdownButtonFormField<PolicyInfo>>(
          find.byType(DropdownButtonFormField<PolicyInfo>),
        );
        expect(dropdown.onChanged, isNull);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Staged policy rows
  // ---------------------------------------------------------------------------

  group('PolicyManagementSection — staged rows', () {
    testWidgets('renders policy badge, label, and address', (tester) async {
      final staged = StagedPolicy(
        info: knownPolicies.firstWhere((p) => p.type == 'threshold'),
        label: 'Threshold: 2-of-N',
        installParams: const OZSimpleThresholdPolicyParams(threshold: 2),
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
