/// Shared per-signer weight input row.
///
/// Used in both the weighted-threshold add form (create-path) and the
/// edit policy params form (read-only read-back). The left-hand [identity]
/// widget is supplied by the caller so each site can render a
/// [SignerIdentityChip] without coupling this widget to either's context.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A row that pairs an identity widget on the left with a weight [TextField]
/// on the right.
///
/// [identity] is typically a [SignerIdentityChip]. [controller] drives the
/// text field. [enabled] controls whether the field is interactive.
/// [onChanged] is invoked on every keystroke when provided.
/// [semanticIdentity] is the accessibility label for the text field
/// (e.g. `'Passkey key:abcd1234...'`).
class WeightInputRow extends StatelessWidget {
  /// Constructs a weight-input row.
  const WeightInputRow({
    required this.identity,
    required this.controller,
    required this.enabled,
    required this.semanticIdentity,
    this.onChanged,
    super.key,
  });

  /// Widget rendered on the left side (typically a [SignerIdentityChip]).
  final Widget identity;

  /// Controller backing the weight [TextField].
  final TextEditingController controller;

  /// Whether the text field is interactive.
  final bool enabled;

  /// Accessibility label for the weight text field.
  ///
  /// Should uniquely identify the signer this row represents so assistive
  /// technology can announce it without ambiguity.
  final String semanticIdentity;

  /// Called on every keystroke. When null, no callback is fired.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: identity),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: Semantics(
              label: 'Weight for $semanticIdentity',
              textField: true,
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                enabled: enabled,
                onChanged: onChanged,
                decoration: const InputDecoration(
                  labelText: 'Weight',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
