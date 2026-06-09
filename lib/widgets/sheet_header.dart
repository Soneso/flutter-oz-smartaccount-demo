/// Shared bottom-sheet header with title, description, and close button.
///
/// Used by [ContractPickerSheet] and [SignerPickerSheet].
library;

import 'package:flutter/material.dart';

/// Header widget for modal bottom sheets.
///
/// Renders a [Semantics(header:true)] title and a description paragraph
/// below it. The close button is rendered when [onClose] is non-null.
class SheetHeader extends StatelessWidget {
  /// Constructs a sheet header.
  const SheetHeader({
    required this.title,
    required this.description,
    this.onClose,
    super.key,
  });

  /// Heading text displayed at the top of the sheet.
  final String title;

  /// Descriptive body text shown below the title.
  final String description;

  /// Called when the user taps the close icon. When null no close button
  /// is rendered (e.g. [ContractPickerSheet] uses action buttons instead).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final titleWidget = Expanded(
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
      ),
    );

    final descriptionWidget = Text(
      description,
      style: textTheme.bodyMedium?.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
    );

    if (onClose != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              titleWidget,
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 4),
          descriptionWidget,
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [titleWidget]),
          const SizedBox(height: 8),
          descriptionWidget,
        ],
      ),
    );
  }
}
