/// Card widget displaying the most recent activity log entries.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/activity_log_state.dart';
import '../theme/spacing.dart';
import '../util/clipboard.dart';
import '../util/semantic_colors.dart';
import 'activity_log_level_badge.dart';

// ---------------------------------------------------------------------------
// ActivityLogCard
// ---------------------------------------------------------------------------

/// Displays the most recent activity log entries from [ActivityLogNotifier].
///
/// Layout:
/// - A header row showing "Activity Log (N)" — full count, not capped — with a
///   [Clear] button to wipe all entries.
/// - Up to [_maxVisible] entries listed newest-first. Each entry shows a short
///   HH:mm:ss timestamp, a level badge (INFO / OK / ERR), and the message text.
/// - Tapping an entry copies its redacted message to the clipboard and shows a
///   "Log message copied to clipboard" snackbar.
///
/// Empty state:
/// - When the log has no entries a "No activity yet" placeholder is shown.
///
/// Accessibility:
/// - Each row is an independent semantics node with a label combining the
///   timestamp, level, and message.
/// - A custom action exposes "Copy to clipboard" for assistive technologies.
class ActivityLogCard extends ConsumerWidget {
  /// Creates an [ActivityLogCard].
  const ActivityLogCard({super.key});

  /// Maximum number of entries visible in the card.
  static const int _maxVisible = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(activityLogProvider);
    final visible = entries.take(_maxVisible).toList();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: kCardPadding,
      decoration: BoxDecoration(
        color: colorScheme.cardBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeaderRow(
            entryCount: entries.length,
            onClear: () => ref.read(activityLogProvider.notifier).clear(),
          ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Semantics(
              label: 'Activity log is empty',
              child: Text(
                'No activity yet',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withAlpha(160),
                    ),
              ),
            )
          else
            Column(
              children: visible
                  .map((entry) => _LogEntryRow(entry: entry))
                  .toList(),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _HeaderRow
// ---------------------------------------------------------------------------

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.entryCount, required this.onClear});

  final int entryCount;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Semantics(
          header: true,
          child: Text(
            'Activity Log ($entryCount)',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        const Spacer(),
        if (entryCount > 0)
          Semantics(
            button: true,
            label: 'Clear activity log',
            child: TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Clear',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _LogEntryRow
// ---------------------------------------------------------------------------

class _LogEntryRow extends StatelessWidget {
  const _LogEntryRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final accessibilityLabel =
        '${_levelName(entry.level)} at ${_formatTime(entry.timestamp)}: '
        '${entry.message}';

    return Semantics(
      label: accessibilityLabel,
      hint: 'Double-tap to copy this entry to the clipboard',
      button: true,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        const CustomSemanticsAction(label: 'Copy to clipboard'): () =>
            _copyEntry(context),
      },
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _copyEntry(context),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: ActivityLogLevelBadge(level: entry.level),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatTime(entry.timestamp),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withAlpha(130),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                    Text(
                      entry.message,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _levelName(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return 'Info';
      case LogLevel.success:
        return 'Success';
      case LogLevel.error:
        return 'Error';
    }
  }

  String _formatTime(DateTime timestamp) {
    return DateFormat('HH:mm:ss').format(timestamp);
  }

  Future<void> _copyEntry(BuildContext context) {
    final safe = redactMessage(entry.message);
    return copyAndToast(
      context,
      safe,
      message: 'Log message copied to clipboard',
    );
  }
}
