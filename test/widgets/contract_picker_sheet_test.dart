/// Tests for [ContractPickerSheet].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/widgets/contract_picker_sheet.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _addr1 =
    'CABC1234567890123456789012345678901234567890123456789012';
const String _addr2 =
    'CBCD1234567890123456789012345678901234567890123456789012';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) => child),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ContractPickerSheet', () {
    testWidgets('shows "Select Wallet" title', (tester) async {
      await tester.pumpWidget(
        _wrap(ContractPickerSheet(candidates: [_addr1, _addr2])),
      );
      expect(find.text('Select Wallet'), findsOneWidget);
    });

    testWidgets('shows description text', (tester) async {
      await tester.pumpWidget(
        _wrap(ContractPickerSheet(candidates: [_addr1, _addr2])),
      );
      expect(
        find.textContaining(
          'This passkey is a signer on more than one wallet.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows a radio tile for each candidate', (tester) async {
      await tester.pumpWidget(
        _wrap(ContractPickerSheet(candidates: [_addr1, _addr2])),
      );
      // Each address is shown truncated — just verify two RadioListTile widgets.
      expect(find.byType(RadioListTile<String>), findsNWidgets(2));
    });

    testWidgets('"Connect" button is disabled before selection', (tester) async {
      await tester.pumpWidget(
        _wrap(ContractPickerSheet(candidates: [_addr1, _addr2])),
      );
      final connectButton = find.widgetWithText(FilledButton, 'Connect');
      expect(connectButton, findsOneWidget);
      final btn = tester.widget<FilledButton>(connectButton);
      expect(btn.onPressed, isNull);
    });

    testWidgets('"Connect" button enabled after selection', (tester) async {
      await tester.pumpWidget(
        _wrap(ContractPickerSheet(candidates: [_addr1, _addr2])),
      );
      // Select the first radio tile.
      await tester.tap(find.byType(RadioListTile<String>).first);
      await tester.pump();

      final connectButton = find.widgetWithText(FilledButton, 'Connect');
      final btn = tester.widget<FilledButton>(connectButton);
      expect(btn.onPressed, isNotNull);
    });

    testWidgets('shows "Cancel" button', (tester) async {
      await tester.pumpWidget(
        _wrap(ContractPickerSheet(candidates: [_addr1, _addr2])),
      );
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('ContractPickerSheet.show resolves to null on cancel',
        (tester) async {
      String? chosen;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  chosen = await ContractPickerSheet.show(
                    context: context,
                    candidates: [_addr1, _addr2],
                  );
                },
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();

      // Tap Cancel.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(chosen, isNull);
    });

    testWidgets('ContractPickerSheet.show resolves to selected address',
        (tester) async {
      String? chosen;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  chosen = await ContractPickerSheet.show(
                    context: context,
                    candidates: [_addr1, _addr2],
                  );
                },
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();

      // Select the first tile.
      await tester.tap(find.byType(RadioListTile<String>).first);
      await tester.pump();

      // Tap Connect.
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(chosen, equals(_addr1));
    });
  });
}
