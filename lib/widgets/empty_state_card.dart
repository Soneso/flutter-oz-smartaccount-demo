/// Shared card surface for empty, "not connected", and similar
/// informational states across screens.
library;

import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// A neutral card used to communicate empty or transient states such as
/// "wallet not connected", "no rules found", or "no signers loaded".
///
/// Layout: optional [icon] at the top, a bold [title], a wrapped [message],
/// and an optional [trailing] widget for an action button or extra controls.
class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({
    required this.title,
    required this.message,
    this.icon,
    this.trailing,
    super.key,
  });

  /// Optional icon shown centered above the title. When null the card starts
  /// directly with the title.
  final IconData? icon;

  /// Heading rendered with [TextTheme.titleSmall] and bold weight.
  final String title;

  /// Supporting copy rendered with [TextTheme.bodySmall].
  final String message;

  /// Optional widget rendered below the message, typically an action button
  /// row.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasIcon = icon != null;
    return Semantics(
      liveRegion: true,
      child: Card(
        elevation: 0,
        color: colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: kCardPadding,
          child: Column(
            crossAxisAlignment: hasIcon
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              if (hasIcon) ...[
                Icon(
                  icon,
                  size: 32,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 8),
              ],
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                  textAlign: hasIcon ? TextAlign.center : TextAlign.start,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: hasIcon ? TextAlign.center : TextAlign.start,
              ),
              if (trailing != null) ...[
                const SizedBox(height: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
