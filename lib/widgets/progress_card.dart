/// A card displaying a circular progress indicator with a status message.
library;

import 'package:flutter/material.dart';

import '../theme/spacing.dart';
import 'loading_label.dart';

// ---------------------------------------------------------------------------
// ProgressCard
// ---------------------------------------------------------------------------

/// Displays a [CircularProgressIndicator] alongside a status text message.
///
/// Shown during long-running operations such as wallet creation to signal
/// that work is in progress. The [status] defaults to `"Creating..."` when
/// not provided.
class ProgressCard extends StatelessWidget {
  /// Creates a [ProgressCard].
  const ProgressCard({
    this.status = 'Creating...',
    super.key,
  });

  /// Status message displayed next to the spinner.
  final String status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: status,
      liveRegion: true,
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: kCardPadding,
          child: LoadingLabel(
            label: status,
            color: colorScheme.primary,
            size: 20,
            strokeWidth: 2.5,
            gap: 12,
            textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      ),
    );
  }
}
