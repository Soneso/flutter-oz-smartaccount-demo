/// Card displayed after a wallet is successfully created and deployed.
library;

import 'package:flutter/material.dart';

import '../flows/wallet_creation_flow.dart';
import '../theme/spacing.dart';
import '../util/format_utils.dart';
import 'loading_button.dart';
import 'result_field.dart';

// ---------------------------------------------------------------------------
// DeployedResultCard
// ---------------------------------------------------------------------------

/// Displays the outcome of a successful wallet creation where the contract
/// was deployed on-chain.
///
/// Fields shown:
/// - Credential ID
/// - Contract Address
/// - Transaction Hash (conditional — omitted when not present in [result])
/// - Balance section with XLM (always shown when present) and DEMO
///   (conditional — shown when [result.demoTokenBalance] is non-null)
///
/// Footer: "Go to Main Screen" button that pops the current route.
class DeployedResultCard extends StatelessWidget {
  /// Creates a [DeployedResultCard].
  const DeployedResultCard({
    required this.result,
    required this.onGoToMainScreen,
    super.key,
  });

  /// The successful creation result to display.
  final WalletCreationResult result;

  /// Called when the user taps "Go to Main Screen".
  final VoidCallback onGoToMainScreen;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              label: 'Wallet Created Successfully',
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    color: colorScheme.primary,
                    size: 20,
                    semanticLabel: '',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Wallet Created Successfully',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ResultField(
              label: 'Credential ID',
              value: result.credentialId,
              semanticValue: redactId(result.credentialId),
            ),
            const SizedBox(height: 8),
            ResultField(
              label: 'Contract Address',
              value: result.contractAddress,
            ),
            if (result.transactionHash != null) ...[
              const SizedBox(height: 8),
              ResultField(
                label: 'Transaction Hash',
                value: result.transactionHash!,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Balance',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            if (result.xlmBalance != null)
              Text(
                '${result.xlmBalance} XLM',
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurface,
                ),
              ),
            if (result.demoTokenBalance != null) ...[
              const SizedBox(height: 2),
              Text(
                '${result.demoTokenBalance} DEMO',
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurface,
                ),
              ),
            ],
            const SizedBox(height: 20),
            LoadingButton(
              label: 'Go to Main Screen',
              style: LoadingButtonStyle.outlined,
              action: () async => onGoToMainScreen(),
            ),
          ],
        ),
      ),
    );
  }
}
