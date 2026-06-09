/// Widget tests for [TransferResultCard].
///
/// Verifies all verbatim label strings and interaction behaviour.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/transfer_flow.dart';
import 'package:smart_account_demo/widgets/transfer_result_card.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _defaultResult = TransferResult(
  transactionHash:
      'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
  amount: '10.0',
  tokenLabel: 'XLM',
  recipient: 'GABC1234567890123456789012345678901234567890123456789012',
);

Widget _wrap({
  TransferResult? result,
  String xlmBalance = '99.5',
  String? demoTokenBalance,
  VoidCallback? onNewTransfer,
  VoidCallback? onGoToMainScreen,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TransferResultCard(
          result: result ?? _defaultResult,
          xlmBalance: xlmBalance,
          demoTokenBalance: demoTokenBalance,
          onNewTransfer: onNewTransfer ?? () {},
          onGoToMainScreen: onGoToMainScreen ?? () {},
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('TransferResultCard — verbatim strings', () {
    testWidgets('shows "Transfer Successful"', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Transfer Successful'), findsOneWidget);
    });

    testWidgets('shows "Transaction Hash" label', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Transaction Hash'), findsOneWidget);
    });

    testWidgets('shows "Copy" button', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('shows the transaction hash truncated, not in full',
        (tester) async {
      await tester.pumpWidget(_wrap());
      // The row displays the truncated form (first 4 + last 4); the full
      // hash is copied on tap but never rendered.
      expect(find.text('abc1...abcd'), findsOneWidget);
      expect(find.text(_defaultResult.transactionHash), findsNothing);
    });

    testWidgets('shows "Amount Sent" label', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Amount Sent'), findsOneWidget);
    });

    testWidgets('shows "Recipient" label', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Recipient'), findsOneWidget);
    });

    testWidgets('shows "Updated Balance" label', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Updated Balance'), findsOneWidget);
    });

    testWidgets('shows "New Transfer" button', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('New Transfer'), findsOneWidget);
    });

    testWidgets('shows "Go to Main Screen" button', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Go to Main Screen'), findsOneWidget);
    });
  });

  group('TransferResultCard — data display', () {
    testWidgets('shows amount with token label', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('10.0 XLM'), findsOneWidget);
    });

    testWidgets('shows XLM balance', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('99.5 XLM'), findsOneWidget);
    });

    testWidgets('shows DEMO balance when non-null', (tester) async {
      await tester.pumpWidget(_wrap(demoTokenBalance: '500.0'));
      expect(find.text('500.0 DEMO'), findsOneWidget);
    });

    testWidgets('hides DEMO balance when null', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.textContaining('DEMO'), findsNothing);
    });

    testWidgets('shows fallback "0.0" for null XLM balance', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TransferResultCard(
                result: _defaultResult,
                xlmBalance: null,
                demoTokenBalance: null,
                onNewTransfer: () {},
                onGoToMainScreen: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('0.0 XLM'), findsOneWidget);
    });
  });

  group('TransferResultCard — interactions', () {
    testWidgets('onNewTransfer called when "New Transfer" tapped', (tester) async {
      var called = false;
      await tester.pumpWidget(_wrap(onNewTransfer: () => called = true));
      await tester.tap(find.text('New Transfer'));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('onGoToMainScreen called when "Go to Main Screen" tapped', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(onGoToMainScreen: () => called = true),
      );
      await tester.tap(find.text('Go to Main Screen'));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('"Copy" button shows "Transaction hash copied" snackbar', (tester) async {
      // Install a clipboard mock so the platform channel does not throw.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') return null;
        if (call.method == 'Clipboard.getData') return {'text': ''};
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.pumpWidget(_wrap());
      await tester.ensureVisible(find.text('Copy'));
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(find.text('Transaction hash copied'), findsOneWidget);
    });
  });
}
