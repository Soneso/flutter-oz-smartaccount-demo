/// Expandable card displaying a single context rule.
///
/// Shows the rule ID badge, name, context-type badge, signer/policy count
/// badges, optional expiry badge, and an expand/collapse toggle. When
/// expanded, full signers and policies sections are displayed.
///
/// Accessibility:
/// - The expand/collapse icon-button announces its action via a semantic label.
/// - Signer and policy section headers use [Semantics(header: true)].
/// - Inline "[data unavailable]" placeholders are readable by screen readers.
library;

import 'package:flutter/material.dart';

import '../flows/context_rule_builder_types.dart'
    show OZSmartAccountSigner, ParsedContextRule;
import '../util/context_rule_format.dart';
import '../util/format_utils.dart';
import '../util/semantic_colors.dart';
import 'loading_label.dart';
import 'pill.dart';

// ---------------------------------------------------------------------------
// ContextRuleCard
// ---------------------------------------------------------------------------

/// Expandable card for a single [ParsedContextRule].
///
/// [isExpanded] and [onToggleExpanded] let the parent control the expanded
/// state so only one card is open at a time (if desired). Pass [onRemove] as
/// null to hide the remove button entirely.
///
/// [canRemove] must be false when this is the last rule on the account; when
/// false the button label changes to "Last Rule" and is disabled.
///
/// [onEdit] adds an "Edit Rule" button alongside the remove button when
/// non-null. Both buttons appear inside the expanded detail view.
class ContextRuleCard extends StatelessWidget {
  /// Creates a [ContextRuleCard].
  const ContextRuleCard({
    required this.rule,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.canRemove,
    required this.isRemoving,
    this.onRemove,
    this.onEdit,
    super.key,
  });

  /// The rule to display.
  final ParsedContextRule rule;

  /// Whether the card is currently expanded to show signer/policy details.
  final bool isExpanded;

  /// Called when the user taps the expand/collapse icon.
  final VoidCallback onToggleExpanded;

  /// True when this rule can be removed (i.e. it is not the last rule).
  final bool canRemove;

  /// True while a removal operation is in progress for this rule.
  final bool isRemoving;

  /// Called when the user taps [Remove Rule]. Null hides the button.
  final VoidCallback? onRemove;

  /// Called when the user taps [Edit Rule]. Null hides the button.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ----- Header row -----
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 0),
            child: Row(
              children: [
                // ID badge
                Pill(
                  label: '#${rule.id}',
                  background: colorScheme.primaryContainer,
                  foreground: colorScheme.onPrimaryContainer,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  textStyle: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onPrimaryContainer,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                // Rule name
                Expanded(
                  child: Text(
                    rule.name.isEmpty ? 'Unnamed Rule' : rule.name,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                // Expand/collapse button
                Semantics(
                  label: isExpanded ? 'Collapse' : 'Expand',
                  button: true,
                  excludeSemantics: true,
                  child: IconButton(
                    icon: Icon(
                      isExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    onPressed: onToggleExpanded,
                  ),
                ),
              ],
            ),
          ),

          // ----- Context type + summary badges -----
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                Pill(
                  label: formatContextType(rule.contextType),
                  background: colorScheme.secondaryContainer,
                  foreground: colorScheme.onSecondaryContainer,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                ),
                Semantics(
                  label:
                      'Signers: ${signerCountLabel(rule.signers.length)}',
                  excludeSemantics: true,
                  child: Pill(
                    label: signerCountLabel(rule.signers.length),
                    background: colorScheme.signerBadgeBackground,
                    foreground: colorScheme.signerBadgeForeground,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                ),
                Semantics(
                  label:
                      'Policies: ${policyCountLabel(rule.policies.length)}',
                  excludeSemantics: true,
                  child: Pill(
                    label: policyCountLabel(rule.policies.length),
                    background: colorScheme.policyBadgeBackground,
                    foreground: colorScheme.policyBadgeForeground,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                ),
                if (rule.validUntil != null)
                  Semantics(
                    label: 'Expires at ledger ${rule.validUntil}',
                    excludeSemantics: true,
                    child: Pill(
                      label: 'Expires: ledger ${rule.validUntil}',
                      background: colorScheme.expiryBadgeBackground,
                      foreground: colorScheme.expiryBadgeForeground,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      borderRadius:
                          const BorderRadius.all(Radius.circular(12)),
                    ),
                  ),
              ],
            ),
          ),

          // ----- Expanded content -----
          if (isExpanded) ...[
            const SizedBox(height: 10),
            Divider(
              height: 1,
              color: colorScheme.outlineVariant,
              indent: 14,
              endIndent: 14,
            ),
            const SizedBox(height: 10),

            // Signers section
            _SignersSection(
              signers: rule.signers,
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),

            // Policies section
            _PoliciesSection(
              policies: rule.policies,
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
          ],

          // ----- Remove / Last Rule button -----
          //
          // Render the action row in any of these cases:
          //   - a remove callback is wired (interactive),
          //   - the rule is the last on the account (renders the disabled
          //     "Last Rule" badge so users understand the constraint),
          //   - a removal is in flight (renders the spinner / "Removing..."
          //     label even though the callback has been cleared by the
          //     parent for the duration of the operation).
          if (onRemove != null || onEdit != null || !canRemove || isRemoving) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Row(
                children: [
                  if (onEdit != null) ...[
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: 'Edit Rule',
                        hint: 'Open the rule editor for rule #${rule.id}',
                        excludeSemantics: true,
                        child: OutlinedButton(
                          onPressed: isRemoving ? null : onEdit,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          child: const Text('Edit Rule'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: _RemoveButton(
                      canRemove: canRemove,
                      isRemoving: isRemoving,
                      onRemove: onRemove,
                      colorScheme: colorScheme,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SignersSection
// ---------------------------------------------------------------------------

class _SignersSection extends StatelessWidget {
  const _SignersSection({
    required this.signers,
    required this.colorScheme,
    required this.textTheme,
  });

  final List<OZSmartAccountSigner> signers;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Signers',
              style: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (signers.isEmpty)
            Text(
              'No signers (policy-only rule)',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            )
          else
            ...signers.map((s) => _SignerChip(
                  signer: s,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                )),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SignerChip
// ---------------------------------------------------------------------------

class _SignerChip extends StatelessWidget {
  const _SignerChip({
    required this.signer,
    required this.colorScheme,
    required this.textTheme,
  });

  final OZSmartAccountSigner signer;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    SignerDisplayInfo info;
    try {
      info = formatSignerForDisplay(signer);
    } catch (_) {
      info = const SignerDisplayInfo(
        typeLabel: 'Unknown',
        displayValue: '[Signer data unavailable]',
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        label: '${info.typeLabel} signer: ${info.displayValue}',
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Pill(
              label: info.typeLabel,
              background: colorScheme.primaryContainer,
              foreground: colorScheme.onPrimaryContainer,
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              textStyle: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                info.displayValue,
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _PoliciesSection
// ---------------------------------------------------------------------------

class _PoliciesSection extends StatelessWidget {
  const _PoliciesSection({
    required this.policies,
    required this.colorScheme,
    required this.textTheme,
  });

  final List<String> policies;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Policies',
              style: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (policies.isEmpty)
            Text(
              'No policies (signer-only rule)',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            )
          else
            ...policies.map((addr) => _PolicyChip(
                  address: addr,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                )),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _PolicyChip
// ---------------------------------------------------------------------------

class _PolicyChip extends StatelessWidget {
  const _PolicyChip({
    required this.address,
    required this.colorScheme,
    required this.textTheme,
  });

  final String address;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final truncated = truncateContractId(address);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        label: 'Policy contract: $truncated',
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colorScheme.policyChipBackground,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'P',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: colorScheme.policyChipForeground,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                truncated,
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _RemoveButton
// ---------------------------------------------------------------------------

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({
    required this.canRemove,
    required this.isRemoving,
    required this.onRemove,
    required this.colorScheme,
  });

  final bool canRemove;
  final bool isRemoving;
  final VoidCallback? onRemove;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final label = canRemove ? 'Remove Rule' : 'Last Rule';
    final enabled = canRemove && !isRemoving && onRemove != null;

    return Semantics(
      button: true,
      label: label,
      hint: canRemove
          ? null
          : 'Cannot remove the last context rule',
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: enabled ? onRemove : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: canRemove ? colorScheme.error : null,
            side: BorderSide(
              color: canRemove
                  ? colorScheme.error.withAlpha(180)
                  : colorScheme.outlineVariant,
            ),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
          child: isRemoving
              ? LoadingLabel(
                  label: 'Removing...',
                  color: colorScheme.error,
                  size: 14,
                  textStyle: TextStyle(
                    fontSize: 13,
                    color: colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: canRemove
                        ? colorScheme.error
                        : colorScheme.onSurface.withAlpha(100),
                  ),
                ),
        ),
      ),
    );
  }
}
