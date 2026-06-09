/// Shared helpers for the policy add-form widgets.
///
/// [handlePolicyAddEpilogue] is the common post-validation dispatch used by
/// [ThresholdAddForm], [WeightedThresholdAddForm], and [SpendingLimitAddForm].
///
/// [PolicyContractRow] renders the "Contract: ABCD...EFGH" line shown above
/// each policy add form.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../flows/context_rule_builder_types.dart' show StagedPolicy;
import '../../util/format_utils.dart' show truncateAddress;

/// Shared success epilogue for policy add-forms.
///
/// Calls [onAddPolicy] with [staged]. When it returns an error string,
/// [onSetError] is called with that string and the function returns. When it
/// returns null, the accessibility announcement is made and [onAddSucceeded]
/// is called.
///
/// Used by [ThresholdAddForm], [WeightedThresholdAddForm], and
/// [SpendingLimitAddForm] to share identical post-validation dispatch logic
/// without duplicating it in each form's `_onAdd` handler.
void handlePolicyAddEpilogue({
  required BuildContext context,
  required StagedPolicy staged,
  required String policyName,
  required String? Function(StagedPolicy) onAddPolicy,
  required void Function(String) onSetError,
  required VoidCallback onAddSucceeded,
}) {
  final addError = onAddPolicy(staged);
  if (addError != null) {
    onSetError(addError);
    return;
  }
  SemanticsService.announce(
    'Added $policyName policy',
    Directionality.of(context),
  );
  onAddSucceeded();
}

/// Single-line "Contract: ABCD...EFGH" row shown above each policy add
/// form. Extracted so all three forms can share the same rendering
/// without re-declaring the helper in each file.
class PolicyContractRow extends StatelessWidget {
  /// Constructs the contract-address row.
  const PolicyContractRow({
    required this.address,
    required this.colorScheme,
    required this.textTheme,
    super.key,
  });

  /// Policy contract C-address shown truncated.
  final String address;

  /// Theme colour scheme passed in by the caller.
  final ColorScheme colorScheme;

  /// Theme text theme passed in by the caller.
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Contract: ${truncateAddress(address, chars: 8)}',
      style: textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
