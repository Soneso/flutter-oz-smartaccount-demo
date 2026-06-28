/// Shared copyable transaction-hash row.
///
/// Renders a monospace hash text truncated to one line alongside a "Copy"
/// button. Tapping the button writes the full hash to the clipboard and
/// shows a snackbar.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../util/clipboard.dart';

/// A row that displays a truncated [hash] alongside a [Copy] button.
///
/// [hash] is the full transaction hash string. [color] is the foreground color
/// for both the hash text and the button outline. [snackbarMessage] is the
/// text displayed in the clipboard confirmation snackbar (default:
/// `'Transaction hash copied'`). [semanticValue] overrides the accessibility
/// value of the hash text field (defaults to [hash]).
class CopyableHashRow extends StatelessWidget {
  /// Constructs a copyable hash row.
  const CopyableHashRow({
    required this.hash,
    this.displayText,
    this.color,
    this.snackbarMessage = 'Transaction hash copied',
    this.semanticValue,
    super.key,
  });

  /// The full transaction hash. Always written to the clipboard on copy.
  final String hash;

  /// Text shown in the row. Defaults to [hash] (the full value); supply a
  /// shortened form to display a truncated hash while still copying the
  /// full [hash].
  final String? displayText;

  /// Foreground color for the hash text and button outline.
  ///
  /// When null the surrounding theme's default foreground color is used.
  final Color? color;

  /// Snackbar message shown after copying.
  final String snackbarMessage;

  /// Accessibility value for the hash text. Defaults to [hash].
  final String? semanticValue;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              displayText ?? hash,
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Copy transaction hash',
            value: semanticValue ?? hash,
            excludeSemantics: true,
            child: OutlinedButton(
              onPressed: () {
                unawaited(copyAndToast(
                  context,
                  hash,
                  message: snackbarMessage,
                  announce: true,
                ));
              },
              style: color != null
                  ? OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide(color: color!.withAlpha(80)),
                      foregroundColor: color,
                    )
                  : null,
              child: const Text(
                'Copy',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
