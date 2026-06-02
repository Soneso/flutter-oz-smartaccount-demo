/// Card displaying the connected wallet status, balances, navigation, and
/// disconnect action.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../navigation/routes.dart';
import '../state/demo_state.dart';
import '../theme/spacing.dart';
import '../util/clipboard.dart';
import '../util/format_utils.dart';
import 'button_label.dart';
import 'loading_label.dart';
import 'undeployed_wallet_warning_card.dart';

// ---------------------------------------------------------------------------
// WalletStatusCard
// ---------------------------------------------------------------------------

/// Primary connected-state surface on the main dashboard.
///
/// The card uses [ColorScheme.primaryContainer] as its background so it stands
/// out as the focal point of the screen when a wallet is connected.
///
/// Layout:
/// - Contract Address row with a `Copy` button (shows a snackbar on copy).
/// - Credential ID row (monospace, no copy button per spec).
/// - [UndeployedWalletWarningCard] when the contract is not yet deployed.
/// - Balance section (XLM + DEMO) with a `Refresh` / `Refreshing...` button
///   (only when deployed).
/// - Navigation grid: `Context Rules`, `Transfer`, `Approve`,
///   `Account Signers` — tappable only when deployed.
/// - Outlined `Disconnect` button.
///
/// [onRefresh] and [onDisconnect] are async callbacks so the parent can wire
/// them to [MainScreenFlow] without this widget holding a flow reference.
/// [onDeployNow] is the deploy-pending callback forwarded to
/// [UndeployedWalletWarningCard]. The flow handles all error logging; the
/// warning card handles inline error display internally.
class WalletStatusCard extends ConsumerWidget {
  /// Creates a [WalletStatusCard].
  const WalletStatusCard({
    required this.onRefresh,
    required this.onDisconnect,
    required this.onDeployNow,
    super.key,
  });

  /// Called when the user taps `Refresh`. Shows "Refreshing..." while running.
  final Future<void> Function() onRefresh;

  /// Called when the user taps `Disconnect`. Delegate clears demo state.
  final Future<void> Function() onDisconnect;

  /// Called when the user taps `Deploy Now` in the undeployed warning card.
  ///
  /// The caller closes over any credential ID it needs. Errors thrown by this
  /// callback are caught and displayed inline by [UndeployedWalletWarningCard].
  final Future<void> Function() onDeployNow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(demoStateProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final contractId = state.contractId ?? '';
    final credentialId = state.credentialId ?? '';
    final truncated = _truncateContractAddress(contractId);

    return Container(
      width: double.infinity,
      padding: kCardPadding,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Wallet Status',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onPrimaryContainer,
                  ),
            ),
          ),
          const SizedBox(height: 8),
          Divider(color: colorScheme.onPrimaryContainer.withAlpha(40)),
          const SizedBox(height: 8),

          // Contract Address row.
          _AddressRow(
            label: 'Contract Address:',
            value: truncated,
            onCopy: () => _copyContractAddress(context, contractId),
          ),
          const SizedBox(height: 8),

          // Credential ID row.
          _LabelValueRow(
            label: 'Credential ID:',
            value: credentialId,
            monospace: true,
          ),

          // Undeployed warning (visible only when not deployed).
          if (state.isConnected && !state.isDeployed) ...[
            const SizedBox(height: 12),
            UndeployedWalletWarningCard(
              onDeployNow: onDeployNow,
            ),
          ],

          // Balance section (only when deployed).
          if (state.isDeployed) ...[
            const SizedBox(height: 12),
            Divider(color: colorScheme.onPrimaryContainer.withAlpha(40)),
            const SizedBox(height: 8),
            _BalanceSection(
              xlmBalance: state.xlmBalance,
              demoBalance: state.demoTokenBalance,
              onRefresh: onRefresh,
            ),
            const SizedBox(height: 12),
            Divider(color: colorScheme.onPrimaryContainer.withAlpha(40)),
            const SizedBox(height: 8),

            // Navigation grid — enabled only when deployed.
            const _DeployedNavigationGrid(),
          ],

          const SizedBox(height: 8),

          // Low-emphasis Disconnect action, always shown when connected.
          // Disconnect errors are logged by the flow internally; no screen-side
          // handler is needed.
          Center(child: _DisconnectButton(onDisconnect: onDisconnect)),
        ],
      ),
    );
  }

  Future<void> _copyContractAddress(BuildContext context, String address) {
    return copyAndToast(
      context,
      address,
      message: 'Contract address copied',
    );
  }

  /// Truncates a contract address to 12 chars at each end with "..." in the
  /// middle, matching the canonical display format for wallet addresses.
  static String _truncateContractAddress(String address) {
    return truncateAddress(address, chars: 12);
  }
}

// ---------------------------------------------------------------------------
// _AddressRow
// ---------------------------------------------------------------------------

class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onPrimaryContainer.withAlpha(180),
                fontWeight: FontWeight.w500,
              ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onPrimaryContainer,
                ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Copy contract address',
          onPressed: onCopy,
          visualDensity: VisualDensity.compact,
          icon: Icon(
            Icons.copy_outlined,
            size: 18,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _LabelValueRow
// ---------------------------------------------------------------------------

class _LabelValueRow extends StatelessWidget {
  const _LabelValueRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onPrimaryContainer.withAlpha(180),
                fontWeight: FontWeight.w500,
              ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: monospace ? 'monospace' : null,
                  color: colorScheme.onPrimaryContainer,
                ),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _BalanceSection
// ---------------------------------------------------------------------------

class _BalanceSection extends StatefulWidget {
  const _BalanceSection({
    required this.xlmBalance,
    required this.demoBalance,
    required this.onRefresh,
  });

  final String? xlmBalance;
  final String? demoBalance;
  final Future<void> Function() onRefresh;

  @override
  State<_BalanceSection> createState() => _BalanceSectionState();
}

class _BalanceSectionState extends State<_BalanceSection> {
  bool _isRefreshing = false;

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final xlmBalance = widget.xlmBalance;
    final demoBalance = widget.demoBalance;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Balance:',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onPrimaryContainer.withAlpha(180),
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: xlmBalance != null
                        ? 'XLM balance: $xlmBalance'
                        : 'XLM balance: loading',
                    excludeSemantics: true,
                    child: Text(
                      '${xlmBalance ?? "Loading..."} XLM',
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onPrimaryContainer,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (demoBalance != null) ...[
                    const SizedBox(height: 2),
                    Semantics(
                      label: 'DEMO balance: $demoBalance',
                      excludeSemantics: true,
                      child: Text(
                        '$demoBalance DEMO',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onPrimaryContainer.withAlpha(200),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 2),
                    Text(
                      '0.0 DEMO',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onPrimaryContainer.withAlpha(160),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip:
                  _isRefreshing ? 'Refreshing balances' : 'Refresh balances',
              onPressed: _isRefreshing ? null : _handleRefresh,
              icon: _isRefreshing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _DeployedNavigationGrid
// ---------------------------------------------------------------------------

class _DeployedNavigationGrid extends StatelessWidget {
  const _DeployedNavigationGrid();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        _NavRow(
          left: _NavAction(
            label: 'Context Rules',
            route: AppRoutes.contextRules,
          ),
          right: _NavAction(label: 'Transfer', route: AppRoutes.transfer),
        ),
        SizedBox(height: 10),
        _NavRow(
          left: _NavAction(label: 'Approve', route: AppRoutes.approve),
          right: _NavAction(
            label: 'Account Signers',
            route: AppRoutes.accountSigners,
          ),
        ),
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.left, required this.right});

  final _NavAction left;
  final _NavAction right;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: left),
        const SizedBox(width: 10),
        Expanded(child: right),
      ],
    );
  }
}

class _NavAction extends StatelessWidget {
  const _NavAction({required this.label, required this.route});

  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: () => context.push(route),
        child: ButtonLabel(label),
      ),
    );
  }
}

class _DisconnectButton extends StatefulWidget {
  const _DisconnectButton({required this.onDisconnect});

  final Future<void> Function() onDisconnect;

  @override
  State<_DisconnectButton> createState() => _DisconnectButtonState();
}

class _DisconnectButtonState extends State<_DisconnectButton> {
  bool _isDisconnecting = false;

  Future<void> _handle() async {
    if (_isDisconnecting) return;
    setState(() => _isDisconnecting = true);
    try {
      await widget.onDisconnect();
    } finally {
      if (mounted) setState(() => _isDisconnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: _isDisconnecting ? null : _handle,
      child: _isDisconnecting
          ? LoadingLabel(
              label: 'Disconnecting...',
              color: colorScheme.primary,
              size: 14,
            )
          : const Text('Disconnect'),
    );
  }
}
