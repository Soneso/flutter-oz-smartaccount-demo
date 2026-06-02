/// Riverpod provider for the shared [ContextRuleFlow] singleton.
///
/// Follows the same pattern as [transferFlowProvider]: a [Provider] that
/// reads notifiers via [ref.read] so the flow instance is stable across
/// rebuilds. Returns null when no kit is present (kit not yet initialised).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/context_rule_flow.dart';
import 'activity_log_state.dart';
import 'demo_state.dart';

/// Provider for the [ContextRuleFlow] instance.
///
/// Re-evaluated whenever the enclosing [ProviderScope] rebuilds (e.g. kit
/// initialisation). Returns null when no kit is available.
final contextRuleFlowProvider = Provider<ContextRuleFlow?>((ref) {
  final demoState = ref.read(demoStateProvider.notifier);
  final activityLog = ref.read(activityLogProvider.notifier);
  return buildContextRuleFlow(
    demoState: demoState,
    activityLog: activityLog,
  );
});

/// Builds a [ContextRuleFlow] from injected dependencies.
///
/// Returns null when the kit is not yet initialised.
ContextRuleFlow? buildContextRuleFlow({
  required DemoStateNotifier demoState,
  required ActivityLogNotifier activityLog,
}) {
  final kit = demoState.kit;
  if (kit == null) return null;

  return ContextRuleFlow(
    demoState: demoState,
    activityLog: activityLog,
    contextRuleManager: ContextRuleManagerFlowAdapter(kit),
    environment: ContextRuleBuilderEnvironmentAdapter(kit),
  );
}
