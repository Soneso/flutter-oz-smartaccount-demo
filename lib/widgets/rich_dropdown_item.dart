/// Reusable two-line content for [DropdownMenuItem] children.
///
/// Renders a bold title above an optional dim subtitle, sized so the
/// surrounding `DropdownButtonFormField` (constructed with
/// `itemHeight: null`) can size each menu row to its content. Paired with
/// `selectedItemBuilder` that returns a single-line `Text(title)` so the
/// closed control stays compact.
library;

import 'package:flutter/material.dart';

/// Two-line dropdown item with [title] and optional [subtitle].
class RichDropdownItem extends StatelessWidget {
  /// Creates a [RichDropdownItem].
  const RichDropdownItem({
    required this.title,
    this.subtitle,
    super.key,
  });

  /// Primary label rendered with the inherited title weight.
  final String title;

  /// Optional secondary description rendered below [title] in a dimmer
  /// foreground colour.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
