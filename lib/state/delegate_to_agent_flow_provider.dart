/// Riverpod provider for the shared [DelegateToAgentFlow] singleton.
///
/// Follows the same pattern as [approveFlowProvider]: a [Provider] that reads
/// notifiers via [ref.read] and reuses the [ContextRuleFlow] resolved from
/// [contextRuleFlowProvider]. Returns null when no kit / context-rule flow is
/// available (kit not yet initialised).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/delegate_to_agent_flow.dart';
import 'activity_log_state.dart';
import 'context_rule_flow_provider.dart';

/// Provider for the [DelegateToAgentFlow] instance.
///
/// Re-evaluated whenever the enclosing [ProviderScope] rebuilds (e.g. kit
/// initialisation). Returns null when no context-rule flow is available.
final delegateToAgentFlowProvider = Provider<DelegateToAgentFlow?>((ref) {
  final contextRuleFlow = ref.read(contextRuleFlowProvider);
  if (contextRuleFlow == null) return null;
  final activityLog = ref.read(activityLogProvider.notifier);
  return DelegateToAgentFlow(
    contextRuleFlow: contextRuleFlow,
    activityLog: activityLog,
  );
});
