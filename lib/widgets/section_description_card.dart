/// Shared tinted card used for the description / header block at the top of
/// a screen or section.
library;

import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// Visual tint applied to a [SectionDescriptionCard]. Choose [neutral] for
/// secondary copy on a list screen and [primary] for the headline block of
/// a feature-level screen.
enum SectionDescriptionTint { neutral, primary }

/// A soft-tinted card that introduces a screen or section with a bold title
/// and a short supporting message.
class SectionDescriptionCard extends StatelessWidget {
  const SectionDescriptionCard({
    required this.title,
    required this.message,
    this.tint = SectionDescriptionTint.neutral,
    super.key,
  });

  final String title;
  final String message;
  final SectionDescriptionTint tint;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final bool isPrimary = tint == SectionDescriptionTint.primary;
    final Color background = isPrimary
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    final Color titleColor =
        isPrimary ? colorScheme.onPrimaryContainer : colorScheme.onSurface;
    final Color bodyColor = isPrimary
        ? colorScheme.onPrimaryContainer.withAlpha(210)
        : colorScheme.onSurfaceVariant;

    return Card(
      elevation: 0,
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isPrimary
            ? BorderSide.none
            : BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: textTheme.bodyMedium?.copyWith(color: bodyColor),
            ),
          ],
        ),
      ),
    );
  }
}
