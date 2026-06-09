/// Annotation badge constants and widget.
///
/// Used in signer and policy management sections to indicate on-chain
/// presence or pending modification.
library;

import 'package:flutter/material.dart';

/// Badge labels for common annotation states.
abstract final class AnnotationBadgeLabel {
  /// Label for an entry that exists on-chain.
  static const String onChain = '(on-chain)';

  /// Label for an entry with pending parameter modifications.
  static const String modified = '(modified)';
}

/// A small bold inline label used as an annotation beside a signer or policy
/// entry.
///
/// [label] is the annotation text (e.g. [AnnotationBadgeLabel.onChain]).
/// [color] drives the text color; defaults to the theme's
/// [ColorScheme.onSurfaceVariant] when null.
class AnnotationBadge extends StatelessWidget {
  /// Constructs an annotation badge.
  const AnnotationBadge({
    required this.label,
    this.color,
    super.key,
  });

  /// The annotation text.
  final String label;

  /// Text color. When null, the theme's on-surface-variant color is used.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Text(
      label,
      style: textTheme.labelSmall?.copyWith(
        color: color ?? colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
