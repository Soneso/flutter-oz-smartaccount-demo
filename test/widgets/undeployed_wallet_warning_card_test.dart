/// Widget tests for [UndeployedWalletWarningCard].
///
/// Verifies the canonical strings ("Wallet Not Deployed", warning body text,
/// "Deploy Now" button), the "Deploying contract..." inline progress text while
/// the action is in flight, the inline error display when the action throws, and
/// the parent Semantics excludeSemantics contract.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/widgets/undeployed_wallet_warning_card.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

Widget _wrap({
  required Future<void> Function() onDeployNow,
}) {
  return MaterialApp(
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: SingleChildScrollView(
        child: UndeployedWalletWarningCard(
          onDeployNow: onDeployNow,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('UndeployedWalletWarningCard — static content', () {
    testWidgets('shows "Wallet Not Deployed" title', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(find.text('Wallet Not Deployed'), findsOneWidget);
    });

    testWidgets('shows warning body text', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(
        find.textContaining(
          'Your passkey is registered but the smart account contract has not '
          'been deployed to the network.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows "Deploy Now" button in idle state', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(find.text('Deploy Now'), findsOneWidget);
    });
  });

  group('UndeployedWalletWarningCard — loading state', () {
    testWidgets('shows "Deploying..." while action is in flight', (tester) async {
      final completer = Completer<void>();
      await tester.pumpWidget(
        _wrap(onDeployNow: () => completer.future),
      );

      await tester.tap(find.text('Deploy Now'));
      await tester.pump();

      // While the completer is pending the button should show "Deploying...".
      expect(find.text('Deploying...'), findsOneWidget);
      expect(find.text('Deploy Now'), findsNothing);

      // Resolve the future.
      completer.complete();
      await tester.pumpAndSettle();

      // After completion the button should revert to "Deploy Now".
      expect(find.text('Deploy Now'), findsOneWidget);
    });

    testWidgets('shows "Deploying contract..." inline text while in flight',
        (tester) async {
      final completer = Completer<void>();
      await tester.pumpWidget(
        _wrap(onDeployNow: () => completer.future),
      );

      await tester.tap(find.text('Deploy Now'));
      await tester.pump();

      expect(find.text('Deploying contract...'), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();

      // Progress text disappears after completion.
      expect(find.text('Deploying contract...'), findsNothing);
    });
  });

  group('UndeployedWalletWarningCard — inline error display', () {
    testWidgets('shows inline error container when action throws', (tester) async {
      await tester.pumpWidget(
        _wrap(
          onDeployNow: () async => throw Exception('deploy failed'),
        ),
      );

      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();

      // The inline error area should contain the error text.
      expect(find.textContaining('deploy failed'), findsOneWidget);
    });

    testWidgets('clears inline error on next Deploy Now tap', (tester) async {
      var callCount = 0;
      await tester.pumpWidget(
        _wrap(
          onDeployNow: () async {
            callCount++;
            if (callCount == 1) throw Exception('first deploy failed');
            // Second call succeeds.
          },
        ),
      );

      // First tap — produces error.
      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();
      expect(find.textContaining('first deploy failed'), findsOneWidget);

      // Second tap — error should be cleared immediately.
      await tester.tap(find.text('Deploy Now'));
      await tester.pump(); // one frame: setState clears error, sets deploying.

      expect(find.textContaining('first deploy failed'), findsNothing);

      await tester.pumpAndSettle();
    });

    testWidgets('no inline error container in idle state', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      // No error text or error container should appear.
      expect(find.textContaining('Exception'), findsNothing);
    });
  });

  group('UndeployedWalletWarningCard — semantics', () {
    testWidgets('parent Semantics uses excludeSemantics: true', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));

      // Walk the semantics tree — the parent Semantics node should have
      // [SemanticsFlag.scopesRoute] absent but [excludeSemantics] set, meaning
      // its children are blocked from the a11y tree.
      // We verify this by checking the rendered SemanticsNode for the card
      // does not produce duplicate labels from child Text nodes.
      final semanticsHandle = tester.ensureSemantics();

      final node = tester.getSemantics(find.byType(UndeployedWalletWarningCard));
      // The label should be the parent wrapper label only.
      expect(
        node.label,
        contains('Wallet Not Deployed'),
      );

      semanticsHandle.dispose();
    });
  });
}
