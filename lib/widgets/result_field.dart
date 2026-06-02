/// A label + monospace value field with tap-to-copy behaviour.
library;

import 'package:flutter/material.dart';

import '../util/clipboard.dart';

// ---------------------------------------------------------------------------
// ResultField
// ---------------------------------------------------------------------------

/// Displays a labelled field with a monospace value that the user can tap to
/// copy to the clipboard.
///
/// Layout:
/// - Small label in [Theme.of(context).textTheme.labelSmall].
/// - Monospace value text, full width, tappable.
/// - "Tap to copy" hint below the value.
///
/// On tap, the [value] is written to the clipboard and a "Copied" snackbar
/// is shown via [ScaffoldMessenger].
///
/// Accessibility:
/// When [semanticValue] is provided it is used in the Semantics label instead
/// of [value]. Pass a redacted form (e.g. first-8…last-8 truncation) for long
/// opaque identifiers such as credential IDs so assistive technology does not
/// read out the full string. The copy action always writes the unredacted
/// [value] to the clipboard regardless of [semanticValue].
class ResultField extends StatelessWidget {
  /// Creates a [ResultField].
  const ResultField({
    required this.label,
    required this.value,
    this.semanticValue,
    super.key,
  });

  /// Field name shown above the value.
  final String label;

  /// Field content written to the clipboard on tap.
  final String value;

  /// Optional override for the assistive-technology semantic label.
  ///
  /// When non-null, the Semantics node reads "$label: $semanticValue" instead
  /// of "$label: $value". Use a redacted form for long opaque identifiers to
  /// prevent screen readers from reading credential IDs or contract addresses
  /// in full. The [value] shown on screen and written to the clipboard is
  /// unaffected.
  final String? semanticValue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final readableValue = semanticValue ?? value;

    return Semantics(
      label: '$label: $readableValue',
      hint: 'Tap to copy',
      button: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => _copy(context),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Tap to copy',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withAlpha(160),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) => copyAndToast(context, value);
}
