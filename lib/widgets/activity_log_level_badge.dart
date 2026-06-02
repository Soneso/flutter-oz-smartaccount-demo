/// Small pill badge rendering a log-level label for activity log entries.
library;

import 'package:flutter/material.dart';

import '../state/activity_log_state.dart';
import '../util/semantic_colors.dart';
import 'pill.dart';

// ---------------------------------------------------------------------------
// ActivityLogLevelBadge
// ---------------------------------------------------------------------------

/// A small rounded-rectangle badge rendering one of the three log-level
/// labels: [LogLevel.info] → "INFO", [LogLevel.success] → "OK",
/// [LogLevel.error] → "ERR".
///
/// Visual design (WCAG AA compliant):
/// - Background: [ColorScheme.surfaceContainerHighest], a neutral Material 3
///   surface token with sufficient contrast for [onSurface] text in both
///   light and dark modes.
/// - Border: 1.5 dp solid border in the accent color
///   ([SemanticColors.activityLogInfo] / [activityLogOk] / [activityLogErr]),
///   used as an identity accent rather than as foreground text.
/// - Text: [ColorScheme.onSurface].
///
/// Accessibility:
/// The badge is excluded from the semantics tree. The surrounding
/// [_LogEntryRow] provides a combined label that includes the level name.
class ActivityLogLevelBadge extends StatelessWidget {
  /// Creates an [ActivityLogLevelBadge] for [level].
  const ActivityLogLevelBadge({required this.level, super.key});

  /// The log level that determines the badge label and border accent color.
  final LogLevel level;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accentColor = _accentColor(cs);
    final label = _label();

    return ExcludeSemantics(
      child: Pill(
        label: label,
        background: cs.surfaceContainerHighest,
        foreground: cs.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(color: accentColor, width: 1.5),
        textStyle: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  String _label() {
    switch (level) {
      case LogLevel.info:
        return 'INFO';
      case LogLevel.success:
        return 'OK';
      case LogLevel.error:
        return 'ERR';
    }
  }

  /// Returns the accent color used as the border tint.
  ///
  /// These fixed values come from [SemanticColors] and are used only as border
  /// accents, not as text colors.
  Color _accentColor(ColorScheme cs) {
    switch (level) {
      case LogLevel.info:
        return cs.activityLogInfo;
      case LogLevel.success:
        return cs.activityLogOk;
      case LogLevel.error:
        return cs.activityLogErr;
    }
  }
}
