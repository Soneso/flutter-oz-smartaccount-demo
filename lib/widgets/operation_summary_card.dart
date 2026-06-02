/// Edit-mode "Pending changes" summary card.
///
/// Renders a compact summary derived from a [ContextRuleEditDiff]: a
/// comma-separated list of pending change categories and the total number
/// of passkey prompts the user can expect when they apply the diff. The
/// card collapses to a single "No changes to apply" message when the diff
/// is empty.
library;

import 'package:flutter/material.dart';

import '../flows/context_rule_edit_types.dart';

// ---------------------------------------------------------------------------
// OperationSummaryCard
// ---------------------------------------------------------------------------

/// Edit-mode operation summary card.
class OperationSummaryCard extends StatelessWidget {
  /// Creates an operation summary card backed by [diff].
  const OperationSummaryCard({required this.diff, super.key});

  /// The diff to summarise.
  final ContextRuleEditDiff diff;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final String headerText;
    String? subText;

    if (diff.isEmpty) {
      headerText = 'No changes to apply';
    } else {
      final parts = formatDiffParts(diff);
      headerText = 'Pending changes: ${parts.join(', ')}';
      final ops = diff.totalOperations;
      subText = '$ops passkey prompt(s) required';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              headerText,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (subText != null) ...[
              const SizedBox(height: 4),
              Text(
                subText,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Returns the comma-separated change descriptors for [diff], in the
/// canonical order expected by the summary header.
List<String> formatDiffParts(ContextRuleEditDiff diff) {
  final parts = <String>[];
  if (diff.nameChanged) parts.add('name update');
  if (diff.newSigners.isNotEmpty) {
    parts.add('${diff.newSigners.length} signer add(s)');
  }
  if (diff.removedSigners.isNotEmpty) {
    parts.add('${diff.removedSigners.length} signer remove(s)');
  }
  if (diff.newPolicies.isNotEmpty) {
    parts.add('${diff.newPolicies.length} policy add(s)');
  }
  if (diff.removedPolicies.isNotEmpty) {
    parts.add('${diff.removedPolicies.length} policy remove(s)');
  }
  if (diff.modifiedPolicies.isNotEmpty) {
    parts.add('${diff.modifiedPolicies.length} policy update(s)');
  }
  if (diff.expiryChanged) parts.add('expiry update');
  return parts;
}
