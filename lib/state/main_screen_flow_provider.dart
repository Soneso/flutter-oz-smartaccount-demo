/// Riverpod provider for the shared [MainScreenFlow] singleton.
///
/// Both [MainScreen] and [WalletCreationScreen] read from this provider so
/// they share one [MainScreenFlow] instance. Sharing the instance is important
/// for post-creation balance refresh: [WalletCreationFlow] calls
/// [MainScreenFlow.refreshBalances] via the same instance that [MainScreen]
/// uses for pull-to-refresh, so both screens observe the same balance state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/main_screen_flow.dart';
import 'activity_log_state.dart';
import 'demo_state.dart';
import 'demo_token_service_provider.dart';

/// Provider for the shared [MainScreenFlow] instance.
///
/// The flow is created lazily on first access and re-created when the
/// underlying [demoStateProvider] or [activityLogProvider] containers are
/// replaced (e.g. during hot-restart in development). In production a single
/// instance lives for the lifetime of the app.
final mainScreenFlowProvider = Provider<MainScreenFlow>((ref) {
  final demoState = ref.read(demoStateProvider.notifier);
  final activityLog = ref.read(activityLogProvider.notifier);
  final demoTokenService = ref.read(demoTokenServiceProvider);
  return MainScreenFlow(
    demoState: demoState,
    activityLog: activityLog,
    demoTokenService: demoTokenService,
  );
});
