/// Compact chip/badge container shared across the demo's inline labels.
library;

import 'package:flutter/material.dart';

import '../theme/spacing.dart' show kChipRadius;

/// Compact chip/badge container for inline counts, kinds, and statuses.
///
/// Use this in place of inline `Container(padding, decoration: BoxDecoration(...))`
/// patterns so every chip in the UI shares the same radius / padding tokens.
///
/// Defaults:
/// - Padding: `horizontal 8, vertical 2`. Override at the call site for any
///   chip that needs more breathing room.
/// - Radius: [kChipRadius] (8 dp).
/// - Text style: `Theme.of(context).textTheme.labelSmall` with [foreground]
///   colour and [FontWeight.w600]. Callers can override the entire style via
///   [textStyle].
///
/// [icon], when supplied, renders to the left of [label] at [iconSize] and
/// in [foreground] colour.
class Pill extends StatelessWidget {
  /// Creates a [Pill].
  const Pill({
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    this.borderRadius = const BorderRadius.all(kChipRadius),
    this.border,
    this.textStyle,
    this.iconSize = 12,
    super.key,
  });

  /// Text rendered inside the pill.
  final String label;

  /// Fill colour for the pill background.
  final Color background;

  /// Foreground colour for [label] and (when present) [icon].
  final Color foreground;

  /// Optional leading icon rendered to the left of [label].
  final IconData? icon;

  /// Internal padding around the label / icon row.
  final EdgeInsetsGeometry padding;

  /// Corner radius for the pill background.
  final BorderRadiusGeometry borderRadius;

  /// Optional border drawn around the pill.
  final BoxBorder? border;

  /// Optional override for the label's text style. When null the style
  /// resolves to `labelSmall.copyWith(color: foreground, fontWeight: w600)`.
  final TextStyle? textStyle;

  /// Edge size of the leading icon when [icon] is supplied.
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final resolvedTextStyle = textStyle ??
        Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            );

    final Widget labelWidget = Text(label, style: resolvedTextStyle);

    final Widget content;
    if (icon == null) {
      content = labelWidget;
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: foreground),
          const SizedBox(width: 4),
          labelWidget,
        ],
      );
    }

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: borderRadius,
        border: border,
      ),
      child: content,
    );
  }
}
