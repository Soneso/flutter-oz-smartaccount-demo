/// Card warning the user that their passkey is registered but the smart
/// account contract has not been deployed yet.
library;

import 'package:flutter/material.dart';

import '../theme/spacing.dart';
import 'loading_button.dart';

// ---------------------------------------------------------------------------
// UndeployedWalletWarningCard
// ---------------------------------------------------------------------------

/// Displays a warning that the smart account contract is not yet deployed and
/// offers a [Deploy Now] action.
///
/// The card uses a yellow/warning tint ([ColorScheme.tertiaryContainer]) so
/// it is visually distinct from primary-surface cards.
///
/// Parameters:
/// - [onDeployNow]: async callback executed when the user taps [Deploy Now].
///   The caller closes over any credential ID it needs. The card shows a
///   "Deploying contract..." status line while the action is in flight.
///
/// Inline error display:
/// When [onDeployNow] throws, the error message is shown inside the card in a
/// small monospace error area. The error is cleared on the next tap so the user
/// always starts with a clean slate. The flow-level activity log entry (written
/// by [MainScreenFlow]) is the source of truth; this inline display is
/// supplementary UX clarity.
///
/// Accessibility:
/// The parent Semantics wrapper uses [excludeSemantics] so children are not
/// double-announced by screen readers. The parent label serves as the semantic
/// landmark; child Text widgets carry no additional semantics.
class UndeployedWalletWarningCard extends StatefulWidget {
  /// Creates an [UndeployedWalletWarningCard].
  const UndeployedWalletWarningCard({
    required this.onDeployNow,
    super.key,
  });

  /// Async action executed when the user taps [Deploy Now].
  ///
  /// The caller is responsible for closing over the credential ID. Any error
  /// thrown is caught by the card and displayed inline.
  final Future<void> Function() onDeployNow;

  @override
  State<UndeployedWalletWarningCard> createState() =>
      _UndeployedWalletWarningCardState();
}

class _UndeployedWalletWarningCardState
    extends State<UndeployedWalletWarningCard> {
  bool _isDeploying = false;
  String? _deployError;

  Future<void> _handleDeploy() async {
    setState(() {
      _isDeploying = true;
      _deployError = null;
    });
    try {
      await widget.onDeployNow();
    } catch (e) {
      if (mounted) {
        setState(() {
          _deployError = _describeError(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isDeploying = false);
      }
    }
  }

  /// Converts an exception to a short, display-safe message.
  static String _describeError(Object error) {
    final raw = error.toString();
    // Truncate extremely long messages so they do not overflow the card.
    if (raw.length > 200) return '${raw.substring(0, 200)}...';
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: 'Wallet Not Deployed. '
          'Your passkey is registered but the smart account contract has not '
          'been deployed to the network. Deploy it to start using your wallet.',
      excludeSemantics: true,
      child: Container(
        padding: kCardPadding,
        decoration: BoxDecoration(
          color: colorScheme.tertiaryContainer.withAlpha(160),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.tertiary.withAlpha(120)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: colorScheme.tertiary,
                  semanticLabel: '',
                ),
                const SizedBox(width: 8),
                Text(
                  'Wallet Not Deployed',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onTertiaryContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Your passkey is registered but the smart account contract has '
              'not been deployed to the network. Deploy it to start using '
              'your wallet.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withAlpha(180),
                  ),
            ),
            const SizedBox(height: 12),
            LoadingButton(
              label: 'Deploy Now',
              loadingLabel: 'Deploying...',
              action: _handleDeploy,
            ),
            // Inline deploying progress line — shown while action is in flight.
            if (_isDeploying) ...[
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Deploying contract...',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface.withAlpha(160),
                      ),
                ),
              ),
            ],
            // Inline deploy-error display — shown when the deploy action throws.
            if (_deployError != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withAlpha(180),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: colorScheme.error.withAlpha(120),
                  ),
                ),
                child: Text(
                  _deployError!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: colorScheme.onErrorContainer,
                      ),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
