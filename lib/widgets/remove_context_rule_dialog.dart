/// Confirmation dialog for context-rule removal.
///
/// Displays the rule ID and name, warns that the action requires smart account
/// authorization, and disables the [Remove] button when the rule is the last
/// one on the account (last-rule safety check).
///
/// Accessibility:
/// - Dialog title uses the default AlertDialog semantics (role=dialog).
/// - The [Remove] button announces its disabled hint when [canRemove] is false.
library;

import 'package:flutter/material.dart';

import '../flows/context_rule_builder_types.dart' show OZParsedContextRule;

// ---------------------------------------------------------------------------
// RemoveContextRuleDialog
// ---------------------------------------------------------------------------

/// Modal dialog that asks the user to confirm removing a context rule.
///
/// Call [RemoveContextRuleDialog.show] to display it and await the result.
/// Returns true when the user confirms, false or null otherwise.
class RemoveContextRuleDialog extends StatelessWidget {
  /// Creates a [RemoveContextRuleDialog].
  const RemoveContextRuleDialog({
    required this.rule,
    required this.canRemove,
    super.key,
  });

  /// The rule the user wants to remove.
  final OZParsedContextRule rule;

  /// When false, the [Remove] button is replaced with a disabled "Last Rule"
  /// button so the user understands they cannot remove the final rule.
  final bool canRemove;

  /// Shows the dialog and returns true when the user confirms, false/null on
  /// cancel or dismiss.
  static Future<bool> show({
    required BuildContext context,
    required OZParsedContextRule rule,
    required bool canRemove,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => RemoveContextRuleDialog(
        rule: rule,
        canRemove: canRemove,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final ruleName = rule.name.isEmpty ? 'Unnamed Rule' : rule.name;
    final message =
        'Remove rule #${rule.id} "$ruleName"? This action requires smart '
        'account authorization and cannot be undone.';

    return AlertDialog(
      title: const Text('Remove Context Rule'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        Semantics(
          button: true,
          label: canRemove ? 'Remove' : 'Last Rule',
          hint: canRemove ? null : 'Cannot remove the last context rule',
          child: FilledButton(
            onPressed: canRemove ? () => Navigator.of(context).pop(true) : null,
            style: FilledButton.styleFrom(
              backgroundColor:
                  canRemove ? colorScheme.error : colorScheme.error.withAlpha(80),
              foregroundColor: colorScheme.onError,
              disabledBackgroundColor: colorScheme.error.withAlpha(80),
              disabledForegroundColor: colorScheme.onError.withAlpha(180),
            ),
            child: Text(canRemove ? 'Remove' : 'Last Rule'),
          ),
        ),
      ],
    );
  }
}
