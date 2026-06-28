/// Main dashboard screen.
///
/// This screen reads from [DemoStateNotifier] and [ActivityLogNotifier] via
/// Riverpod and delegates every SDK interaction to [MainScreenFlow]. Screens
/// must not call into the SDK directly.
///
/// State branches:
/// - Not Connected: placeholder with [Create Wallet] and [Connect Wallet] CTAs.
/// - Connected + Not Deployed: [WalletStatusCard] with an embedded undeployed
///   warning; no balance section, no navigation grid.
/// - Connected + Deployed: full [WalletStatusCard] with balances, navigation
///   grid, and the outlined [Disconnect] button.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../flows/main_screen_flow.dart';
import '../navigation/routes.dart';
import '../state/demo_state.dart';
import '../state/main_screen_flow_provider.dart';
import '../state/pending_request_count_provider.dart';
import '../state/theme_mode_provider.dart';
import '../theme/spacing.dart';
import '../widgets/activity_log_card.dart';
import '../widgets/wallet_status_card.dart';

// ---------------------------------------------------------------------------
// MainScreen
// ---------------------------------------------------------------------------

/// Main dashboard screen showing the wallet status, activity log, and
/// navigation to all primary features.
///
/// Kit initialisation:
/// [MainScreenFlow.initializeKit] is called from [State.initState]. The flow
/// guards re-entrancy internally so re-mounts do not build a second kit.
///
/// Pull-to-refresh:
/// When the wallet is connected and deployed, pulling down the scroll view
/// calls [MainScreenFlow.refreshBalances].
///
/// Screens-never-call-SDK rule:
/// This screen interacts only with [MainScreenFlow], [DemoStateNotifier], and
/// [ActivityLogNotifier]. It never references the smart account kit or any of
/// its managers directly.
class MainScreen extends ConsumerStatefulWidget {
  /// Creates a [MainScreen].
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  late final MainScreenFlow _flow;

  /// Periodically refreshes the account-scoped pending-escalation count while
  /// the main screen is visible, so the inbox bell badge lights up when the
  /// agent escalates a call without the user having to pull-to-refresh. Owned
  /// by the widget and cancelled in [dispose]; the count provider holds no
  /// timer of its own.
  Timer? _badgeRefreshTimer;

  /// How often the bell badge is refreshed while the main screen is mounted.
  static const Duration _badgeRefreshInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    // Source the shared flow from the provider so [MainScreen] and
    // [WalletCreationScreen] operate on the same instance.
    _flow = ref.read(mainScreenFlowProvider);
    // Defer kit initialisation past the first frame. initializeKit() has a
    // synchronous error path that calls setBootstrapError() on the demo
    // state notifier; if that mutation fires while the widget tree is
    // still mounting Riverpod rejects it. The post-frame callback ensures
    // the first frame is committed before any state mutation can happen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _flow.initializeKit().then((_) {
        if (mounted) _flow.refreshBalances();
      });
      // Load the pending-escalation count immediately so the inbox bell badge
      // is populated on the first frame; the periodic timer started below keeps
      // it live while the main screen is visible.
      unawaited(ref.read(pendingRequestCountProvider.notifier).refresh());
    });
    _startBadgeRefreshTimer();
  }

  @override
  void dispose() {
    _badgeRefreshTimer?.cancel();
    super.dispose();
  }

  /// Starts the periodic bell-badge refresh. Each tick reloads the
  /// account-scoped pending count, but only while a wallet is connected — the
  /// inbox is account-scoped, so a disconnected app has nothing to surface.
  void _startBadgeRefreshTimer() {
    _badgeRefreshTimer = Timer.periodic(_badgeRefreshInterval, (_) {
      if (!mounted) return;
      if (ref.read(demoStateProvider).contractId == null) return;
      unawaited(ref.read(pendingRequestCountProvider.notifier).refresh());
    });
  }

  /// Pull-to-refresh refreshes the balances and the pending-escalation count
  /// together, so the bell badge tracks the latest server state.
  Future<void> _onPullToRefresh() async {
    await Future.wait<void>(<Future<void>>[
      _flow.refreshBalances(),
      ref.read(pendingRequestCountProvider.notifier).refresh(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(demoStateProvider);

    // Drive the inbox bell badge from the connection state: the inbox is scoped
    // to the connected smart account, so refresh the count when an account
    // connects (or changes) and reset it to zero on disconnect.
    ref.listen<String?>(
      demoStateProvider.select((s) => s.contractId),
      (previous, next) {
        final notifier = ref.read(pendingRequestCountProvider.notifier);
        if (next == null) {
          notifier.reset();
        } else {
          unawaited(notifier.refresh());
        }
      },
    );

    return Scaffold(
      appBar: _buildAppBar(context),
      body: RefreshIndicator(
        onRefresh: _onPullToRefresh,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: kCardPadding,
              sliver: SliverList(
                delegate: SliverChildListDelegate(
                  _buildBody(context, connectionState),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      centerTitle: false,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Stellar Smart Account Demo',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            'Testnet',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onPrimary
                      .withAlpha(200),
                ),
          ),
        ],
      ),
      actions: const [
        _ApprovalInboxBell(),
        _ThemeModeToggle(),
        SizedBox(width: 8),
      ],
    );
  }

  List<Widget> _buildBody(
    BuildContext context,
    WalletConnectionState state,
  ) {
    if (!state.isConnected) {
      return _buildNotConnectedBranch(context);
    }

    return [
      WalletStatusCard(
        onRefresh: _flow.refreshBalances,
        onDisconnect: _flow.disconnect,
        onDeployNow: () {
          final credentialId = state.credentialId ?? '';
          return _flow.deployPendingAndProvision(
            credentialId: credentialId,
          );
        },
      ),
      const SizedBox(height: 12),
      const ActivityLogCard(),
      // Ensure there is always enough content to enable pull-to-refresh
      // even on short screens.
      const SizedBox(height: 40),
    ];
  }

  List<Widget> _buildNotConnectedBranch(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return [
      const SizedBox(height: 40),
      Semantics(
        label: 'No wallet connected',
        child: Center(
          child: Text(
            'No wallet connected',
            style: textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface.withAlpha(160),
            ),
          ),
        ),
      ),
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => context.push(AppRoutes.walletCreation),
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('Create Wallet'),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => context.push(AppRoutes.walletConnection),
          icon: const Icon(Icons.link),
          label: const Text('Connect Wallet'),
        ),
      ),
      const SizedBox(height: 32),
      const ActivityLogCard(),
      const SizedBox(height: 40),
    ];
  }
}

/// AppBar action: a bell that opens the approval inbox, badged with the number
/// of pending agent escalations when greater than zero.
class _ApprovalInboxBell extends ConsumerWidget {
  const _ApprovalInboxBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingRequestCountProvider);
    final tooltip = count > 0
        ? 'Approval inbox ($count pending)'
        : 'Approval inbox';
    final icon = Icon(
      count > 0 ? Icons.notifications_active_outlined : Icons.notifications_none,
    );
    return IconButton(
      tooltip: tooltip,
      onPressed: () => context.push(AppRoutes.approvalInbox),
      icon: count > 0
          ? Badge.count(count: count, child: icon)
          : icon,
    );
  }
}

/// AppBar action that cycles the persisted [ThemeMode] (light → dark →
/// system) and renders the icon matching the current mode.
class _ThemeModeToggle extends ConsumerWidget {
  const _ThemeModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final (icon, tooltip) = switch (mode) {
      ThemeMode.light => (Icons.light_mode_outlined, 'Light mode (tap for dark)'),
      ThemeMode.dark => (Icons.dark_mode_outlined, 'Dark mode (tap for system)'),
      ThemeMode.system => (Icons.brightness_auto_outlined, 'System theme (tap for light)'),
    };
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: () => ref.read(themeModeProvider.notifier).cycle(),
    );
  }
}
