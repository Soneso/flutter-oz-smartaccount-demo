/// Riverpod provider for the shared [ApproveFlow] singleton.
///
/// Follows the same pattern as [transferFlowProvider]: a [Provider] that
/// reads notifiers via [ref.read] so the flow instance is stable across
/// rebuilds. Returns null when no kit is present (kit not yet initialised).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/approve_flow.dart';
import 'activity_log_state.dart';
import 'context_rule_flow_provider.dart';
import 'demo_state.dart';

/// Provider for the [ApproveFlow] instance.
///
/// Re-evaluated whenever the enclosing [ProviderScope] rebuilds (e.g. kit
/// initialisation). Returns null when no kit is available.
final approveFlowProvider = Provider<ApproveFlow?>((ref) {
  final demoState = ref.read(demoStateProvider.notifier);
  final activityLog = ref.read(activityLogProvider.notifier);
  final contextRuleFlow = ref.read(contextRuleFlowProvider);
  if (contextRuleFlow == null) return null;

  final kit = demoState.kit;
  if (kit == null) return null;

  return ApproveFlow(
    demoState: demoState,
    activityLog: activityLog,
    contractCall: ContractCallAdapter(kit.transactionOperations),
    multiSignerContractCall:
        MultiSignerContractCallAdapter(kit.multiSignerManager),
    contextRuleFlow: contextRuleFlow,
    allowanceFetcher: AllowanceFetcherAdapter(kit),
  );
});
