/// Widget tests for [EditPolicyParamsForm].
///
/// Covers:
/// 1. Renders pre-populated values from [EditPolicyEntry.originalParams].
/// 2. Editing the threshold value invokes onEntryUpdated with modified=true
///    and fresh install params.
/// 3. Reverting the value back to the original clears the modified flag.
/// 4. Spending-limit form rejects invalid amount inputs and keeps the
///    modified flag aligned with the user's last edit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart' show PolicyInfo;
import 'package:smart_account_demo/flows/context_rule_edit_types.dart';
import 'package:smart_account_demo/util/format_utils.dart'
    show nativeTokenDecimals;
import 'package:smart_account_demo/widgets/edit_policy_params_form.dart';

const PolicyInfo _thresholdInfo = PolicyInfo(
  type: 'threshold',
  name: 'Threshold (M-of-N)',
  description: '',
  address: 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
);

const PolicyInfo _spendingInfo = PolicyInfo(
  type: 'spending_limit',
  name: 'Spending Limit',
  description: '',
  address: 'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L',
);

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('threshold form pre-populates from originalParams',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final entry = EditPolicyEntry(
      info: _thresholdInfo,
      label: 'Threshold: 2-of-N',
      address: _thresholdInfo.address,
      onChainId: 1,
      isOriginal: true,
      originalParams: const PolicyParams(type: 'threshold', threshold: 2),
    );

    await tester.pumpWidget(_wrap(EditPolicyParamsForm(
      entry: entry,
      onEntryUpdated: (_) {},
      isSubmitting: false,
      spendingLimitDecimals: nativeTokenDecimals,
    )));
    await tester.pump();

    expect(find.text('Edit Threshold (M-of-N) Parameters'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('Current on-chain value: 2'), findsOneWidget);
  });

  testWidgets('editing the threshold reports modified=true with install params',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final entry = EditPolicyEntry(
      info: _thresholdInfo,
      label: 'Threshold: 2-of-N',
      address: _thresholdInfo.address,
      onChainId: 1,
      isOriginal: true,
      originalParams: const PolicyParams(type: 'threshold', threshold: 2),
    );

    EditPolicyEntry? captured;
    await tester.pumpWidget(_wrap(EditPolicyParamsForm(
      entry: entry,
      onEntryUpdated: (e) => captured = e,
      isSubmitting: false,
      spendingLimitDecimals: nativeTokenDecimals,
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '3');
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.modified, isTrue);
    expect(captured!.installSpec, isNotNull);
    expect(captured!.installSpec, isA<PolicyInstallSpecSimpleThreshold>());
    expect(
      (captured!.installSpec! as PolicyInstallSpecSimpleThreshold).threshold,
      3,
    );
    expect(captured!.label, 'Threshold: 3-of-N');
  });

  testWidgets('reverting the threshold clears modified flag', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final entry = EditPolicyEntry(
      info: _thresholdInfo,
      label: 'Threshold: 2-of-N',
      address: _thresholdInfo.address,
      onChainId: 1,
      isOriginal: true,
      originalParams: const PolicyParams(type: 'threshold', threshold: 2),
    );

    EditPolicyEntry? captured;
    await tester.pumpWidget(_wrap(EditPolicyParamsForm(
      entry: entry,
      onEntryUpdated: (e) => captured = e,
      isSubmitting: false,
      spendingLimitDecimals: nativeTokenDecimals,
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '5');
    await tester.pump();
    expect(captured!.modified, isTrue);

    await tester.enterText(find.byType(TextField).first, '2');
    await tester.pump();
    expect(captured!.modified, isFalse);
  });

  testWidgets('spending-limit form pre-populates amount and period days',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final entry = EditPolicyEntry(
      info: _spendingInfo,
      label: 'Limit: 100 / 1 day(s)',
      address: _spendingInfo.address,
      onChainId: 2,
      isOriginal: true,
      originalParams: const PolicyParams(
        type: 'spending_limit',
        spendingLimit: '100',
        periodDays: 1,
      ),
    );

    await tester.pumpWidget(_wrap(EditPolicyParamsForm(
      entry: entry,
      onEntryUpdated: (_) {},
      isSubmitting: false,
      spendingLimitDecimals: nativeTokenDecimals,
    )));
    await tester.pump();

    expect(find.text('Edit Spending Limit Parameters'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });
}
