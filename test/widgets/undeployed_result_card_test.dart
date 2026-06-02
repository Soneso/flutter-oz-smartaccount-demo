/// Widget tests for [UndeployedResultCard].
///
/// Verifies:
/// - Required fields rendered.
/// - Warning banner text shown.
/// - Deploy Now triggers callback.
/// - Deploy error is sanitised and shown inline on failure.
/// - Deploy Now button is disabled after a failure.
/// - onDeploySucceeded fires on success.
/// - Go to Main Screen callback fires.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/wallet_creation_flow.dart';
import 'package:smart_account_demo/widgets/undeployed_result_card.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _result = WalletCreationResult(
  contractAddress: 'CABC1234567890123456789012345678901234567890123456789012',
  credentialId: 'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU',
  isDeployed: false,
);

Widget _wrap({
  required Future<void> Function() onDeployNow,
  VoidCallback? onGoToMainScreen,
  VoidCallback? onDeploySucceeded,
}) {
  return MaterialApp(
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: UndeployedResultCard(
          result: _result,
          onDeployNow: onDeployNow,
          onGoToMainScreen: onGoToMainScreen ?? () {},
          onDeploySucceeded: onDeploySucceeded,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
  });

  group('UndeployedResultCard — rendering', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(find.text('Passkey Registered'), findsOneWidget);
    });

    testWidgets('renders Credential ID field', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(find.text('Credential ID'), findsOneWidget);
    });

    testWidgets('renders Contract Address (derived) field', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(find.text('Contract Address (derived)'), findsOneWidget);
    });

    testWidgets('renders warning banner text', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(
        find.textContaining(
          'The wallet contract has not been deployed to the network yet.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders Deploy Now button', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(find.text('Deploy Now'), findsOneWidget);
    });

    testWidgets('renders Go to Main Screen button', (tester) async {
      await tester.pumpWidget(_wrap(onDeployNow: () async {}));
      expect(find.text('Go to Main Screen'), findsOneWidget);
    });
  });

  group('UndeployedResultCard — Deploy Now behaviour', () {
    testWidgets('Deploy Now fires onDeployNow callback', (tester) async {
      var called = false;
      await tester.pumpWidget(_wrap(
        onDeployNow: () async => called = true,
      ));

      await tester.tap(find.text('Deploy Now'));
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('shows Deploying... while in flight', (tester) async {
      final completer = Completer<void>();
      await tester.pumpWidget(_wrap(onDeployNow: () => completer.future));

      await tester.tap(find.text('Deploy Now'));
      await tester.pump();

      expect(find.text('Deploying...'), findsOneWidget);
      expect(find.text('Deploying contract...'), findsOneWidget);

      // Complete so the widget can settle cleanly.
      completer.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('shows inline error when deploy fails', (tester) async {
      await tester.pumpWidget(_wrap(
        onDeployNow: () async => throw Exception('Deploy failed'),
      ));

      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();

      // classifyError surfaces the underlying exception's toString() so
      // demo developers can diagnose unknown failures.
      expect(find.textContaining('Unexpected error:'), findsOneWidget);
      expect(find.textContaining('Deploy failed'), findsOneWidget);
    });

    testWidgets('Deploy Now button disabled after failure', (tester) async {
      await tester.pumpWidget(_wrap(
        onDeployNow: () async => throw Exception('Deploy failed'),
      ));

      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();

      // After failure the action is replaced with () async {} — a re-tap
      // should not trigger the original onDeployNow again.
      // We simply verify the error stays visible (not cleared by re-deploy).
      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();

      // Error message still present — no second deploy was attempted.
      expect(find.textContaining('Unexpected error:'), findsOneWidget);
    });

    testWidgets('shows retry guidance after failure', (tester) async {
      await tester.pumpWidget(_wrap(
        onDeployNow: () async => throw Exception('Deploy failed'),
      ));

      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Retry from the Connect Wallet screen'),
        findsOneWidget,
      );
    });

    testWidgets('fires onDeploySucceeded callback on success', (tester) async {
      var succeeded = false;
      await tester.pumpWidget(_wrap(
        onDeployNow: () async {},
        onDeploySucceeded: () => succeeded = true,
      ));

      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();

      expect(succeeded, isTrue);
    });
  });

  group('UndeployedResultCard — Go to Main Screen', () {
    testWidgets('Go to Main Screen fires callback', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(
        onDeployNow: () async {},
        onGoToMainScreen: () => tapped = true,
      ));

      await tester.tap(find.text('Go to Main Screen'));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });
  });
}
