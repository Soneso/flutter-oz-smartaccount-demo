/// Card displayed after a passkey is registered but the contract was not
/// deployed (autoSubmit was false).
library;

import 'package:flutter/material.dart';

import '../flows/wallet_creation_flow.dart';
import '../theme/spacing.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import '../util/semantic_colors.dart';
import 'loading_button.dart';
import 'result_field.dart';

// ---------------------------------------------------------------------------
// UndeployedResultCard
// ---------------------------------------------------------------------------

/// Displays the outcome of a wallet creation where the passkey was registered
/// but the smart account contract was not deployed yet.
///
/// Fields shown:
/// - Credential ID
/// - Contract Address (derived)
///
/// Warning banner explaining the pending state. A "Deploy Now" button lets the
/// user deploy immediately from this card without navigating away. On success
/// the parent is notified via [onDeploySucceeded] so it can swap to
/// [DeployedResultCard]. On failure an inline error is shown and the Deploy Now
/// button is disabled to prevent a double-submit against a partially-deployed
/// credential.
///
/// Footer: "Go to Main Screen" button.
class UndeployedResultCard extends StatefulWidget {
  /// Creates an [UndeployedResultCard].
  const UndeployedResultCard({
    required this.result,
    required this.onDeployNow,
    required this.onGoToMainScreen,
    this.onDeploySucceeded,
    super.key,
  });

  /// The creation result (isDeployed == false).
  final WalletCreationResult result;

  /// Called when the user taps "Deploy Now".
  ///
  /// The caller closes over the credential ID and calls
  /// [MainScreenFlow.deployPendingAndProvision]. On success the parent widget
  /// should rebuild showing [DeployedResultCard]. Any error thrown is caught
  /// by this card and displayed inline.
  final Future<void> Function() onDeployNow;

  /// Called when the user taps "Go to Main Screen".
  final VoidCallback onGoToMainScreen;

  /// Called after [onDeployNow] completes without error.
  ///
  /// The parent screen uses this callback to reconstruct an updated
  /// [WalletCreationResult] with [isDeployed] set to true and then calls
  /// [setState] to swap this card for [DeployedResultCard]. The card itself
  /// stays presentation-focused and does not read [DemoState] directly.
  final VoidCallback? onDeploySucceeded;

  @override
  State<UndeployedResultCard> createState() => _UndeployedResultCardState();
}

class _UndeployedResultCardState extends State<UndeployedResultCard> {
  bool _isDeploying = false;
  String? _deployError;

  Future<void> _handleDeployNow() async {
    setState(() {
      _isDeploying = true;
      _deployError = null;
    });
    try {
      await widget.onDeployNow();
      widget.onDeploySucceeded?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _deployError = classifyError(e).message;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isDeploying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final deployFailed = _deployError != null;

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
              label: 'Passkey Registered',
              child: Text(
                'Passkey Registered',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            ResultField(
              label: 'Credential ID',
              value: widget.result.credentialId,
              semanticValue: redactId(widget.result.credentialId),
            ),
            const SizedBox(height: 8),
            ResultField(
              label: 'Contract Address (derived)',
              value: widget.result.contractAddress,
            ),
            const SizedBox(height: 12),
            // Warning banner
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.warningContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.onWarningContainer.withAlpha(80),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: colorScheme.onWarningContainer,
                    size: 16,
                    semanticLabel: '',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The wallet contract has not been deployed to the '
                      'network yet. Deploy it now or later from the '
                      'Connect Wallet screen.',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onWarningContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Deploy Now is disabled after a failure to prevent double-submit.
            Opacity(
              opacity: deployFailed ? 0.5 : 1.0,
              child: LoadingButton(
                label: 'Deploy Now',
                loadingLabel: 'Deploying...',
                action: deployFailed ? () async {} : _handleDeployNow,
              ),
            ),
            Semantics(
              liveRegion: true,
              label: 'Deploying contract',
              enabled: _isDeploying,
              child: _isDeploying
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                        child: Text(
                          'Deploying contract...',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withAlpha(160),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Semantics(
              liveRegion: true,
              label: deployFailed
                  ? 'Deploy failed: ${_deployError ?? ''}'
                  : 'Deploy error',
              enabled: deployFailed,
              child: deployFailed
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onErrorContainer,
                            ),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Retry from the Connect Wallet screen.',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 16),
            LoadingButton(
              label: 'Go to Main Screen',
              style: LoadingButtonStyle.outlined,
              action: () async => widget.onGoToMainScreen(),
            ),
          ],
        ),
      ),
    );
  }
}
