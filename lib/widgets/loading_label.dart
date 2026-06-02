/// Compact spinner + text content for buttons and loading rows.
library;

import 'package:flutter/material.dart';

/// Compact spinner + text content for buttons and loading rows.
///
/// Drop into any button's `child:` (or any inline progress affordance)
/// to render a small [CircularProgressIndicator] alongside [label]. Does
/// not own a background — the surrounding button or row provides it.
///
/// When [color] is null the spinner inherits its colour from the
/// surrounding [DefaultTextStyle], which lets it pick up the enclosing
/// button's foreground colour without any explicit wiring.
class LoadingLabel extends StatelessWidget {
  /// Creates a [LoadingLabel].
  const LoadingLabel({
    required this.label,
    this.color,
    this.size = 16,
    this.strokeWidth = 2,
    this.gap = 8,
    this.textStyle,
    super.key,
  });

  /// Text rendered to the right of the spinner.
  final String label;

  /// Spinner colour. When null, falls back to the surrounding
  /// [DefaultTextStyle]'s colour so it picks up the button's foreground.
  final Color? color;

  /// Spinner square edge size in logical pixels.
  final double size;

  /// Spinner stroke width.
  final double strokeWidth;

  /// Horizontal gap between the spinner and [label].
  final double gap;

  /// Optional text style override for [label].
  ///
  /// When null the label inherits the ambient [DefaultTextStyle], which is
  /// what every button-shaped container provides.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final spinnerColor = color ?? DefaultTextStyle.of(context).style.color;
    final labelWidget =
        textStyle == null ? Text(label) : Text(label, style: textStyle);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            strokeWidth: strokeWidth,
            color: spinnerColor,
          ),
        ),
        SizedBox(width: gap),
        // Flexible + ellipsis so a long loadingLabel can never push the
        // spinner off-center or wrap to a second line inside the host
        // button; only the text shrinks, the spinner stays fixed.
        Flexible(
          child: DefaultTextStyle.merge(
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            softWrap: false,
            child: labelWidget,
          ),
        ),
      ],
    );
  }
}
