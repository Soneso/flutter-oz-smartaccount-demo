/// Modal bottom sheet for selecting one contract from an ambiguous list.
///
/// Shown when [WalletConnectionFlow.connectViaIndexer] or
/// [WalletConnectionFlow.autoConnect] returns [ConnectionResultAmbiguous].
/// The user selects one candidate contract address and taps "Connect".
library;

import 'package:flutter/material.dart';

import '../util/format_utils.dart';
import 'sheet_header.dart';

// ---------------------------------------------------------------------------
// ContractPickerSheet
// ---------------------------------------------------------------------------

/// A modal bottom sheet that lets the user pick one contract from a list of
/// candidates when the indexer finds multiple wallets for a single passkey.
///
/// The sheet always shows:
/// - A "Select Wallet" title.
/// - A description explaining the ambiguous state.
/// - A radio-button list of candidate contract addresses.
/// - A "Cancel" button (left) and a "Connect" button (right).
///
/// The "Connect" button is disabled until a selection is made.
///
/// Accessibility:
/// - Each radio tile has a full semantics label and is keyboard-navigable.
/// - "Cancel" and "Connect" buttons carry independent hint slots.
///
/// Usage:
/// ```dart
/// final selected = await ContractPickerSheet.show(
///   context: context,
///   candidates: result.candidates,
/// );
/// if (selected != null) { ... }
/// ```
class ContractPickerSheet extends StatefulWidget {
  /// Creates a [ContractPickerSheet] with the supplied [candidates].
  const ContractPickerSheet({
    required this.candidates,
    super.key,
  });

  /// Candidate contract addresses to display.
  final List<String> candidates;

  /// Shows the [ContractPickerSheet] as a modal bottom sheet and returns the
  /// selected contract address, or null when the user cancels.
  static Future<String?> show({
    required BuildContext context,
    required List<String> candidates,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ContractPickerSheet(candidates: candidates),
    );
  }

  @override
  State<ContractPickerSheet> createState() => _ContractPickerSheetState();
}

class _ContractPickerSheetState extends State<ContractPickerSheet> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHandle(colorScheme),
            const SheetHeader(
              title: 'Select Wallet',
              description: 'This passkey is a signer on more than one wallet. '
                  'Pick the one to connect.',
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final candidate in widget.candidates)
                    _buildRadioTile(context, candidate, colorScheme, textTheme),
                ],
              ),
            ),
            _buildActions(context, colorScheme),
          ],
        );
      },
    );
  }

  Widget _buildHandle(ColorScheme colorScheme) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 4),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: colorScheme.onSurfaceVariant.withAlpha(80),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }


  Widget _buildRadioTile(
    BuildContext context,
    String candidate,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final isSelected = _selected == candidate;
    final index = widget.candidates.indexOf(candidate);
    final total = widget.candidates.length;
    // Use truncateContractId for consistent 12/12 display across all surfaces.
    final display = truncateContractId(candidate);

    return Semantics(
      label: 'Wallet option ${index + 1} of $total',
      value: display,
      hint: isSelected ? 'Selected' : 'Tap to select',
      selected: isSelected,
      child: RadioListTile<String>(
        value: candidate,
        groupValue: _selected,
        onChanged: (v) => setState(() => _selected = v),
        title: Text(
          display,
          style: textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        activeColor: colorScheme.primary,
        dense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildActions(BuildContext context, ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              hint: 'Dismisses the wallet picker without connecting.',
              button: true,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              hint: 'Connects to the selected wallet.',
              button: true,
              child: FilledButton(
                onPressed: _selected == null
                    ? null
                    : () => Navigator.of(context).pop(_selected),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text(
                  'Connect',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
