/// A primary button that shows an inline spinner while an async action runs.
library;

import 'package:flutter/material.dart';

import 'button_label.dart';

import 'loading_label.dart';

// ---------------------------------------------------------------------------
// LoadingButtonStyle
// ---------------------------------------------------------------------------

/// Visual style for a [LoadingButton].
enum LoadingButtonStyle {
  /// Standard filled primary button. Use for positive actions.
  primary,

  /// Red destructive button. Use for disconnect / delete actions.
  destructive,

  /// Outlined (unfilled) button. Use for secondary actions such as
  /// Disconnect placed inside a card that already has a strong background.
  outlined,
}

// ---------------------------------------------------------------------------
// LoadingButton
// ---------------------------------------------------------------------------

/// A Material 3 filled (or outlined) button that shows a
/// [CircularProgressIndicator] spinner and disables itself while an async
/// action is executing.
///
/// Behaviour:
/// - Tapping calls the provided [action] closure inside a [Future].
/// - While the future is running [loadingLabel] (if provided) or the spinner
///   alone is shown, and the button is disabled so accidental re-taps are
///   ignored.
/// - If the action throws, the error is forwarded to the optional [onError]
///   closure. When [onError] is null, thrown errors are silently discarded.
///
/// Accessibility:
/// - The semantics label reflects the loading state so screen-reader users
///   know when a network operation is in progress.
///
/// Usage:
/// ```dart
/// LoadingButton(
///   label: 'Disconnect',
///   style: LoadingButtonStyle.outlined,
///   action: () async => flow.disconnect(),
///   onError: (e) => activityLog.error('Disconnect failed: $e'),
/// )
/// ```
class LoadingButton extends StatefulWidget {
  /// Creates a [LoadingButton].
  const LoadingButton({
    required this.label,
    required this.action,
    this.loadingLabel,
    this.loadingProgress,
    this.disabledHint,
    this.style = LoadingButtonStyle.primary,
    this.enabled = true,
    this.isLoading = false,
    this.onError,
    super.key,
  });

  /// Text shown on the button in the idle state.
  final String label;

  /// Optional text shown inside the button while the action is in flight.
  ///
  /// When null the button shows only a spinner (no text) during loading.
  /// When provided, the text is displayed alongside the spinner so the user
  /// knows what operation is in progress (e.g. "Deploying...").
  final String? loadingLabel;

  /// Dynamic progress label that overrides [loadingLabel] while loading.
  ///
  /// When non-null and the button is in loading state, this value is shown
  /// instead of [loadingLabel]. Callers that drive progress messages through
  /// external state (e.g. an [onProgress] callback on a long-running flow)
  /// pass the latest message here via [setState]. When null, [loadingLabel]
  /// is used as the fallback. When both are null, only the spinner is shown.
  final String? loadingProgress;

  /// Accessibility hint announced by screen readers when the button is disabled.
  ///
  /// Use this to explain why the button is not interactive, e.g.
  /// "Form is incomplete. Enter recipient and amount." When null, no
  /// additional hint is announced in the disabled state.
  final String? disabledHint;

  /// Visual style.
  ///
  /// - [LoadingButtonStyle.primary]: standard filled primary button.
  /// - [LoadingButtonStyle.destructive]: red filled button for irreversible actions.
  /// - [LoadingButtonStyle.outlined]: unfilled outlined button for secondary
  ///   actions placed inside already-tinted containers.
  final LoadingButtonStyle style;

  /// Async action executed when the button is tapped.
  final Future<void> Function() action;

  /// Whether the button is interactive.
  ///
  /// When false the button is visually disabled and taps are rejected.
  /// This gates both the visual disabled-state AND tap rejection, unlike
  /// passing a no-op closure which still accepts the gesture.
  final bool enabled;

  /// External loading override.
  ///
  /// When true, the button shows its loading state (spinner + optional
  /// [loadingLabel]) and rejects taps, even if the internal action-driven
  /// loading flag is false. Use this when the screen runs follow-up async
  /// work after [action]'s returned Future has resolved, so the spinner
  /// stays visible across that gap.
  final bool isLoading;

  /// Called with any error thrown by [action].
  ///
  /// Always invoked on the widget's build context isolate (same event loop as
  /// the widget tree) so callers can safely call [Notifier] methods or call
  /// [setState] directly without an additional [Future.microtask] hop.
  final void Function(Object error)? onError;

  @override
  State<LoadingButton> createState() => _LoadingButtonState();
}

class _LoadingButtonState extends State<LoadingButton> {
  bool _isLoading = false;

  bool get _showLoading => _isLoading || widget.isLoading;

  Future<void> _handleTap() async {
    if (_showLoading || !widget.enabled) return;
    setState(() => _isLoading = true);
    try {
      await widget.action();
    } catch (e) {
      widget.onError?.call(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final effectiveLoadingLabel =
        (widget.loadingProgress ?? widget.loadingLabel);
    final semanticsLabel = _showLoading
        ? '${effectiveLoadingLabel ?? widget.label}, loading'
        : widget.label;

    final String? semanticsHint;
    if (_showLoading) {
      semanticsHint = 'Please wait.';
    } else if (!widget.enabled && widget.disabledHint != null) {
      semanticsHint = widget.disabledHint;
    } else {
      semanticsHint = null;
    }

    return Semantics(
      label: semanticsLabel,
      hint: semanticsHint,
      button: true,
      child: SizedBox(
        width: double.infinity,
        child: _buildButton(context, colorScheme),
      ),
    );
  }

  Widget _buildButton(BuildContext context, ColorScheme colorScheme) {
    final loadingContent = _buildLoadingContent(colorScheme);
    // [ButtonLabel] keeps the idle label on a single line: on narrow screens
    // (or when the caller passes a long label such as a multi-word action plus
    // a parenthesised count) the text shrinks to fit instead of wrapping
    // mid-button and rendering vertically displaced.
    final idleContent = ButtonLabel(
      widget.label,
      style: const TextStyle(fontWeight: FontWeight.w600),
    );
    // Null onPressed disables the button at the Material layer, rejecting taps.
    final VoidCallback? onPressed =
        (_showLoading || !widget.enabled) ? null : _handleTap;

    switch (widget.style) {
      case LoadingButtonStyle.outlined:
        return OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: BorderSide(color: colorScheme.outline),
          ),
          child: _showLoading ? loadingContent : idleContent,
        );
      case LoadingButtonStyle.destructive:
        return FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
            disabledBackgroundColor: colorScheme.error.withAlpha(180),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _showLoading ? loadingContent : idleContent,
        );
      case LoadingButtonStyle.primary:
        return FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            disabledBackgroundColor: colorScheme.primary.withAlpha(180),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _showLoading ? loadingContent : idleContent,
        );
    }
  }

  Widget _buildLoadingContent(ColorScheme colorScheme) {
    final loadingText = widget.loadingProgress ?? widget.loadingLabel;
    final spinnerColor = widget.style == LoadingButtonStyle.outlined
        ? colorScheme.primary
        : widget.style == LoadingButtonStyle.destructive
            ? colorScheme.onError
            : colorScheme.onPrimary;

    if (loadingText != null) {
      return LoadingLabel(
        label: loadingText,
        color: spinnerColor,
        size: 20,
        strokeWidth: 2.5,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      );
    }
    return SizedBox(
      height: 20,
      width: 20,
      child: CircularProgressIndicator(strokeWidth: 2.5, color: spinnerColor),
    );
  }
}
