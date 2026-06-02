/// Widget tests for [OperationSummaryCard] and [formatDiffParts].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/context_rule_edit_types.dart';
import 'package:smart_account_demo/widgets/operation_summary_card.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

const String _fixtureAddress =
    'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';

EditSignerEntry _signerEntry() => EditSignerEntry(
      signer: OZDelegatedSigner(_fixtureAddress),
      onChainId: null,
      isOriginal: false,
    );

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  test('formatDiffParts emits the canonical order for a combined diff', () {
    final diff = ContextRuleEditDiff(
      ruleId: 1,
      nameChanged: true,
      newName: 'X',
      newSigners: [_signerEntry()],
      removedSigners: [_signerEntry()],
      newPolicies: const [],
      removedPolicies: const [],
      modifiedPolicies: const [],
      expiryChanged: true,
      newExpiry: null,
    );
    expect(formatDiffParts(diff), [
      'name update',
      '1 signer add(s)',
      '1 signer remove(s)',
      'expiry update',
    ]);
  });

  testWidgets('renders "No changes to apply" for an empty diff',
      (tester) async {
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
    await tester.pumpWidget(_wrap(const OperationSummaryCard(diff: diff)));
    await tester.pump();

    expect(find.text('No changes to apply'), findsOneWidget);
  });

  testWidgets('renders "Pending changes" + passkey count for non-empty diff',
      (tester) async {
    final diff = ContextRuleEditDiff(
      ruleId: 1,
      nameChanged: true,
      newName: 'Y',
      newSigners: [_signerEntry(), _signerEntry()],
      removedSigners: const <EditSignerEntry>[],
      newPolicies: const <EditPolicyEntry>[],
      removedPolicies: const <EditPolicyEntry>[],
      modifiedPolicies: const <EditPolicyEntry>[],
      expiryChanged: false,
      newExpiry: null,
    );
    await tester.pumpWidget(_wrap(OperationSummaryCard(diff: diff)));
    await tester.pump();

    expect(
      find.text('Pending changes: name update, 2 signer add(s)'),
      findsOneWidget,
    );
    expect(find.text('3 passkey prompt(s) required'), findsOneWidget);
  });
}
