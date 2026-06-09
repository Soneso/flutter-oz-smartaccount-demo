/// Add-form for the spending-limit policy type.
///
/// Owns its own amount and period controllers and per-field validation
/// errors. Reports successful adds via [onAddPolicy]; the parent
/// dispatches the new [StagedPolicy] and is responsible for collapsing
/// the chooser back to its empty state on success.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/demo_config.dart' show PolicyInfo;
import '../../flows/context_rule_builder_types.dart';
import '../../flows/context_rule_flow.dart' show ledgersPerDay;
import '../field_error_text.dart';
import '../full_width_submit_button.dart';
import 'policy_add_form_shared.dart' show PolicyContractRow, handlePolicyAddEpilogue;

/// Stateful form that gathers a per-period spending limit (amount in
/// XLM-like decimal, period in whole days) and submits it as a
/// [StagedPolicy] for [PolicyInfo.type] equal to
/// `PolicyType.spendingLimit`.
class SpendingLimitAddForm extends StatefulWidget {
  /// Creates a spending-limit add form.
  const SpendingLimitAddForm({
    required this.policy,
    required this.isSubmitting,
    required this.decimals,
    required this.onAddPolicy,
    required this.onAddSucceeded,
    this.decimalsError,
    super.key,
  });

  /// Canonical metadata for the spending-limit policy contract.
  final PolicyInfo policy;

  /// True while the parent form is submitting; disables the inputs.
  final bool isSubmitting;

  /// Decimal scale of the rule's guarded token, used to convert the entered
  /// amount to base units. Resolved by the parent (native decimals for the
  /// native / default-rule case, the token's own `decimals()` otherwise).
  final int decimals;

  /// Non-null when the parent could not resolve the guarded token's decimals.
  /// While set, the Add button is disabled and the message is shown so the
  /// amount is never scaled with the wrong precision.
  final String? decimalsError;

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

/// Matches a non-negative decimal with an optional single fractional part.
/// Precision (against the guarded token's decimals) and positivity are
/// enforced by [OZTransactionOperations.amountToBaseUnits].
final RegExp _positiveDecimalPattern = RegExp(r'^\d+(\.\d+)?$');

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

    // Reject scientific notation and non-decimal shapes before numeric
    // parsing. Fractional-precision (relative to the guarded token's
    // decimals) and range are enforced by amountToBaseUnits below.
    if (amountRaw.toLowerCase().contains('e') ||
        !_positiveDecimalPattern.hasMatch(amountRaw)) {
      amountErr = 'Must be a positive number';
    }
    final days = int.tryParse(periodRaw);
    if (days == null || days < 1) {
      periodErr = 'Must be at least 1 day';
    }

    BigInt? baseUnits;
    if (amountErr == null) {
      try {
        baseUnits = OZTransactionOperations.amountToBaseUnits(
          amountRaw,
          decimals: widget.decimals,
        );
      } on SmartAccountValidationException catch (e) {
        amountErr = e.message;
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

    // Normalise the display label via num.parse so trailing zeros are
    // dropped and the staged row reads "100" not "100.0000000".
    final normalised = num.parse(amountRaw).toString();
    final staged = StagedPolicy(
      info: widget.policy,
      label: 'Limit: $normalised / $days day(s)',
      installParams: OZSpendingLimitPolicyParams(
        spendingLimit: baseUnits!,
        periodLedgers: periodLedgers,
      ),
    );
    handlePolicyAddEpilogue(
      context: context,
      staged: staged,
      policyName: widget.policy.name,
      onAddPolicy: widget.onAddPolicy,
      onSetError: (e) => setState(() => _amountError = e),
      onAddSucceeded: widget.onAddSucceeded,
    );
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
        FieldErrorText(
          error: _amountError ?? _periodError,
          topGap: 6,
        ),
        FieldErrorText(error: widget.decimalsError, topGap: 6),
        const SizedBox(height: 12),
        FullWidthSubmitButton(
          label: 'Add Spending Limit Policy',
          enabled: !widget.isSubmitting &&
              widget.decimalsError == null &&
              _amountController.text.trim().isNotEmpty &&
              _periodController.text.trim().isNotEmpty,
          onPressed: _onAdd,
        ),
      ],
    );
  }
}
