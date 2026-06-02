/// Shared error-tinted card used to surface a recoverable error at the top
/// of a section or below a form.
library;

import 'package:flutter/material.dart';

import '../theme/spacing.dart';
import '../util/semantic_colors.dart';
import 'loading_label.dart';

/// A card with an error-container tint, an error icon, the [message] body,
/// and an optional retry action.
///
/// When [onAction] is provided the card renders a retry button that disables
/// itself and shows an inline spinner while [onAction] is running, so users
/// cannot fire the recovery action twice.
class ErrorCard extends StatefulWidget {
  const ErrorCard({
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  }) : assert(
          (actionLabel == null) == (onAction == null),
          'actionLabel and onAction must be provided together',
        );

  final String message;

  /// Label for the optional retry button rendered below the message.
  final String? actionLabel;

  /// Async callback invoked when the retry button is pressed.
  ///
  /// While the returned [Future] is in flight the button is disabled and
  /// shows an inline spinner alongside [actionLabel].
  final Future<void> Function()? onAction;

  @override
  State<ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<ErrorCard> {
  bool _isRetrying = false;

  Future<void> _handleRetry() async {
    if (_isRetrying) return;
    setState(() => _isRetrying = true);
    try {
      await widget.onAction!.call();
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      enabled: true,
      child: Card(
        elevation: 0,
        color: colorScheme.errorContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.errorBorder),
        ),
        child: Padding(
          padding: kCardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline,
                    color: colorScheme.onErrorContainer,
                    size: 18,
                    semanticLabel: '',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      widget.message,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.onAction != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    onPressed: _isRetrying ? null : _handleRetry,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colorScheme.onErrorContainer,
                      side: BorderSide(color: colorScheme.errorBorder),
                    ),
                    child: _isRetrying
                        ? LoadingLabel(
                            label: widget.actionLabel!,
                            color: colorScheme.onErrorContainer,
                            size: 14,
                          )
                        : Text(widget.actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
