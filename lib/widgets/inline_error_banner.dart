/// Compact error banner used inline beneath form fields or section actions.
library;

import 'package:flutter/material.dart';

import '../util/semantic_colors.dart';

/// A small horizontal container with an error tint, an error icon and the
/// [message]. Use this for inline validation or in-flight failure feedback
/// next to the control that triggered it.
class InlineErrorBanner extends StatelessWidget {
  const InlineErrorBanner({
    required this.message,
    super.key,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.errorBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            color: colorScheme.onErrorContainer,
            size: 16,
            semanticLabel: '',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
