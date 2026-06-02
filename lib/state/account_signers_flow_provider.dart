/// Riverpod provider for the shared [AccountSignersFlow] singleton.
///
/// Follows the same pattern as [contextRuleFlowProvider]: a [Provider] that
/// reads notifiers via [ref.read] so the flow instance is stable across
/// rebuilds. Returns null when no kit is present (kit not yet initialised).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/account_signers_flow.dart';
import '../flows/transfer_flow.dart' show ContextRuleManagerAdapter;
import 'activity_log_state.dart';
import 'demo_state.dart';

/// Provider for the [AccountSignersFlow] instance.
///
/// Re-evaluated whenever the enclosing [ProviderScope] rebuilds (e.g. kit
/// initialisation). Returns null when no kit is available.
final accountSignersFlowProvider = Provider<AccountSignersFlow?>((ref) {
  final demoState = ref.read(demoStateProvider.notifier);
  final activityLog = ref.read(activityLogProvider.notifier);
  return buildAccountSignersFlow(
    demoState: demoState,
    activityLog: activityLog,
  );
});

/// Builds an [AccountSignersFlow] from injected dependencies.
///
/// Returns null when the kit is not yet initialised.
AccountSignersFlow? buildAccountSignersFlow({
  required DemoStateNotifier demoState,
  required ActivityLogNotifier activityLog,
}) {
  final kit = demoState.kit;
  if (kit == null) return null;

  return AccountSignersFlow(
    demoState: demoState,
    activityLog: activityLog,
    contextRuleManager: ContextRuleManagerAdapter(kit.contextRuleManager),
  );
}
