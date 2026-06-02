/// Inner widget shells used by the Context Rule Builder screen.
///
/// These widgets are kept in a separate file purely for size management —
/// they remain private to the screen via the `part of` relationship so
/// they can continue to reference the screen's private enums, constants,
/// and helper types without exposing them on the widget layer.
part of '../screens/context_rule_builder_screen.dart';

class _RuleNameField extends StatelessWidget {
  const _RuleNameField({
    required this.controller,
    required this.error,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String? error;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: (_) {
        // Notify the parent to recompute field error, diff/cap, and CTA state.
        onChanged();
      },
      decoration: InputDecoration(
        labelText: 'Rule Name',
        hintText: 'e.g., DefaultRule, TokenTransfers',
        border: const OutlineInputBorder(),
        errorText: error,
      ),
    );
  }
}

class _ContextTypeSection extends StatelessWidget {
  const _ContextTypeSection({
    required this.option,
    required this.contractAddress,
    required this.wasmHashController,
    required this.contractError,
    required this.wasmError,
    required this.enabled,
    required this.onOptionChanged,
    required this.onContractChanged,
    required this.onWasmChanged,
    this.showEditHelper = false,
  });

  final _ContextTypeOption option;
  final String contractAddress;
  final TextEditingController wasmHashController;
  final String? contractError;
  final String? wasmError;
  final bool enabled;
  final bool showEditHelper;
  final ValueChanged<_ContextTypeOption> onOptionChanged;
  final ValueChanged<String> onContractChanged;
  final VoidCallback onWasmChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<_ContextTypeOption>(
          initialValue: option,
          itemHeight: null,
          decoration: const InputDecoration(
            labelText: 'Context Type',
            border: OutlineInputBorder(),
          ),
          selectedItemBuilder: (_) => [
            for (final o in _ContextTypeOption.values)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(o.displayName),
              ),
          ],
          items: [
            for (final o in _ContextTypeOption.values)
              DropdownMenuItem<_ContextTypeOption>(
                value: o,
                child: Semantics(
                  label: '${o.displayName}. ${o.description}',
                  excludeSemantics: true,
                  child: RichDropdownItem(
                    title: o.displayName,
                    subtitle: o.description,
                  ),
                ),
              ),
          ],
          onChanged: enabled
              ? (o) {
                  if (o != null) onOptionChanged(o);
                }
              : null,
        ),
        const SizedBox(height: 6),
        Text(
          option.description,
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        if (showEditHelper) ...[
          const SizedBox(height: 6),
          Text(
            'Context type cannot be changed after creation.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (option == _ContextTypeOption.callContract) ...[
          const SizedBox(height: 12),
          _ContractSelector(
            address: contractAddress,
            error: contractError,
            enabled: enabled,
            onChanged: onContractChanged,
          ),
        ],
        if (option == _ContextTypeOption.createContract) ...[
          const SizedBox(height: 12),
          TextField(
            controller: wasmHashController,
            onChanged: (_) => onWasmChanged(),
            enabled: enabled,
            inputFormatters: [
              FilteringTextInputFormatter.deny(RegExp(r'\s')),
            ],
            decoration: InputDecoration(
              labelText: 'WASM Hash (hex)',
              hintText: '64 hex characters',
              border: const OutlineInputBorder(),
              errorText: wasmError,
            ),
          ),
        ],
      ],
    );
  }
}

class _ContractSelector extends ConsumerWidget {
  const _ContractSelector({
    required this.address,
    required this.error,
    required this.enabled,
    required this.onChanged,
  });

  final String address;
  final String? error;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demoToken = ref.watch(
      demoStateProvider.select((s) => s.demoTokenContractId),
    );

    final options = <_ContractOption>[
      const _ContractOption('XLM Native Contract', config.nativeTokenContract),
      if (demoToken != null)
        _ContractOption('Demo Token Contract', demoToken),
    ];
    final isInList = options.any((o) => o.address == address);
    final dropdownValue = isInList ? address : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: dropdownValue,
          itemHeight: null,
          decoration: InputDecoration(
            labelText: 'Contract',
            border: const OutlineInputBorder(),
            errorText: error,
          ),
          selectedItemBuilder: (_) => [
            for (final o in options)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(o.label),
              ),
          ],
          items: [
            for (final o in options)
              DropdownMenuItem<String>(
                value: o.address,
                child: Semantics(
                  label: '${o.label}. Contract address ${o.address}',
                  excludeSemantics: true,
                  child: RichDropdownItem(
                    title: o.label,
                    subtitle: truncateAddress(o.address, chars: 8),
                  ),
                ),
              ),
          ],
          onChanged: enabled
              ? (v) {
                  if (v != null) onChanged(v);
                }
              : null,
        ),
      ],
    );
  }
}

class _ContractOption {
  const _ContractOption(this.label, this.address);
  final String label;
  final String address;
}

class _ExpirySection extends StatelessWidget {
  const _ExpirySection({
    required this.hasExpiry,
    required this.offset,
    required this.isCustom,
    required this.customController,
    required this.error,
    required this.enabled,
    required this.onChanged,
    this.existingExpiryLedger,
  });

  final bool hasExpiry;
  final int? offset;
  final bool isCustom;
  final TextEditingController customController;
  final String? error;
  final bool enabled;
  final int? existingExpiryLedger;
  final void Function(bool hasExpiry, int? offset, bool isCustom) onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // The dropdown value is either the matched preset offset, the
    // sentinel -1 when the user has selected `Custom`, or null when no
    // selection has been made.
    final int? dropdownValue;
    if (!hasExpiry) {
      dropdownValue = null;
    } else if (isCustom) {
      dropdownValue = -1;
    } else if (_kExpiryOptions.any((p) => p.offset == offset)) {
      dropdownValue = offset;
    } else {
      dropdownValue = null;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.cardBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            value: hasExpiry,
            onChanged: enabled
                ? (v) => onChanged(v ?? false, v == true ? offset : null,
                    v == true ? isCustom : false)
                : null,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Set Expiry'),
            contentPadding: EdgeInsets.zero,
          ),
          if (hasExpiry) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: dropdownValue,
              decoration: InputDecoration(
                labelText: 'Time from now',
                border: const OutlineInputBorder(),
                errorText: error,
              ),
              items: [
                for (final p in _kExpiryOptions)
                  DropdownMenuItem<int>(
                    // Use -1 as the sentinel for Custom so the underlying
                    // dropdown remains keyed on int values.
                    value: p.isCustom ? -1 : p.offset,
                    child: Semantics(
                      label: p.isCustom
                          ? 'Custom. Enter a custom expiry offset in ledgers.'
                          : '${p.label} expiry preset.',
                      excludeSemantics: true,
                      child: Text(p.label),
                    ),
                  ),
              ],
              onChanged: enabled
                  ? (v) {
                      if (v == null) return;
                      if (v == -1) {
                        // Custom: parse current text-field state. May be
                        // empty until the user types something, in which
                        // case the offset stays null and validation will
                        // surface the empty error.
                        final parsed =
                            int.tryParse(customController.text.trim());
                        onChanged(true, parsed, true);
                      } else {
                        onChanged(true, v, false);
                      }
                    }
                  : null,
            ),
            if (isCustom) ...[
              const SizedBox(height: 8),
              TextField(
                controller: customController,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Custom offset (ledgers)',
                  hintText: 'e.g., 5760',
                  border: OutlineInputBorder(),
                ),
                onChanged: (txt) {
                  final parsed = int.tryParse(txt.trim());
                  onChanged(true, parsed, true);
                },
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'The rule will expire after the selected duration from the '
              'current ledger.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (existingExpiryLedger != null) ...[
              const SizedBox(height: 4),
              Text(
                'Current on-chain expiry: ledger $existingExpiryLedger. '
                'Select a duration above to replace it.',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.isEditMode,
    required this.isSubmitting,
    required this.progressMessage,
    required this.enabled,
    required this.disabledHint,
    required this.onSubmit,
  });

  final bool isEditMode;
  final bool isSubmitting;
  final String progressMessage;
  final bool enabled;
  final String? disabledHint;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final label = isEditMode ? 'Apply Changes' : 'Create Context Rule';
    // In edit-mode, surface the per-step progress message inside the
    // button's loading label so the user sees which on-chain operation is
    // currently running. The verbatim progress text already includes the
    // rule ID.
    final loadingLabel = isEditMode && progressMessage.isNotEmpty
        ? progressMessage
        : 'Submitting...';
    return LoadingButton(
      label: label,
      loadingLabel: loadingLabel,
      action: onSubmit,
      enabled: enabled,
      isLoading: isSubmitting,
      disabledHint: disabledHint,
    );
  }
}

class _SuccessCard extends StatelessWidget {
  const _SuccessCard({
    required this.hash,
    required this.colorScheme,
    required this.textTheme,
  });

  final String hash;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.successBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Transaction Successful',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.successForeground,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            button: true,
            label: 'Copy transaction hash',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => copyAndToast(
                context,
                hash,
                message: 'Hash copied to clipboard',
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    'Hash: $hash',
                    style: textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: colorScheme.successForeground,
                    ),
                  ),
                  Text(
                    'Tap to Copy',
                    style: textTheme.labelSmall?.copyWith(
                      color:
                          colorScheme.successForeground.withAlpha(180),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Go Back'),
            ),
          ),
        ],
      ),
    );
  }
}
