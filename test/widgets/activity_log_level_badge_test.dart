/// Widget tests for [ActivityLogLevelBadge].
///
/// Verifies that the correct label text is rendered for each [LogLevel], that
/// the badge excludes itself from the semantics tree, and that the Option A
/// contrast fix is applied: background uses surfaceContainerHighest, border
/// uses the spec accent color, and text uses onSurface (WCAG AA safe).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/util/semantic_colors.dart';
import 'package:smart_account_demo/widgets/activity_log_level_badge.dart';

Widget _wrap(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? ThemeData.light(useMaterial3: true),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('ActivityLogLevelBadge — label text', () {
    testWidgets('renders INFO label for LogLevel.info', (tester) async {
      await tester.pumpWidget(
        _wrap(const ActivityLogLevelBadge(level: LogLevel.info)),
      );
      expect(find.text('INFO'), findsOneWidget);
    });

    testWidgets('renders OK label for LogLevel.success', (tester) async {
      await tester.pumpWidget(
        _wrap(const ActivityLogLevelBadge(level: LogLevel.success)),
      );
      expect(find.text('OK'), findsOneWidget);
    });

    testWidgets('renders ERR label for LogLevel.error', (tester) async {
      await tester.pumpWidget(
        _wrap(const ActivityLogLevelBadge(level: LogLevel.error)),
      );
      expect(find.text('ERR'), findsOneWidget);
    });
  });

  group('ActivityLogLevelBadge — contrast fix (Option A)', () {
    // Helper: resolves the Container decoration for the badge widget.
    BoxDecoration resolveDecoration(WidgetTester tester) {
      final container = tester.widget<Container>(find.byType(Container).first);
      return container.decoration! as BoxDecoration;
    }

    testWidgets('INFO badge background is surfaceContainerHighest',
        (tester) async {
      final theme = ThemeData.light(useMaterial3: true);
      await tester.pumpWidget(
        _wrap(const ActivityLogLevelBadge(level: LogLevel.info), theme: theme),
      );
      final deco = resolveDecoration(tester);
      expect(deco.color, equals(theme.colorScheme.surfaceContainerHighest));
    });

    testWidgets('INFO badge border accent is activityLogInfo spec color',
        (tester) async {
      final theme = ThemeData.light(useMaterial3: true);
      await tester.pumpWidget(
        _wrap(const ActivityLogLevelBadge(level: LogLevel.info), theme: theme),
      );
      final deco = resolveDecoration(tester);
      final border = deco.border as Border;
      expect(
        border.top.color,
        equals(theme.colorScheme.activityLogInfo),
      );
    });

    testWidgets('OK badge border accent is activityLogOk spec color',
        (tester) async {
      final theme = ThemeData.light(useMaterial3: true);
      await tester.pumpWidget(
        _wrap(
          const ActivityLogLevelBadge(level: LogLevel.success),
          theme: theme,
        ),
      );
      final deco = resolveDecoration(tester);
      final border = deco.border as Border;
      expect(
        border.top.color,
        equals(theme.colorScheme.activityLogOk),
      );
    });

    testWidgets('ERR badge border accent is activityLogErr spec color',
        (tester) async {
      final theme = ThemeData.light(useMaterial3: true);
      await tester.pumpWidget(
        _wrap(
          const ActivityLogLevelBadge(level: LogLevel.error),
          theme: theme,
        ),
      );
      final deco = resolveDecoration(tester);
      final border = deco.border as Border;
      expect(
        border.top.color,
        equals(theme.colorScheme.activityLogErr),
      );
    });

    testWidgets('INFO badge text uses onSurface (WCAG AA safe)', (tester) async {
      final theme = ThemeData.light(useMaterial3: true);
      await tester.pumpWidget(
        _wrap(const ActivityLogLevelBadge(level: LogLevel.info), theme: theme),
      );
      final textWidget = tester.widget<Text>(find.text('INFO'));
      expect(textWidget.style?.color, equals(theme.colorScheme.onSurface));
    });

    testWidgets('OK badge text uses onSurface (WCAG AA safe)', (tester) async {
      final theme = ThemeData.light(useMaterial3: true);
      await tester.pumpWidget(
        _wrap(
          const ActivityLogLevelBadge(level: LogLevel.success),
          theme: theme,
        ),
      );
      final textWidget = tester.widget<Text>(find.text('OK'));
      expect(textWidget.style?.color, equals(theme.colorScheme.onSurface));
    });

    testWidgets('ERR badge text uses onSurface (WCAG AA safe)', (tester) async {
      final theme = ThemeData.light(useMaterial3: true);
      await tester.pumpWidget(
        _wrap(
          const ActivityLogLevelBadge(level: LogLevel.error),
          theme: theme,
        ),
      );
      final textWidget = tester.widget<Text>(find.text('ERR'));
      expect(textWidget.style?.color, equals(theme.colorScheme.onSurface));
    });
  });
}
