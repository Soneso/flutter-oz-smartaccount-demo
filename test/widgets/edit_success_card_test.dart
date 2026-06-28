/// Widget tests for [EditSuccessCard].
///
/// Covers:
/// 1. Full-success variant renders "All Changes Applied", the hash list,
///    and the Done button.
/// 2. Partial-success variant renders "Partial Update", the auth-guard
///    message, and no Done button.
/// 3. Failure variant renders "Update Failed", the error message, the
///    failed-step descriptor, and no Done button.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/context_rule_edit_types.dart';
import 'package:smart_account_demo/widgets/edit_success_card.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('full success: title, hash list, Done button', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    var doneTapped = false;
    const result = ContextRuleEditResult(
      success: true,
      completedOperations: 2,
      totalOperations: 2,
      partialDueToAuthGuard: false,
      authGuardMessage: null,
      error: null,
      failedStep: null,
      transactionHashes: ['hash-a', 'hash-b'],
    );
    await tester.pumpWidget(_wrap(EditSuccessCard(
      result: result,
      onDone: () => doneTapped = true,
    )));
    await tester.pump();

    expect(find.text('All Changes Applied'), findsOneWidget);
    expect(find.text('2 of 2 operation(s) completed'), findsOneWidget);
    expect(find.text('Transaction Hashes'), findsOneWidget);
    expect(find.text('hash-a'), findsOneWidget);
    expect(find.text('hash-b'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await tester.tap(find.text('Done'));
    expect(doneTapped, isTrue);
  });

  testWidgets('partial success: blue card + auth-guard message + no Done',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const result = ContextRuleEditResult(
      success: true,
      completedOperations: 1,
      totalOperations: 3,
      partialDueToAuthGuard: true,
      authGuardMessage: 'Signers changed; reload and retry.',
      error: null,
      failedStep: null,
      transactionHashes: ['hash-a'],
    );
    await tester.pumpWidget(_wrap(EditSuccessCard(
      result: result,
      onDone: () {},
    )));
    await tester.pump();

    expect(find.text('Partial Update'), findsOneWidget);
    expect(find.text('1 of 3 operation(s) completed'), findsOneWidget);
    expect(find.text('Signers changed; reload and retry.'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('failure: red card + Failed at: step + no Done', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const result = ContextRuleEditResult(
      success: false,
      completedOperations: 0,
      totalOperations: 2,
      partialDueToAuthGuard: false,
      authGuardMessage: null,
      error: 'rejected by contract',
      failedStep: 'Updating rule name',
    );
    await tester.pumpWidget(_wrap(EditSuccessCard(
      result: result,
      onDone: () {},
    )));
    await tester.pump();

    expect(find.text('Update Failed'), findsOneWidget);
    expect(find.text('0 of 2 operation(s) completed'), findsOneWidget);
    expect(find.text('rejected by contract'), findsOneWidget);
    expect(find.text('Failed at: Updating rule name'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
  });
}
