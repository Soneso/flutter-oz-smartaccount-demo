/// Card widget for a single pending (undeployed) credential.
///
/// Displays a truncated credential ID and contract ID alongside "Retry Deploy"
/// and "Delete" action buttons. The screen controls enabled state based on
/// which section is active; this widget exposes [enabled] and [isDeploying]
/// to drive those states.
library;

import 'package:flutter/material.dart';

import '../util/format_utils.dart';
import 'loading_button.dart';

// ---------------------------------------------------------------------------
// PendingCredentialCard
// ---------------------------------------------------------------------------

/// A card row that represents one pending credential awaiting on-chain
/// deployment.
///
/// Layout:
/// - Truncated credential ID (first 12 / last 8 characters).
/// - Truncated contract ID (first 12 / last 12 characters), or "Unknown".
/// - "Retry Deploy" (primary, left) and "Delete" (outlined, right) buttons.
///
/// Inline error [errorMessage] is shown beneath the buttons when non-null.
/// The card uses a surface background with an error-coloured border to draw
/// attention to the undeployed state while maintaining Material 3 AA contrast.
class PendingCredentialCard extends StatelessWidget {
  /// Creates a [PendingCredentialCard].
  const PendingCredentialCard({
    required this.credentialId,
    this.contractId,
    this.nickname,
    this.enabled = true,
    this.isDeploying = false,
    this.errorMessage,
    required this.onRetryDeploy,
    required this.onDelete,
    super.key,
  });

  /// Raw Base64URL credential ID. Displayed in truncated form.
  final String credentialId;

  /// Smart account contract address (C-address), or null when not yet known.
  final String? contractId;

  /// Optional display name for the credential.
  final String? nickname;

  /// Whether the action buttons are interactive.
  ///
  /// Set to false when another section is in-flight.
  final bool enabled;

  /// True while the "Retry Deploy" action is executing for this specific card.
  ///
  /// Disables both buttons and shows the deploying spinner on "Retry Deploy".
  final bool isDeploying;

  /// Inline error shown beneath the buttons when non-null.
  final String? errorMessage;

  /// Called when the user taps "Retry Deploy".
  final Future<void> Function() onRetryDeploy;

  /// Called when the user taps "Delete".
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final displayCredId = truncateCredentialId(credentialId, nickname: nickname);

    return Semantics(
      container: true,
      label: 'Pending credential $displayCredId',
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: colorScheme.error.withAlpha(80),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLabeledField(
              context,
              label: 'Credential ID:',
              value: displayCredId,
            ),
            const SizedBox(height: 6),
            _buildLabeledField(
              context,
              label: 'Contract ID:',
              value: truncateContractId(contractId),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    enabled: enabled && !isDeploying,
                    child: LoadingButton(
                      label: 'Retry Deploy',
                      loadingLabel: 'Deploying...',
                      action: onRetryDeploy,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    enabled: enabled && !isDeploying,
                    child: LoadingButton(
                      label: 'Delete',
                      style: LoadingButtonStyle.outlined,
                      action: onDelete,
                    ),
                  ),
                ),
              ],
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                enabled: errorMessage != null,
                child: Text(
                  errorMessage!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLabeledField(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: '$label $value',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Returns the display form of [credentialId].
  ///
  /// Delegates to [truncateCredentialId] from `format_utils.dart`.
  /// Exposed as a static method so unit tests can verify the formatting
  /// logic independently of the widget tree.
  static String formatCredentialId(String credentialId, String? nickname) =>
      truncateCredentialId(credentialId, nickname: nickname);
}
