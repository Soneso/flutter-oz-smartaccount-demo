/// Success result card shown after a token transfer completes.
///
/// Displays the transaction hash (with copy button), amount sent, recipient,
/// and updated balances.
library;

import 'package:flutter/material.dart';

import '../flows/transfer_flow.dart';
import '../theme/spacing.dart';
import '../util/format_utils.dart';
import 'copyable_hash_row.dart';

// ---------------------------------------------------------------------------
// TransferResultCard
// ---------------------------------------------------------------------------

/// Card shown on successful completion of a token transfer.
///
/// Shows the labels "Transfer Successful", "Transaction Hash", "Amount Sent",
/// "Recipient", and "Updated Balance".
///
/// The transaction hash field includes a [Copy] button that writes the
/// full hash to the clipboard and shows a "Transaction hash copied" snackbar.
class TransferResultCard extends StatelessWidget {
  /// Creates a [TransferResultCard].
  const TransferResultCard({
    required this.result,
    required this.xlmBalance,
    required this.demoTokenBalance,
    required this.onNewTransfer,
    required this.onGoToMainScreen,
    super.key,
  });

  /// The successful transfer result.
  final TransferResult result;

  /// Current XLM balance string to display (may be stale if refresh failed).
  final String? xlmBalance;

  /// Current DEMO token balance string, or null when not available.
  final String? demoTokenBalance;

  /// Called when the user taps "New Transfer".
  final VoidCallback onNewTransfer;

  /// Called when the user taps "Go to Main Screen".
  final VoidCallback onGoToMainScreen;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          elevation: 0,
          color: colorScheme.primaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: colorScheme.primary.withAlpha(60),
            ),
          ),
          child: Padding(
            padding: kCardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Semantics(
                  header: true,
                  child: Text(
                    'Transfer Successful',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Transaction Hash
                _buildLabel(
                  'Transaction Hash',
                  colorScheme,
                  textTheme,
                ),
                const SizedBox(height: 4),
                CopyableHashRow(
                  hash: result.transactionHash,
                  displayText: truncateAddress(result.transactionHash),
                  color: colorScheme.onPrimaryContainer,
                  semanticValue: redactId(result.transactionHash),
                ),
                const SizedBox(height: 12),

                // Amount Sent
                _buildLabel('Amount Sent', colorScheme, textTheme),
                const SizedBox(height: 4),
                Text(
                  '${result.amount} ${result.tokenLabel}',
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 12),

                // Recipient
                _buildLabel('Recipient', colorScheme, textTheme),
                const SizedBox(height: 4),
                Semantics(
                  label: 'Recipient: ${redactId(result.recipient)}',
                  excludeSemantics: true,
                  child: Text(
                    truncateAddress(result.recipient),
                    style: textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: colorScheme.onPrimaryContainer,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 12),

                // Updated Balance
                _buildLabel('Updated Balance', colorScheme, textTheme),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 16,
                  children: [
                    Text(
                      '${xlmBalance ?? "0.0"} XLM',
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    if (demoTokenBalance != null)
                      Text(
                        '$demoTokenBalance DEMO',
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // New Transfer button
        FilledButton(
          onPressed: onNewTransfer,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text(
            'New Transfer',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),

        // Go to Main Screen button
        FilledButton(
          onPressed: onGoToMainScreen,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text(
            'Go to Main Screen',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Widget _buildLabel(
    String text,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Text(
      text,
      style: textTheme.labelMedium?.copyWith(
        color: colorScheme.onPrimaryContainer.withAlpha(180),
        fontWeight: FontWeight.w600,
      ),
    );
  }

}
