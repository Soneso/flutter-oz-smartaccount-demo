/// Inline form for editing parameters of an existing on-chain policy.
///
/// Renders pre-populated fields for the relevant policy type. As the user
/// changes any value, a fresh policy `XdrSCVal` is built and the entry is
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

import '../flows/context_rule_edit_types.dart';
import '../flows/context_rule_flow.dart' show ledgersPerDay;
import '../util/format_utils.dart';
import '../util/policy_scval_builders.dart';
import '../util/policy_type.dart';
import '../util/semantic_colors.dart';
import '../util/signer_type_label.dart';
import 'field_error_text.dart';

// ---------------------------------------------------------------------------
// EditPolicyParamsForm
// ---------------------------------------------------------------------------

/// Renders an inline edit form for the parameters of an on-chain policy.
class EditPolicyParamsForm extends StatefulWidget {
  /// Creates an inline policy edit form.
  const EditPolicyParamsForm({
    required this.entry,
    required this.onEntryUpdated,
    required this.isSubmitting,
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

  @override
  State<EditPolicyParamsForm> createState() => _EditPolicyParamsFormState();
}

class _EditPolicyParamsFormState extends State<EditPolicyParamsForm> {
  late final TextEditingController _thresholdController;
  late final TextEditingController _amountController;
  late final TextEditingController _periodDaysController;
  late final TextEditingController _weightedThresholdController;

  // Per-signer weight inputs keyed by signer key string. Read-only;
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
      for (final entry in weights.entries) {
        _weightControllers[entry.key] =
            TextEditingController(text: entry.value.toString());
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
      // SCVal stays null so the submit button can detect the issue.
      final changed = value.trim() != (params.threshold?.toString() ?? '');
      widget.onEntryUpdated(
        widget.entry.copyWith(modified: changed, clearScVal: true),
      );
      return;
    }
    final changed = parsed != params.threshold;
    final scVal = buildSimpleThresholdScVal(threshold: parsed);
    widget.onEntryUpdated(
      widget.entry.copyWith(
        modified: changed,
        scVal: changed ? scVal : null,
        clearScVal: !changed,
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

    final amountValid = stellarDecimalAmountPattern.hasMatch(amountStr);
    final days = int.tryParse(periodStr);

    final amountChanged = amountStr != (params.spendingLimit ?? '');
    final periodChanged = days != params.periodDays;
    final isDirty = amountChanged || periodChanged;

    if (!amountValid || days == null || days < 1) {
      setState(() => _error =
          'Must be a positive amount with up to 7 decimal places and >= 1 day');
      widget.onEntryUpdated(
        widget.entry.copyWith(modified: isDirty, clearScVal: true),
      );
      return;
    }

    final stroops = decimalToStroops(amountStr);
    if (stroops == null || stroops <= 0) {
      setState(() => _error = 'Must be a positive amount');
      widget.onEntryUpdated(
        widget.entry.copyWith(modified: isDirty, clearScVal: true),
      );
      return;
    }

    final periodLedgers = days * ledgersPerDay;
    final scVal = buildSpendingLimitScVal(
      limit: stroops,
      periodLedgers: periodLedgers,
    );
    widget.onEntryUpdated(
      widget.entry.copyWith(
        modified: isDirty,
        scVal: isDirty ? scVal : null,
        clearScVal: !isDirty,
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
        final weights = params.signerWeights ?? const <String, int>{};
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
              for (final entry in weights.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.key,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 100,
                        child: Semantics(
                          label: 'Weight for ${_signerLabelFor(entry.key)} '
                              'signer ${entry.key}',
                          textField: true,
                          child: TextField(
                            controller: _weightControllers.putIfAbsent(
                              entry.key,
                              () => TextEditingController(
                                text: entry.value.toString(),
                              ),
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
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
                  ),
                ),
            ],
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// Best-effort signer-type descriptor for assistive-technology weight
  /// field labels. The on-chain signer-weight map key is opaque (a typed
  /// descriptor string assembled by the policy parser), so the readable
  /// label uses its leading token when one is recognisable and otherwise
  /// falls back to a generic descriptor.
  String _signerLabelFor(String key) {
    if (key.startsWith('External:')) return SignerTypeLabel.external;
    if (key.length == 56 && key.startsWith('G')) return 'Delegated';
    return 'Signer';
  }
}

