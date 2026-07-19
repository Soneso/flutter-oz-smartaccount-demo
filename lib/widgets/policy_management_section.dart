/// Policy management subsection for the Context Rule Builder screen.
///
/// Renders the policies header, the list of staged policies, the policy
/// type dropdown, and the type-specific add forms (simple threshold,
/// spending limit, weighted threshold). All mutable state is owned by
/// the caller and threaded in via callbacks. The per-type add forms
/// each live in their own file under `policy_add_forms/` and own their
/// controllers and per-form error state.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../config/demo_config.dart' show PolicyInfo, knownPolicies;
import '../flows/context_rule_builder_types.dart';
import '../flows/context_rule_edit_types.dart';
import '../theme/spacing.dart';
import '../util/format_utils.dart';
import '../util/policy_type.dart';
import '../util/semantic_colors.dart';
import 'annotation_badge.dart';
import 'edit_policy_params_form.dart';
import 'field_error_text.dart';
import 'pill.dart';
import 'policy_add_forms/spending_limit_add_form.dart';
import 'policy_add_forms/threshold_add_form.dart';
import 'policy_add_forms/weighted_threshold_add_form.dart';
import 'rich_dropdown_item.dart';

// ---------------------------------------------------------------------------
// PolicyManagementSection
// ---------------------------------------------------------------------------

/// Renders the policies section of the Context Rule Builder.
class PolicyManagementSection extends StatefulWidget {
  /// Constructs a policy management section.
  const PolicyManagementSection({
    required this.policies,
    required this.signers,
    required this.fieldError,
    required this.isSubmitting,
    required this.maxPolicies,
    required this.spendingLimitDecimals,
    required this.onAddPolicy,
    required this.onRemovePolicy,
    this.spendingLimitDecimalsError,
    this.editEntries,
    this.onEditEntryUpdated,
    super.key,
  });

  /// The currently staged policies (create-mode source).
  final List<StagedPolicy> policies;

  /// The currently staged signers (read-only, used by the weighted-threshold
  /// form to render per-signer weight rows and validate weight totals).
  final List<StagedSigner> signers;

  /// Optional inline error banner.
  final String? fieldError;

  /// True while a submission is in flight; disables the add forms.
  final bool isSubmitting;

  /// Maximum number of policies permitted on a rule (OZ contract limit).
  final int maxPolicies;

  /// Decimal scale of the rule's guarded token, threaded into the
  /// spending-limit add form and the inline spending-limit edit form so an
  /// entered amount is converted to base units with the correct precision.
  final int spendingLimitDecimals;

  /// Non-null when the parent could not resolve the guarded token's decimals;
  /// disables the spending-limit Add button and surfaces the message.
  final String? spendingLimitDecimalsError;

  /// Called when the user successfully adds a new policy. Returns null on
  /// success or an error message string when the policy cannot be added.
  final String? Function(StagedPolicy policy) onAddPolicy;

  /// Called when the user taps the remove (X) button for a staged policy.
  /// In edit-mode the callback receives an adapter [StagedPolicy] that the
  /// screen converts back into its edit-mode model.
  final void Function(StagedPolicy policy) onRemovePolicy;

  /// When non-null, the section renders in edit-mode using these entries
  /// instead of the create-mode [policies] list. Edit-mode entries also
  /// expose inline parameter editing for `isOriginal` entries.
  final List<EditPolicyEntry>? editEntries;

  /// Called when the user edits the inline parameters of an existing
  /// on-chain policy entry. The new entry replaces the caller's reference.
  final void Function(EditPolicyEntry entry)? onEditEntryUpdated;

  @override
  State<PolicyManagementSection> createState() =>
      _PolicyManagementSectionState();
}

class _PolicyManagementSectionState extends State<PolicyManagementSection> {
  PolicyInfo? _selectedType;

  // Marks the staged-policy count caption so a user-initiated add can bring
  // the newly staged policy into view.
  final GlobalKey _captionKey = GlobalKey();

  /// Collapses the chooser after a successful add. Clearing [_selectedType]
  /// disposes the keyed form widget, so no explicit reset is required.
  void _onAddSucceeded() {
    setState(() {
      _selectedType = null;
    });
  }

  /// Announces a policy removal to assistive technology.
  void _announcePolicyRemoved() {
    SemanticsService.announce('Removed policy', Directionality.of(context));
  }

  /// Forwards a staged add to the caller and, on success, scrolls the count
  /// caption into view. Only user-initiated adds route through here, so
  /// edit-mode rule loading and post-failure reloads never move the viewport.
  String? _handleAddPolicy(StagedPolicy policy) {
    final error = widget.onAddPolicy(policy);
    if (error == null) _scrollCaptionIntoView();
    return error;
  }

  /// Brings the count caption into view after the add-driven rebuild has
  /// laid it out. No-op when the caption is not mounted.
  void _scrollCaptionIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _captionKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.5,
      );
    });
  }

  // ---- Build ----

  bool get _isEditMode => widget.editEntries != null;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final editEntries = widget.editEntries;
    final atCap = _isEditMode
        ? (editEntries!.length >= widget.maxPolicies)
        : (widget.policies.length >= widget.maxPolicies);

    final Set<String> addedAddresses = _isEditMode
        ? editEntries!.map((e) => e.address).toSet()
        : widget.policies.map((p) => p.address).toSet();
    final available =
        knownPolicies.where((p) => !addedAddresses.contains(p.address)).toList(
              growable: false,
            );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PoliciesHeaderCard(
          colorScheme: colorScheme,
          textTheme: textTheme,
          maxPolicies: widget.maxPolicies,
          fieldError: widget.fieldError,
          isEditMode: _isEditMode,
        ),
        const SizedBox(height: 12),
        if (_isEditMode)
          _EditPoliciesList(
            entries: editEntries!,
            colorScheme: colorScheme,
            textTheme: textTheme,
            isSubmitting: widget.isSubmitting,
            spendingLimitDecimals: widget.spendingLimitDecimals,
            onRemove: (entry) {
              widget.onRemovePolicy(_adaptEditEntry(entry));
              _announcePolicyRemoved();
            },
            onEntryUpdated: widget.onEditEntryUpdated ?? (_) {},
          )
        else
          _PoliciesList(
            policies: widget.policies,
            colorScheme: colorScheme,
            textTheme: textTheme,
            isSubmitting: widget.isSubmitting,
            onRemove: (policy) {
              widget.onRemovePolicy(policy);
              _announcePolicyRemoved();
            },
          ),
        if (_isEditMode
            ? editEntries!.isNotEmpty
            : widget.policies.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            key: _captionKey,
            _policyCount(_isEditMode
                ? editEntries!.length
                : widget.policies.length),
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (!atCap)
          _AddPolicyCard(
            colorScheme: colorScheme,
            textTheme: textTheme,
            available: available,
            selectedType: _selectedType,
            isSubmitting: widget.isSubmitting,
            onTypeChanged: (info) {
              setState(() {
                _selectedType = info;
              });
              // Switching policy type swaps to a new form widget — keyed
              // by the policy-type constant — so the previous form is
              // disposed along with its controllers and inline errors.
              // No explicit field-reset is required.
            },
            body: _buildTypeBody(colorScheme, textTheme),
          ),
      ],
    );
  }

  /// Converts an [EditPolicyEntry] removal back into the [StagedPolicy]
  /// shape so the screen's existing `onRemovePolicy` handler can dispatch
  /// uniformly.
  StagedPolicy _adaptEditEntry(EditPolicyEntry entry) {
    final info = entry.info ??
        PolicyInfo(
          type: PolicyType.unknown,
          name: 'Unknown',
          description: '',
          address: entry.address,
        );
    return StagedPolicy(
      info: info,
      label: entry.label,
      // This adapter feeds the removal handler only; install params are never
      // read on that path. A benign placeholder satisfies the required
      // non-null contract.
      installParams: const OZSimpleThresholdPolicyParams(threshold: 1),
    );
  }

  Widget _buildTypeBody(ColorScheme colorScheme, TextTheme textTheme) {
    final type = _selectedType;
    if (type == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Select a policy type above to configure parameters.',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    switch (type.type) {
      case PolicyType.threshold:
        // Keyed by policy type so each form gets a fresh instance on switch.
        return ThresholdAddForm(
          key: const ValueKey<String>(PolicyType.threshold),
          policy: type,
          signers: widget.signers,
          isSubmitting: widget.isSubmitting,
          onAddPolicy: _handleAddPolicy,
          onAddSucceeded: _onAddSucceeded,
        );
      case PolicyType.spendingLimit:
        return SpendingLimitAddForm(
          key: const ValueKey<String>(PolicyType.spendingLimit),
          policy: type,
          isSubmitting: widget.isSubmitting,
          decimals: widget.spendingLimitDecimals,
          decimalsError: widget.spendingLimitDecimalsError,
          onAddPolicy: _handleAddPolicy,
          onAddSucceeded: _onAddSucceeded,
        );
      case PolicyType.weightedThreshold:
        return WeightedThresholdAddForm(
          key: const ValueKey<String>(PolicyType.weightedThreshold),
          policy: type,
          signers: widget.signers,
          isSubmitting: widget.isSubmitting,
          onAddPolicy: _handleAddPolicy,
          onAddSucceeded: _onAddSucceeded,
        );
      default:
        return const SizedBox.shrink();
    }
  }

}

String _policyCount(int n) {
  return n == 1 ? '1 policy attached' : '$n policies attached';
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _PoliciesHeaderCard extends StatelessWidget {
  const _PoliciesHeaderCard({
    required this.colorScheme,
    required this.textTheme,
    required this.maxPolicies,
    required this.fieldError,
    this.isEditMode = false,
  });

  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final int maxPolicies;
  final String? fieldError;
  final bool isEditMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Policies',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Attach policies to constrain how operations are authorized. '
            'Policies are optional. Maximum $maxPolicies per rule.',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (isEditMode) ...[
            const SizedBox(height: 6),
            Text(
              'Each policy change requires a separate passkey authentication.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
              ),
            ),
          ],
          FieldErrorText(error: fieldError),
        ],
      ),
    );
  }
}

class _PoliciesList extends StatelessWidget {
  const _PoliciesList({
    required this.policies,
    required this.colorScheme,
    required this.textTheme,
    required this.isSubmitting,
    required this.onRemove,
  });

  final List<StagedPolicy> policies;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isSubmitting;
  final void Function(StagedPolicy policy) onRemove;

  @override
  Widget build(BuildContext context) {
    if (policies.isEmpty) {
      return Container(
        width: double.infinity,
        padding: kCardPadding,
        decoration: BoxDecoration(
          color: colorScheme.cardBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Text(
          'No policies attached. Policies are optional.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final p in policies) ...[
          _StagedPolicyRow(
            policy: p,
            colorScheme: colorScheme,
            textTheme: textTheme,
            isSubmitting: isSubmitting,
            onRemove: () => onRemove(p),
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _StagedPolicyRow extends StatelessWidget {
  const _StagedPolicyRow({
    required this.policy,
    required this.colorScheme,
    required this.textTheme,
    required this.isSubmitting,
    required this.onRemove,
  });

  final StagedPolicy policy;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isSubmitting;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final chipColor = _policyTypeColor(policy.info.type, colorScheme);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: chipColor.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  container: true,
                  label: '${policy.info.name} policy: ${policy.label}',
                  excludeSemantics: true,
                  child: Row(
                    children: [
                      Pill(
                        label: policy.info.name,
                        background: chipColor,
                        foreground: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          policy.label,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove policy',
                onPressed: isSubmitting ? null : onRemove,
                iconSize: 18,
                icon: Icon(Icons.close, color: colorScheme.error),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(
              truncateAddress(policy.address, chars: 8),
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddPolicyCard extends StatelessWidget {
  const _AddPolicyCard({
    required this.colorScheme,
    required this.textTheme,
    required this.available,
    required this.selectedType,
    required this.isSubmitting,
    required this.onTypeChanged,
    required this.body,
  });

  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final List<PolicyInfo> available;
  final PolicyInfo? selectedType;
  final bool isSubmitting;
  final ValueChanged<PolicyInfo?> onTypeChanged;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.cardBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Add Policy',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (available.isEmpty)
            Text(
              'All policy types already added',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            )
          else
            DropdownButtonFormField<PolicyInfo>(
              initialValue: selectedType,
              itemHeight: null,
              decoration: const InputDecoration(
                labelText: 'Policy Type',
                border: OutlineInputBorder(),
              ),
              selectedItemBuilder: (_) => [
                for (final info in available)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(info.name),
                  ),
              ],
              items: [
                for (final info in available)
                  DropdownMenuItem<PolicyInfo>(
                    value: info,
                    child: Semantics(
                      label: '${info.name}. ${info.description}',
                      excludeSemantics: true,
                      child: RichDropdownItem(
                        title: info.name,
                        subtitle: info.description,
                      ),
                    ),
                  ),
              ],
              onChanged: isSubmitting ? null : onTypeChanged,
            ),
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }
}

Color _policyTypeColor(String type, ColorScheme colorScheme) {
  switch (type) {
    case PolicyType.threshold:
      return colorScheme.tertiary;
    case PolicyType.spendingLimit:
      return colorScheme.primary;
    case PolicyType.weightedThreshold:
      return colorScheme.secondary;
    default:
      return colorScheme.outline;
  }
}

// ---------------------------------------------------------------------------
// Edit-mode policy list
// ---------------------------------------------------------------------------

class _EditPoliciesList extends StatelessWidget {
  const _EditPoliciesList({
    required this.entries,
    required this.colorScheme,
    required this.textTheme,
    required this.isSubmitting,
    required this.spendingLimitDecimals,
    required this.onRemove,
    required this.onEntryUpdated,
  });

  final List<EditPolicyEntry> entries;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isSubmitting;
  final int spendingLimitDecimals;
  final void Function(EditPolicyEntry entry) onRemove;
  final void Function(EditPolicyEntry entry) onEntryUpdated;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        width: double.infinity,
        padding: kCardPadding,
        decoration: BoxDecoration(
          color: colorScheme.cardBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Text(
          'No policies attached. Policies are optional.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final entry in entries) ...[
          _EditPolicyRow(
            entry: entry,
            colorScheme: colorScheme,
            textTheme: textTheme,
            isSubmitting: isSubmitting,
            spendingLimitDecimals: spendingLimitDecimals,
            onRemove: () => onRemove(entry),
            onEntryUpdated: onEntryUpdated,
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _EditPolicyRow extends StatelessWidget {
  const _EditPolicyRow({
    required this.entry,
    required this.colorScheme,
    required this.textTheme,
    required this.isSubmitting,
    required this.spendingLimitDecimals,
    required this.onRemove,
    required this.onEntryUpdated,
  });

  final EditPolicyEntry entry;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isSubmitting;
  final int spendingLimitDecimals;
  final VoidCallback onRemove;
  final void Function(EditPolicyEntry entry) onEntryUpdated;

  @override
  Widget build(BuildContext context) {
    final type = entry.info?.type ?? PolicyType.unknown;
    final chipColor = _policyTypeColor(type, colorScheme);
    final name = entry.info?.name ?? 'Unknown';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: chipColor.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  container: true,
                  label: '$name policy: ${entry.label}'
                      '${entry.isOriginal ? ', on-chain' : ''}'
                      '${entry.modified ? ', modified' : ''}',
                  excludeSemantics: true,
                  child: Row(
                    children: [
                      Pill(
                        label: name,
                        background: chipColor,
                        foreground: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          children: [
                            Text(
                              entry.label,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (entry.isOriginal)
                              AnnotationBadge(
                                label: AnnotationBadgeLabel.onChain,
                                color: colorScheme.onChainBadgeForeground,
                              ),
                            if (entry.modified)
                              AnnotationBadge(
                                label: AnnotationBadgeLabel.modified,
                                color: colorScheme.modifiedBadgeForeground,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove policy',
                onPressed: isSubmitting ? null : onRemove,
                iconSize: 18,
                icon: Icon(Icons.close, color: colorScheme.error),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(
              truncateAddress(entry.address, chars: 8),
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (entry.isOriginal && entry.originalParams != null)
            EditPolicyParamsForm(
              entry: entry,
              isSubmitting: isSubmitting,
              spendingLimitDecimals: spendingLimitDecimals,
              onEntryUpdated: onEntryUpdated,
            ),
        ],
      ),
    );
  }
}
