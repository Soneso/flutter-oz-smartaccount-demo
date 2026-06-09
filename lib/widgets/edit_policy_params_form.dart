/// Inline form for editing parameters of an existing on-chain policy.
///
/// Renders pre-populated fields for the relevant policy type. As the user
/// changes any value, a fresh [PolicyInstallSpec] is produced and the entry is
/// reported back to the caller with [EditPolicyEntry.modified] set to
/// `true`. Reverting all changes flips [EditPolicyEntry.modified] back to
/// `false` so the parent can suppress the modified-badge.
///
/// Weighted-threshold inline editing is not supported; the inner
/// signer-weight payload requires the parent's live signer SCVals. Users
/// remove and re-add the policy to change parameters.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../flows/context_rule_builder_types.dart'
    show OZTransactionOperations, SmartAccountValidationException;
import '../flows/context_rule_edit_types.dart';
import '../flows/context_rule_flow.dart' show ledgersPerDay;
import '../util/policy_type.dart';
import '../util/semantic_colors.dart';
import '../util/signer_colors.dart';
import 'field_error_text.dart';
import 'signer_identity_chip.dart';

// ---------------------------------------------------------------------------
// EditPolicyParamsForm
// ---------------------------------------------------------------------------

/// Matches a non-negative decimal with an optional single fractional part.
/// Precision (against the guarded token's decimals) and positivity are
/// enforced by [OZTransactionOperations.amountToBaseUnits].
final RegExp _positiveDecimalPattern = RegExp(r'^\d+(\.\d+)?$');

/// Renders an inline edit form for the parameters of an on-chain policy.
class EditPolicyParamsForm extends StatefulWidget {
  /// Creates an inline policy edit form.
  const EditPolicyParamsForm({
    required this.entry,
    required this.onEntryUpdated,
    required this.isSubmitting,
    required this.spendingLimitDecimals,
    super.key,
  });

  /// The policy entry being edited. Must have [EditPolicyEntry.isOriginal]
  /// true and non-null [EditPolicyEntry.originalParams].
  final EditPolicyEntry entry;

  /// Called when the user edits any parameter. The new entry replaces the
  /// caller's reference.
  final void Function(EditPolicyEntry entry) onEntryUpdated;

  /// True while a submission is in flight; disables every input.
  final bool isSubmitting;

  /// Decimal scale of the rule's guarded token, used to convert an edited
  /// spending-limit amount to base units.
  final int spendingLimitDecimals;

  @override
  State<EditPolicyParamsForm> createState() => _EditPolicyParamsFormState();
}

class _EditPolicyParamsFormState extends State<EditPolicyParamsForm> {
  late final TextEditingController _thresholdController;
  late final TextEditingController _amountController;
  late final TextEditingController _periodDaysController;
  late final TextEditingController _weightedThresholdController;

  // Per-signer weight inputs keyed by the entry's stableKey. Read-only;
  // populated for display so users can see the on-chain weights alongside
  // the "edit unsupported" helper text.
  final Map<String, TextEditingController> _weightControllers =
      <String, TextEditingController>{};

  String? _error;

  /// Helper text shown for the weighted-threshold inline editor.
  static const String _weightedUnsupportedHelper =
      'Weighted-threshold inline edit is not yet supported. '
      'Remove and re-add to change parameters.';

  @override
  void initState() {
    super.initState();
    final params = widget.entry.originalParams;
    _thresholdController =
        TextEditingController(text: params?.threshold?.toString() ?? '');
    _amountController =
        TextEditingController(text: params?.spendingLimit ?? '');
    _periodDaysController =
        TextEditingController(text: params?.periodDays?.toString() ?? '');
    _weightedThresholdController =
        TextEditingController(text: params?.threshold?.toString() ?? '');

    final weights = params?.signerWeights;
    if (weights != null) {
      for (final entry in weights) {
        _weightControllers[entry.stableKey] =
            TextEditingController(text: entry.weight.toString());
      }
    }
  }

  @override
  void dispose() {
    _thresholdController.dispose();
    _amountController.dispose();
    _periodDaysController.dispose();
    _weightedThresholdController.dispose();
    for (final c in _weightControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- Threshold ----

  void _onThresholdChanged(String value) {
    setState(() => _error = null);
    final params = widget.entry.originalParams;
    if (params == null) return;

    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 1 || parsed > 15) {
      setState(() => _error = 'Must be between 1 and 15');
      // Still report the modified flag based on whether the value diverges
      // from the original — invalid inputs leave the form dirty but the
      // spec stays null so the submit button can detect the issue.
      final changed = value.trim() != (params.threshold?.toString() ?? '');
      widget.onEntryUpdated(
        widget.entry.copyWith(modified: changed, clearInstallSpec: true),
      );
      return;
    }
    final changed = parsed != params.threshold;
    final spec = PolicyInstallSpecSimpleThreshold(threshold: parsed);
    widget.onEntryUpdated(
      widget.entry.copyWith(
        modified: changed,
        installSpec: changed ? spec : null,
        clearInstallSpec: !changed,
        label: 'Threshold: $parsed-of-N',
      ),
    );
  }

  // ---- Spending limit ----

  void _onSpendingChanged() {
    setState(() => _error = null);
    final params = widget.entry.originalParams;
    if (params == null) return;

    final amountStr = _amountController.text.trim();
    final periodStr = _periodDaysController.text.trim();

    final amountWellFormed =
        !amountStr.toLowerCase().contains('e') &&
            _positiveDecimalPattern.hasMatch(amountStr);
    final days = int.tryParse(periodStr);

    final amountChanged = amountStr != (params.spendingLimit ?? '');
    final periodChanged = days != params.periodDays;
    final isDirty = amountChanged || periodChanged;

    if (!amountWellFormed || days == null || days < 1) {
      setState(() => _error = 'Must be a positive amount and >= 1 day');
      widget.onEntryUpdated(
        widget.entry.copyWith(modified: isDirty, clearInstallSpec: true),
      );
      return;
    }

    // Validate the amount via amountToBaseUnits to surface precision errors
    // (excess fractional digits, non-positive, out of range) before staging.
    try {
      OZTransactionOperations.amountToBaseUnits(
        amountStr,
        decimals: widget.spendingLimitDecimals,
      );
    } on SmartAccountValidationException catch (e) {
      setState(() => _error = e.message);
      widget.onEntryUpdated(
        widget.entry.copyWith(modified: isDirty, clearInstallSpec: true),
      );
      return;
    }

    // Pass the decimal string + decimals to the spec so the flow can forward
    // them to policyManager.addSpendingLimit which handles the conversion.
    final periodLedgers = days * ledgersPerDay;
    final spec = PolicyInstallSpecSpendingLimit(
      amount: amountStr,
      decimals: widget.spendingLimitDecimals,
      periodLedgers: periodLedgers,
    );
    widget.onEntryUpdated(
      widget.entry.copyWith(
        modified: isDirty,
        installSpec: isDirty ? spec : null,
        clearInstallSpec: !isDirty,
        label: 'Limit: $amountStr / $days day(s)',
      ),
    );
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final params = widget.entry.originalParams;
    if (params == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Edit ${widget.entry.info?.name ?? 'Policy'} Parameters',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              ),
            ),
          ),
          if (widget.entry.modified) ...[
            const SizedBox(height: 4),
            Semantics(
              liveRegion: true,
              child: Text(
                'Parameters modified (will be updated on submit)',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.modifiedBadgeForeground),
              ),
            ),
          ],
          const SizedBox(height: 8),
          _buildBody(params, colorScheme, textTheme),
          FieldErrorText(error: _error),
        ],
      ),
    );
  }

  Widget _buildBody(
    PolicyParams params,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (params.type) {
      case PolicyType.threshold:
        return TextField(
          controller: _thresholdController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          enabled: !widget.isSubmitting,
          onChanged: _onThresholdChanged,
          decoration: InputDecoration(
            labelText: 'Threshold (required signers)',
            border: const OutlineInputBorder(),
            helperText:
                'Current on-chain value: ${params.threshold ?? 'unknown'}',
          ),
        );
      case PolicyType.spendingLimit:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              enabled: !widget.isSubmitting,
              onChanged: (_) => _onSpendingChanged(),
              decoration: InputDecoration(
                labelText: 'Amount',
                border: const OutlineInputBorder(),
                helperText:
                    'Current on-chain value: ${params.spendingLimit ?? 'unknown'}',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _periodDaysController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              enabled: !widget.isSubmitting,
              onChanged: (_) => _onSpendingChanged(),
              decoration: InputDecoration(
                labelText: 'Period (days)',
                border: const OutlineInputBorder(),
                helperText: 'Current on-chain value: '
                    '${params.periodDays ?? 'unknown'} day(s)',
              ),
            ),
          ],
        );
      case PolicyType.weightedThreshold:
        final weights = params.signerWeights ?? const <WeightedSignerEntry>[];
        // Weighted-threshold inline editing is unsupported; fields are inert
        // with a live-region helper for assistive technology.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                _weightedUnsupportedHelper,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _weightedThresholdController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              enabled: false,
              decoration: InputDecoration(
                labelText: 'Weight Threshold',
                border: const OutlineInputBorder(),
                helperText:
                    'Current on-chain value: ${params.threshold ?? 'unknown'}',
              ),
            ),
            if (weights.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Per-Signer Weights',
                style: textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              for (final entry in weights)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _WeightedSignerRow(
                    entry: entry,
                    controller: _weightControllers.putIfAbsent(
                      entry.stableKey,
                      () => TextEditingController(
                        text: entry.weight.toString(),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

}

// ---------------------------------------------------------------------------
// _WeightedSignerRow
// ---------------------------------------------------------------------------

/// A single row in the weighted-threshold Per-Signer Weights display.
///
/// Renders the signer badge and display value via [SignerIdentityChip]
/// alongside a read-only weight field.
class _WeightedSignerRow extends StatelessWidget {
  const _WeightedSignerRow({
    required this.entry,
    required this.controller,
  });

  final WeightedSignerEntry entry;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final info = entry.displayInfo;
    final chipColor = signerTypeColorForDisplayLabel(info.typeLabel);

    return Row(
      children: [
        Expanded(
          child: SignerIdentityChip(
            typeLabel: info.typeLabel,
            displayValue: info.displayValue,
            chipColor: chipColor,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 100,
          child: Semantics(
            label: 'Weight for ${info.typeLabel} signer ${info.displayValue}',
            textField: true,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              enabled: false,
              decoration: const InputDecoration(
                labelText: 'Weight',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

