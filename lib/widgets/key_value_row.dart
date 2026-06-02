/// Two-column label/value row used inside review and confirmation surfaces.
library;

import 'package:flutter/material.dart';

/// A single labelled row rendered as a fixed-width label column on the left
/// and a flexible value column on the right.
///
/// The [value] slot accepts an arbitrary [Widget] so callers can render
/// plain text, a chip, an inline icon row, or any other element. For the
/// common case of a selectable text value matching the canonical label /
/// value styling, use the [KeyValueRow.text] convenience constructor.
///
/// Visual contract:
/// - Label column is fixed at [labelWidth] (default `110`) and styled as
///   `labelSmall` with letter-spacing `0.4`, [FontWeight.w600], and the
///   surface-variant foreground.
/// - The value column is wrapped in [Expanded] so it shares whatever
///   horizontal space remains in the row's parent.
/// - Wraps in a [Semantics] node when used via [KeyValueRow.text] so screen
///   readers announce the pair as `"$label: $value"` instead of two
///   separate fragments.
class KeyValueRow extends StatelessWidget {
  /// Creates a [KeyValueRow] with a custom [value] widget.
  const KeyValueRow({
    required this.label,
    required this.value,
    this.labelWidth = 110,
    this.semanticsLabel,
    super.key,
  })  : _textValue = null,
        _monospace = false,
        _emphasised = false;

  /// Creates a [KeyValueRow] with a [SelectableText] value column.
  ///
  /// When [monospace] is true the value text uses the `monospace` font
  /// family, suited to addresses, hashes, and other opaque identifiers.
  /// When [emphasised] is true the value is rendered with [TextTheme.bodyMedium]
  /// + [FontWeight.w700] and uses tabular figures for clean numeric
  /// alignment — used for highlighted lines such as transfer amounts.
  const KeyValueRow.text({
    required this.label,
    required String value,
    this.labelWidth = 110,
    bool monospace = false,
    bool emphasised = false,
    super.key,
  })  : _textValue = value,
        _monospace = monospace,
        _emphasised = emphasised,
        value = const SizedBox.shrink(),
        semanticsLabel = null;

  /// Label text rendered in the fixed-width left column.
  final String label;

  /// Right-hand value widget. Ignored when [KeyValueRow.text] is used.
  final Widget value;

  /// Width of the fixed label column in logical pixels.
  final double labelWidth;

  /// Optional override for the row's semantics label. When null, falls back
  /// to `"$label: $value"` for the [KeyValueRow.text] constructor and to
  /// the inherited semantics of [value] otherwise.
  final String? semanticsLabel;

  final String? _textValue;
  final bool _monospace;
  final bool _emphasised;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final labelWidget = SizedBox(
      width: labelWidth,
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );

    final Widget valueWidget;
    final String? effectiveSemanticsLabel;
    if (_textValue != null) {
      final valueStyle =
          (_emphasised ? textTheme.bodyMedium : textTheme.bodySmall)?.copyWith(
        color: colorScheme.onSurface,
        fontWeight: _emphasised ? FontWeight.w700 : FontWeight.w500,
        fontFamily: _monospace ? 'monospace' : null,
        fontFeatures:
            _emphasised ? const [FontFeature.tabularFigures()] : null,
      );
      valueWidget = Expanded(
        child: SelectableText(_textValue, style: valueStyle),
      );
      effectiveSemanticsLabel = semanticsLabel ?? '$label: $_textValue';
    } else {
      valueWidget = value;
      effectiveSemanticsLabel = semanticsLabel;
    }

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [labelWidget, valueWidget],
      ),
    );

    if (effectiveSemanticsLabel == null) {
      return row;
    }
    return Semantics(
      label: effectiveSemanticsLabel,
      excludeSemantics: true,
      child: row,
    );
  }
}
