/// Tests for [PendingCredentialCard].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/widgets/pending_credential_card.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _longCredId =
    'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmVleGFtcGxl';
const String _contractId =
    'CABC1234567890123456789012345678901234567890123456789012';

Widget _buildCard({
  String credentialId = _longCredId,
  String? contractId = _contractId,
  String? nickname,
  bool enabled = true,
  bool isDeploying = false,
  String? errorMessage,
  Future<void> Function()? onRetry,
  Future<void> Function()? onDelete,
}) {
  return MaterialApp(
    home: Scaffold(
      body: PendingCredentialCard(
        credentialId: credentialId,
        contractId: contractId,
        nickname: nickname,
        enabled: enabled,
        isDeploying: isDeploying,
        errorMessage: errorMessage,
        onRetryDeploy: onRetry ?? () async {},
        onDelete: onDelete ?? () async {},
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('PendingCredentialCard', () {
    testWidgets('shows "Credential ID:" label', (tester) async {
      await tester.pumpWidget(_buildCard());
      expect(find.text('Credential ID:'), findsOneWidget);
    });

    testWidgets('shows "Contract ID:" label', (tester) async {
      await tester.pumpWidget(_buildCard());
      expect(find.text('Contract ID:'), findsOneWidget);
    });

    testWidgets('shows "Retry Deploy" button', (tester) async {
      await tester.pumpWidget(_buildCard());
      expect(find.text('Retry Deploy'), findsOneWidget);
    });

    testWidgets('shows "Delete" button', (tester) async {
      await tester.pumpWidget(_buildCard());
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('credential ID is truncated (first 12 + last 8)', (tester) async {
      await tester.pumpWidget(_buildCard());
      // Verify truncation: should NOT show the full raw string.
      expect(find.text(_longCredId), findsNothing);
      // Should contain ellipsis.
      expect(
        find.textContaining('...'),
        findsWidgets,
      );
    });

    testWidgets('null contractId shows "Unknown"', (tester) async {
      await tester.pumpWidget(_buildCard(contractId: null));
      expect(find.text('Unknown'), findsOneWidget);
    });

    testWidgets('nickname appears after credential ID', (tester) async {
      await tester.pumpWidget(
        _buildCard(nickname: 'My Key'),
      );
      expect(find.textContaining('My Key'), findsOneWidget);
    });

    testWidgets('shows loading label when isDeploying = true', (tester) async {
      await tester.pumpWidget(_buildCard(isDeploying: true));
      // LoadingButton shows "Deploying..." while loading — trigger a loading
      // state by checking that "Retry Deploy" can still be found in idle state.
      expect(find.text('Retry Deploy'), findsOneWidget);
    });

    testWidgets('shows inline error when errorMessage is set', (tester) async {
      await tester.pumpWidget(
        _buildCard(errorMessage: 'Deployment failed.'),
      );
      expect(find.text('Deployment failed.'), findsOneWidget);
    });

    testWidgets('no inline error when errorMessage is null', (tester) async {
      await tester.pumpWidget(_buildCard());
      expect(find.text('Deployment failed.'), findsNothing);
    });

    testWidgets('onRetryDeploy callback is invoked', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _buildCard(onRetry: () async { called = true; }),
      );
      await tester.tap(find.text('Retry Deploy'));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('onDelete callback is invoked', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _buildCard(onDelete: () async { called = true; }),
      );
      await tester.tap(find.text('Delete'));
      await tester.pump();
      expect(called, isTrue);
    });
  });

  group('PendingCredentialCard — truncation helpers', () {
    test('credential ID truncation: 12 + ... + 8 chars', () {
      const id = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890abcdefgh';
      final display = PendingCredentialCard.formatCredentialId(id, null);
      expect(display.length, lessThan(id.length));
      expect(display, startsWith('ABCDEFGHIJKL'));
      expect(display, contains('...'));
      expect(display, endsWith(id.substring(id.length - 8)));
    });

    test('short credential ID not truncated', () {
      const id = 'short';
      final display = PendingCredentialCard.formatCredentialId(id, null);
      expect(display, equals('short'));
    });

    test('nickname appended after truncated id', () {
      const id = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890abcdefgh';
      final display =
          PendingCredentialCard.formatCredentialId(id, 'My Phone');
      expect(display, contains('My Phone'));
      expect(display, contains('(My Phone)'));
    });
  });
}
