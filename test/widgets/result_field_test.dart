/// Widget tests for [ResultField].
///
/// Verifies:
/// - Label and value are rendered.
/// - "Tap to copy" hint is shown.
/// - Tapping copies value to clipboard and shows "Copied" snackbar.
/// - semanticValue overrides the Semantics label.
/// - Copy hint is in the hint slot, not appended to label.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/widgets/result_field.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _wrap(ResultField field) {
  return MaterialApp(
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: field,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Track clipboard writes.
  final clipboardLog = <String>[];
  setUp(() {
    clipboardLog.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final text =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
        if (text != null) clipboardLog.add(text);
      }
      return null;
    });
  });

  group('ResultField — rendering', () {
    testWidgets('renders label', (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Contract Address',
        value: 'CABC1234',
      )));

      expect(find.text('Contract Address'), findsOneWidget);
    });

    testWidgets('renders value', (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Contract Address',
        value: 'CABC1234',
      )));

      expect(find.text('CABC1234'), findsOneWidget);
    });

    testWidgets('renders Tap to copy hint', (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Contract Address',
        value: 'CABC1234',
      )));

      expect(find.text('Tap to copy'), findsOneWidget);
    });
  });

  group('ResultField — copy behaviour', () {
    testWidgets('tap copies value to clipboard', (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Contract Address',
        value: 'CABC1234ABCD',
      )));

      await tester.tap(find.text('CABC1234ABCD'));
      await tester.pump();

      expect(clipboardLog, contains('CABC1234ABCD'));
    });

    testWidgets('tap shows Copied snackbar', (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Credential ID',
        value: 'cred-abc-123',
      )));

      await tester.tap(find.text('cred-abc-123'));
      await tester.pump();

      expect(find.text('Copied'), findsOneWidget);
    });
  });

  group('ResultField — semanticValue', () {
    testWidgets('Semantics label uses semanticValue when provided',
        (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Credential ID',
        value: 'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU',
        semanticValue: 'dGVzdC1j...aWZpeHR1',
      )));

      final semantics = tester.getSemantics(find.byType(ResultField));
      expect(semantics.label, contains('dGVzdC1j...aWZpeHR1'));
      expect(semantics.label, isNot(contains('dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU')));
    });

    testWidgets('Semantics label uses value when semanticValue is null',
        (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Contract Address',
        value: 'CABC1234',
      )));

      final semantics = tester.getSemantics(find.byType(ResultField));
      expect(semantics.label, contains('CABC1234'));
    });

    testWidgets('copy hint is in Semantics hint slot, not appended to label',
        (tester) async {
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Contract Address',
        value: 'CABC1234',
      )));

      final semantics = tester.getSemantics(find.byType(ResultField));
      // Label must not contain the copy instruction.
      expect(semantics.label, isNot(contains('Tap to copy')));
      // Hint carries the copy instruction.
      expect(semantics.hint, equals('Tap to copy'));
    });

    testWidgets('clipboard receives unredacted value when semanticValue set',
        (tester) async {
      const fullValue = 'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU';
      await tester.pumpWidget(_wrap(const ResultField(
        label: 'Credential ID',
        value: fullValue,
        semanticValue: 'dGVzdC1j...aWZpeHR1',
      )));

      await tester.tap(find.text(fullValue));
      await tester.pump();

      expect(clipboardLog, contains(fullValue));
    });
  });
}
