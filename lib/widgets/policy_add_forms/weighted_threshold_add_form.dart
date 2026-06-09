/// Add-form for the weighted-threshold policy type.
///
/// Owns its own threshold controller, per-signer weight controllers, and
/// per-field validation errors. Per-signer weight controllers are keyed
/// by [StagedSigner.uniqueKey] so they survive widget rebuilds while the
/// signer list is stable, and are pruned when signers go away. Reports
/// successful adds via [onAddPolicy]; the parent dispatches the new
/// [StagedPolicy] and is responsible for collapsing the chooser back to
/// its empty state on success.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/demo_config.dart' show PolicyInfo;
import '../../flows/context_rule_builder_types.dart';
import '../../util/signer_colors.dart';
import '../../util/signer_type_label.dart';
import '../field_error_text.dart';
import '../full_width_submit_button.dart';
import '../signer_identity_chip.dart';
import '../weight_input_row.dart';
import 'policy_add_form_shared.dart' show PolicyContractRow, handlePolicyAddEpilogue;

/// Stateful form that gathers a weight threshold and a per-signer weight
/// matrix and submits it as a [StagedPolicy] for [PolicyInfo.type] equal
/// to `PolicyType.weightedThreshold`.
class WeightedThresholdAddForm extends StatefulWidget {
  /// Creates a weighted-threshold add form.
  const WeightedThresholdAddForm({
    required this.policy,
    required this.signers,
    required this.isSubmitting,
    required this.onAddPolicy,
    required this.onAddSucceeded,
    super.key,
  });

  /// Canonical metadata for the weighted-threshold policy contract.
  final PolicyInfo policy;

  /// Currently staged signers; one weight row is rendered per signer.
  /// May be empty, in which case the form renders a hint and disables
  /// the submit button.
  final List<StagedSigner> signers;

  /// True while the parent form is submitting; disables the inputs.
  final bool isSubmitting;

  /// Called when the user successfully adds a new policy.
  ///
  /// Returns null on success or an error string when the policy cannot
  /// be added (e.g. duplicate / cap exceeded).
  final String? Function(StagedPolicy policy) onAddPolicy;

  /// Invoked after [onAddPolicy] returns null so the parent can collapse
  /// the chooser and clear its `_selectedType`.
  final VoidCallback onAddSucceeded;

  @override
  State<WeightedThresholdAddForm> createState() =>
      _WeightedThresholdAddFormState();
}

class _WeightedThresholdAddFormState extends State<WeightedThresholdAddForm> {
  final TextEditingController _thresholdController = TextEditingController();
  String? _thresholdError;
  String? _weightsError;
  final Map<String, TextEditingController> _weightControllers = {};

  @override
  void dispose() {
    _thresholdController.dispose();
    for (final c in _weightControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant WeightedThresholdAddForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep weight controllers aligned with the current signer list. Any
    // controller whose signer has been removed is disposed and dropped.
    final keys = widget.signers.map((s) => s.uniqueKey).toSet();
    final stale = _weightControllers.keys
        .where((k) => !keys.contains(k))
        .toList(growable: false);
    for (final k in stale) {
      _weightControllers.remove(k)?.dispose();
    }
  }

  TextEditingController _weightController(String key) {
    return _weightControllers.putIfAbsent(key, TextEditingController.new);
  }

  void _onAdd() {
    final raw = _thresholdController.text.trim();
    final threshold = int.tryParse(raw);
    String? thresholdErr;
    String? weightsErr;

    if (threshold == null || threshold < 1) {
      thresholdErr = 'Must be at least 1';
    }
    if (widget.signers.isEmpty) {
      weightsErr = 'Add signers before configuring weights';
    }

    final signerWeights = <OZSmartAccountSigner, int>{};
    var totalWeight = 0;

    if (weightsErr == null) {
      for (final s in widget.signers) {
        final ctrl = _weightController(s.uniqueKey);
        final w = int.tryParse(ctrl.text.trim());
        if (w == null || w < 1) {
          weightsErr = 'All signers must have a weight >= 1';
          break;
        }
        totalWeight += w;
        signerWeights[s.signer] = w;
      }
    }

    if (thresholdErr == null && weightsErr == null) {
      if (totalWeight < threshold!) {
        weightsErr =
            'Total weight ($totalWeight) must be >= threshold ($threshold)';
      }
    }

    if (thresholdErr != null || weightsErr != null) {
      setState(() {
        _thresholdError = thresholdErr;
        _weightsError = weightsErr;
      });
      return;
    }

    final staged = StagedPolicy(
      info: widget.policy,
      label: 'Weighted: threshold=$threshold',
      installParams: OZWeightedThresholdPolicyParams(
        signerWeights: signerWeights,
        threshold: threshold!,
      ),
    );
    handlePolicyAddEpilogue(
      context: context,
      staged: staged,
      policyName: widget.policy.name,
      onAddPolicy: widget.onAddPolicy,
      onSetError: (e) => setState(() => _weightsError = e),
      onAddSucceeded: widget.onAddSucceeded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PolicyContractRow(
          address: widget.policy.address,
          colorScheme: colorScheme,
          textTheme: textTheme,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _thresholdController,
          onChanged: (_) {
            setState(() {
              if (_thresholdError != null) {
                _thresholdError = null;
              }
            });
          },
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Weight Threshold',
            hintText: 'e.g., 100',
            border: const OutlineInputBorder(),
            helperText: _thresholdError == null
                ? 'Minimum total weight required for authorization'
                : null,
          ),
          enabled: !widget.isSubmitting,
        ),
        FieldErrorText(error: _thresholdError, topGap: 6),
        const SizedBox(height: 12),
        if (widget.signers.isEmpty)
          Text(
            'Add signers above to configure per-signer weights.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          )
        else ...[
          Semantics(
            header: true,
            child: Text(
              'Per-Signer Weights',
              style: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 6),
          for (final s in widget.signers) ...[
            WeightInputRow(
              key: ValueKey<String>(s.uniqueKey),
              identity: SignerIdentityChip(
                typeLabel: labelForStagedSignerType(s.type),
                displayValue: s.identifier,
                chipColor: signerTypeColorForDisplayLabel(labelForStagedSignerType(s.type)),
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              ),
              controller: _weightController(s.uniqueKey),
              enabled: !widget.isSubmitting,
              semanticIdentity: '${labelForStagedSignerType(s.type)} signer ${s.identifier}',
              onChanged: (_) {
                if (_weightsError != null) {
                  setState(() => _weightsError = null);
                }
              },
            ),
          ],
        ],
        FieldErrorText(error: _weightsError, topGap: 6),
        const SizedBox(height: 12),
        FullWidthSubmitButton(
          label: 'Add Weighted Threshold Policy',
          enabled: !widget.isSubmitting &&
              _thresholdController.text.trim().isNotEmpty &&
              widget.signers.isNotEmpty,
          onPressed: _onAdd,
        ),
      ],
    );
  }
}

