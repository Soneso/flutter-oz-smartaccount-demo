/// Widget tests for [DeployedResultCard].
///
/// Verifies:
/// - All required fields are rendered.
/// - Transaction hash row is shown only when non-null.
/// - DEMO balance row is shown only when non-null.
/// - "Go to Main Screen" button triggers the callback.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/wallet_creation_flow.dart';
import 'package:smart_account_demo/widgets/deployed_result_card.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

WalletCreationResult _fullResult() {
  return const WalletCreationResult(
    contractAddress: 'CABC1234567890123456789012345678901234567890123456789012',
    credentialId: 'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU',
    isDeployed: true,
    xlmBalance: '10.5',
    demoTokenBalance: '1000.0',
    transactionHash: 'abc123txhash',
  );
}

WalletCreationResult _minimalResult() {
  return const WalletCreationResult(
    contractAddress: 'CABC1234567890123456789012345678901234567890123456789012',
    credentialId: 'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU',
    isDeployed: true,
  );
}

Widget _wrap(DeployedResultCard card) {
  return MaterialApp(
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: card,
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

  group('DeployedResultCard — full result', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _fullResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.text('Wallet Created Successfully'), findsOneWidget);
    });

    testWidgets('renders Credential ID label and value', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _fullResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.text('Credential ID'), findsOneWidget);
      expect(find.text('dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU'), findsOneWidget);
    });

    testWidgets('renders Contract Address label and value', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _fullResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.text('Contract Address'), findsOneWidget);
      expect(
        find.text('CABC1234567890123456789012345678901234567890123456789012'),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('renders Transaction Hash when present', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _fullResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.text('Transaction Hash'), findsOneWidget);
      expect(find.text('abc123txhash'), findsOneWidget);
    });

    testWidgets('renders Balance section with XLM and DEMO', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _fullResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.text('Balance'), findsOneWidget);
      expect(find.text('10.5 XLM'), findsOneWidget);
      expect(find.text('1000.0 DEMO'), findsOneWidget);
    });

    testWidgets('renders Go to Main Screen button', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _fullResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.text('Go to Main Screen'), findsOneWidget);
    });

    testWidgets('Go to Main Screen button fires callback', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _fullResult(),
        onGoToMainScreen: () => tapped = true,
      )));

      await tester.tap(find.text('Go to Main Screen'));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });
  });

  group('DeployedResultCard — minimal result (no optional fields)', () {
    testWidgets('Transaction Hash row absent when null', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _minimalResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.text('Transaction Hash'), findsNothing);
    });

    testWidgets('DEMO balance absent when null', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _minimalResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.textContaining('DEMO'), findsNothing);
    });

    testWidgets('XLM balance absent when null', (tester) async {
      await tester.pumpWidget(_wrap(DeployedResultCard(
        result: _minimalResult(),
        onGoToMainScreen: () {},
      )));

      expect(find.textContaining('XLM'), findsNothing);
    });
  });
}
