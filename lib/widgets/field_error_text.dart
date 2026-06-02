/// Live-region error label rendered under a form field.
library;

import 'package:flutter/material.dart';

/// Live-region error label rendered under a form field.
///
/// Renders [error] in [ColorScheme.error] with a 4 dp top padding so it
/// can be dropped directly into a [Column] beneath the field without any
/// additional spacing widget. Returns [SizedBox.shrink] when [error] is
/// null so callers can wire it in unconditionally.
///
/// Wrapped in a `Semantics(liveRegion: true)` node so assistive technology
/// announces validation errors immediately when they appear.
class FieldErrorText extends StatelessWidget {
  /// Creates a [FieldErrorText].
  const FieldErrorText({required this.error, super.key});

  /// Error message to display, or null to render nothing.
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error == null) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          error!,
          style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
        ),
      ),
    );
  }
}
