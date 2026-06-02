/// Add-form for the simple-threshold policy type.
///
/// Owns its own threshold-count controller and validation error. Reports
/// successful adds via [onAddPolicy]; the parent dispatches the new
/// [StagedPolicy] and is responsible for collapsing the chooser back to
/// its empty state on success.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../config/demo_config.dart' show PolicyInfo;
import '../../flows/context_rule_builder_types.dart';
import '../../util/format_utils.dart';
import '../../util/policy_scval_builders.dart';

/// Stateful form that gathers a simple threshold (1..15) and submits it
/// as a [StagedPolicy] for [PolicyInfo.type] equal to
/// `PolicyType.threshold`.
class ThresholdAddForm extends StatefulWidget {
  /// Creates a threshold-policy add form.
  const ThresholdAddForm({
    required this.policy,
    required this.signers,
    required this.isSubmitting,
    required this.onAddPolicy,
    required this.onAddSucceeded,
    super.key,
  });

  /// Canonical metadata for the threshold policy contract.
  final PolicyInfo policy;

  /// Currently staged signers; used to cap the threshold to the signer
  /// count and to render the helper text.
  final List<StagedSigner> signers;

  /// True while the parent form is submitting; disables the input.
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
  State<ThresholdAddForm> createState() => _ThresholdAddFormState();
}

class _ThresholdAddFormState extends State<ThresholdAddForm> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onAdd() {
    final raw = _controller.text.trim();
    final t = int.tryParse(raw);
    if (t == null || t < 1 || t > 15) {
      setState(() => _error = 'Must be between 1 and 15');
      return;
    }
    if (widget.signers.isNotEmpty && t > widget.signers.length) {
      setState(() => _error =
          'Cannot exceed signer count (${widget.signers.length})');
      return;
    }

    XdrSCVal scVal;
    try {
      scVal = buildSimpleThresholdScVal(threshold: t);
    } catch (e) {
      setState(() => _error = e.toString());
      return;
    }

    final staged = StagedPolicy(
      info: widget.policy,
      label: 'Threshold: $t-of-N',
      scVal: scVal,
    );

    final addError = widget.onAddPolicy(staged);
    if (addError != null) {
      setState(() => _error = addError);
      return;
    }
    SemanticsService.announce(
      'Added ${widget.policy.name} policy',
      Directionality.of(context),
    );
    widget.onAddSucceeded();
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
          controller: _controller,
          onChanged: (_) {
            setState(() {
              if (_error != null) _error = null;
            });
          },
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Threshold (required signers)',
            hintText: 'e.g., 2',
            border: const OutlineInputBorder(),
            helperText: _error == null
                ? 'Number of signers required to authorize '
                    '(1 to ${widget.signers.isEmpty ? 1 : widget.signers.length})'
                : null,
          ),
          enabled: !widget.isSubmitting,
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed:
                widget.isSubmitting || _controller.text.trim().isEmpty
                    ? null
                    : _onAdd,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('Add Threshold Policy'),
          ),
        ),
      ],
    );
  }
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
