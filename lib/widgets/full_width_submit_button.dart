/// Full-width submit button for add-forms.
library;

import 'package:flutter/material.dart';

/// A full-width [FilledButton] with a consistent 12 dp vertical padding,
/// used by the policy and signer add-form submit actions.
///
/// [label] is the button text. [enabled] controls whether the button is
/// interactive; when false the button is rendered in its disabled state.
/// [onPressed] is called when the user taps the enabled button.
class FullWidthSubmitButton extends StatelessWidget {
  /// Creates a full-width submit button.
  const FullWidthSubmitButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
    super.key,
  });

  /// Button label text.
  final String label;

  /// Whether the button is interactive.
  final bool enabled;

  /// Callback invoked when the button is tapped.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: Text(label),
      ),
    );
  }
}
