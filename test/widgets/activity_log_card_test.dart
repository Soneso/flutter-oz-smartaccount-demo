/// Widget tests for [ActivityLogCard].
///
/// Covers the updated header text format, the [Clear] button, the empty-state
/// string (no trailing period), the log-level badge rendering, and the snackbar
/// text on entry tap.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/widgets/activity_log_card.dart';
import 'package:smart_account_demo/widgets/activity_log_level_badge.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

Widget _wrap({List<LogEntry> entries = const []}) {
  final container = ProviderContainer(
    overrides: [
      activityLogProvider.overrideWith(() {
        return _FixedActivityLogNotifier(entries);
      }),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      home: const Scaffold(body: ActivityLogCard()),
    ),
  );
}

/// Notifier that starts with a fixed list and supports [clear].
class _FixedActivityLogNotifier extends ActivityLogNotifier {
  _FixedActivityLogNotifier(this._initial);
  final List<LogEntry> _initial;

  @override
  List<LogEntry> build() => List.of(_initial);
}

LogEntry _makeEntry(String message, LogLevel level) {
  return LogEntry(
    message: message,
    level: level,
    timestamp: DateTime(2024, 1, 1, 12),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ActivityLogCard — empty state', () {
    testWidgets('shows "No activity yet" (no trailing period)', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('No activity yet'), findsOneWidget);
      // Ensure the old text with period is gone.
      expect(find.text('No activity yet.'), findsNothing);
    });

    testWidgets('header shows "Activity Log (0)" when empty', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Activity Log (0)'), findsOneWidget);
    });

    testWidgets('Clear button is not visible when no entries', (tester) async {
      await tester.pumpWidget(_wrap());
      expect(find.text('Clear'), findsNothing);
    });
  });

  group('ActivityLogCard — with entries', () {
    testWidgets('header shows full entry count', (tester) async {
      final entries = List.generate(
        12,
        (i) => _makeEntry('Message $i', LogLevel.info),
      );
      await tester.pumpWidget(_wrap(entries: entries));
      // Header must show total count (12), not capped at 10.
      expect(find.text('Activity Log (12)'), findsOneWidget);
    });

    testWidgets('Clear button is visible when entries exist', (tester) async {
      await tester.pumpWidget(
        _wrap(entries: [_makeEntry('Hello', LogLevel.info)]),
      );
      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('renders ActivityLogLevelBadge for each visible entry',
        (tester) async {
      final entries = [
        _makeEntry('Info msg', LogLevel.info),
        _makeEntry('OK msg', LogLevel.success),
        _makeEntry('Error msg', LogLevel.error),
      ];
      await tester.pumpWidget(_wrap(entries: entries));
      expect(find.byType(ActivityLogLevelBadge), findsNWidgets(3));
    });

    testWidgets('INFO badge label is "INFO"', (tester) async {
      await tester.pumpWidget(
        _wrap(entries: [_makeEntry('Info msg', LogLevel.info)]),
      );
      expect(find.text('INFO'), findsOneWidget);
    });

    testWidgets('success badge label is "OK"', (tester) async {
      await tester.pumpWidget(
        _wrap(entries: [_makeEntry('OK msg', LogLevel.success)]),
      );
      expect(find.text('OK'), findsOneWidget);
    });

    testWidgets('error badge label is "ERR"', (tester) async {
      await tester.pumpWidget(
        _wrap(entries: [_makeEntry('Err msg', LogLevel.error)]),
      );
      expect(find.text('ERR'), findsOneWidget);
    });

    testWidgets('shows at most 10 entries when log has more', (tester) async {
      final entries = List.generate(
        15,
        (i) => _makeEntry('Message $i', LogLevel.info),
      );
      await tester.pumpWidget(_wrap(entries: entries));
      // 15 entries exist but only 10 badges should be rendered (max visible).
      expect(find.byType(ActivityLogLevelBadge), findsNWidgets(10));
    });
  });

  group('ActivityLogCard — Clear button', () {
    testWidgets('tapping Clear empties the log', (tester) async {
      final container = ProviderContainer(
        overrides: [
          activityLogProvider.overrideWith(ActivityLogNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      // Pre-populate the log via the notifier.
      container.read(activityLogProvider.notifier).info('Entry 1');
      container.read(activityLogProvider.notifier).info('Entry 2');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: const Scaffold(body: ActivityLogCard()),
          ),
        ),
      );

      // Verify entries are present before clear.
      expect(container.read(activityLogProvider).length, equals(2));
      expect(find.text('Clear'), findsOneWidget);

      // Tap the Clear button.
      await tester.tap(find.text('Clear'));
      await tester.pump();

      // Log must be empty after clear.
      expect(container.read(activityLogProvider), isEmpty);
      expect(find.text('No activity yet'), findsOneWidget);
    });
  });

  group('ActivityLogCard — copy snackbar text', () {
    testWidgets('tapping entry shows "Log message copied to clipboard"',
        (tester) async {
      // Install a clipboard mock so the platform channel does not throw.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') return null;
        if (call.method == 'Clipboard.getData') return {'text': ''};
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.pumpWidget(
        _wrap(entries: [_makeEntry('Some message', LogLevel.info)]),
      );

      // Tap the entry row — use the message text as a finder.
      await tester.tap(find.text('Some message'));
      await tester.pumpAndSettle();

      expect(find.text('Log message copied to clipboard'), findsOneWidget);
    });
  });
}
