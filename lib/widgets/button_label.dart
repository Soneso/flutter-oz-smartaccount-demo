/// Shrink-to-fit text for button children.
library;

import 'package:flutter/material.dart';

/// Drop-in replacement for [Text] inside a button's `child:` slot.
///
/// Wraps the label in [FittedBox] with [BoxFit.scaleDown] so a long string
/// shrinks to a single line on narrow buttons instead of wrapping mid-button
/// and rendering vertically displaced. On wide enough buttons the label
/// renders at its natural size; [FittedBox.scaleDown] only ever scales DOWN.
///
/// Use this anywhere a button's parent constrains its width (typically
/// [Expanded] inside a [Row], or a fixed-height side-by-side navigation grid)
/// and where the label can be longer than `Cancel` / `OK`.
class ButtonLabel extends StatelessWidget {
  /// Creates a [ButtonLabel] with the given [text].
  const ButtonLabel(
    this.text, {
    this.style,
    this.textAlign,
    super.key,
  });

  /// The label text.
  final String text;

  /// Optional text style. When null the button's ambient
  /// [DefaultTextStyle] is used.
  final TextStyle? style;

  /// Optional text alignment. When null the surrounding button decides
  /// alignment (Material buttons centre their child by default).
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, style: style, textAlign: textAlign),
    );
  }
}
