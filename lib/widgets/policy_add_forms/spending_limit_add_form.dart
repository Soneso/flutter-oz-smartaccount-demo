/// Add-form for the spending-limit policy type.
///
/// Owns its own amount and period controllers and per-field validation
/// errors. Reports successful adds via [onAddPolicy]; the parent
/// dispatches the new [StagedPolicy] and is responsible for collapsing
/// the chooser back to its empty state on success.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../config/demo_config.dart' show PolicyInfo;
import '../../flows/context_rule_builder_types.dart';
import '../../flows/context_rule_flow.dart' show ledgersPerDay;
import '../../util/format_utils.dart';
import '../../util/policy_scval_builders.dart';
import 'threshold_add_form.dart' show PolicyContractRow;

/// Stateful form that gathers a per-period spending limit (amount in
/// XLM-like decimal, period in whole days) and submits it as a
/// [StagedPolicy] for [PolicyInfo.type] equal to
/// `PolicyType.spendingLimit`.
class SpendingLimitAddForm extends StatefulWidget {
  /// Creates a spending-limit add form.
  const SpendingLimitAddForm({
    required this.policy,
    required this.isSubmitting,
    required this.onAddPolicy,
    required this.onAddSucceeded,
    super.key,
  });

  /// Canonical metadata for the spending-limit policy contract.
  final PolicyInfo policy;

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
  State<SpendingLimitAddForm> createState() => _SpendingLimitAddFormState();
}

class _SpendingLimitAddFormState extends State<SpendingLimitAddForm> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _periodController = TextEditingController();
  String? _amountError;
  String? _periodError;

  @override
  void dispose() {
    _amountController.dispose();
    _periodController.dispose();
    super.dispose();
  }

  void _onAdd() {
    final amountRaw = _amountController.text.trim();
    final periodRaw = _periodController.text.trim();
    String? amountErr;
    String? periodErr;

    // Reject scientific notation and amounts with more than 7 fractional
    // digits before any numeric parsing. Stellar amounts must fit in
    // stroop precision (1 XLM = 10_000_000 stroops); accepting a richer
    // input here would silently lose precision when reduced to integer
    // stroops.
    if (!stellarDecimalAmountPattern.hasMatch(amountRaw)) {
      amountErr = 'Must be a positive amount with up to 7 decimal places';
    }
    final days = int.tryParse(periodRaw);
    if (days == null || days < 1) {
      periodErr = 'Must be at least 1 day';
    }

    int? stroops;
    if (amountErr == null) {
      stroops = decimalToStroops(amountRaw);
      if (stroops == null || stroops <= 0) {
        amountErr = 'Must be a positive amount with up to 7 decimal places';
      }
    }

    if (amountErr != null || periodErr != null) {
      setState(() {
        _amountError = amountErr;
        _periodError = periodErr;
      });
      return;
    }

    final periodLedgers = days! * ledgersPerDay;

    XdrSCVal scVal;
    try {
      scVal = buildSpendingLimitScVal(
        limit: stroops!,
        periodLedgers: periodLedgers,
      );
    } catch (e) {
      setState(() => _amountError = e.toString());
      return;
    }

    // Normalise the display label via num.parse so trailing zeros are
    // dropped and the staged row reads "100" not "100.0000000".
    final normalised = num.parse(amountRaw).toString();
    final staged = StagedPolicy(
      info: widget.policy,
      label: 'Limit: $normalised / $days day(s)',
      scVal: scVal,
    );
    final addError = widget.onAddPolicy(staged);
    if (addError != null) {
      setState(() => _amountError = addError);
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
    final days = int.tryParse(_periodController.text.trim()) ?? 0;
    final ledgers = days * ledgersPerDay;
    final periodHelper = days > 0
        ? '$days day(s) = $ledgers ledgers'
        : 'The spending limit resets after this period. '
            'Example: amount 100 with period 1 means max 100 tokens per day.';

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
          controller: _amountController,
          onChanged: (_) {
            setState(() {
              if (_amountError != null) _amountError = null;
            });
          },
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: 'Amount',
            hintText: 'e.g., 100.0',
            border: const OutlineInputBorder(),
            helperText: _amountError == null
                ? 'Maximum amount allowed per period'
                : null,
          ),
          enabled: !widget.isSubmitting,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _periodController,
          onChanged: (_) {
            if (_periodError != null) {
              setState(() => _periodError = null);
            } else {
              // Refresh helper text reactively.
              setState(() {});
            }
          },
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Period (days)',
            hintText: 'e.g., 1',
            border: const OutlineInputBorder(),
            helperText: _periodError == null ? periodHelper : null,
          ),
          enabled: !widget.isSubmitting,
        ),
        if (_amountError != null || _periodError != null) ...[
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              _amountError ?? _periodError ?? '',
              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: widget.isSubmitting ||
                    _amountController.text.trim().isEmpty ||
                    _periodController.text.trim().isEmpty
                ? null
                : _onAdd,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('Add Spending Limit Policy'),
          ),
        ),
      ],
    );
  }
}
