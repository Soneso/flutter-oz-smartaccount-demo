/// Widget tests for [ProgressCard].
///
/// Verifies:
/// - Default status text "Creating..." is rendered.
/// - Custom status text is rendered.
/// - CircularProgressIndicator is present.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/widgets/progress_card.dart';

Widget _wrap(ProgressCard card) {
  return MaterialApp(
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: card,
      ),
    ),
  );
}

void main() {
  group('ProgressCard', () {
    testWidgets('shows default Creating... status', (tester) async {
      await tester.pumpWidget(_wrap(const ProgressCard()));
      expect(find.text('Creating...'), findsOneWidget);
    });

    testWidgets('shows custom status text', (tester) async {
      await tester.pumpWidget(_wrap(const ProgressCard(status: 'Deploying...')));
      expect(find.text('Deploying...'), findsOneWidget);
    });

    testWidgets('contains CircularProgressIndicator', (tester) async {
      await tester.pumpWidget(_wrap(const ProgressCard()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
