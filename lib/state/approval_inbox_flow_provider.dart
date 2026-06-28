/// Riverpod provider for the shared [ApprovalInboxFlow] singleton.
///
/// Follows the same pattern as [approveFlowProvider]: a [Provider] that reads
/// the notifiers via [ref.read] so the flow instance is stable across
/// rebuilds. Unlike the approve flow, this provider always returns a flow (not
/// null) because the inbox listing and the bell badge must work before a
/// wallet is connected; the single-signer submission adapter is resolved
/// lazily on each approve via the connected kit, so a kit that becomes
/// available after this flow is built is still picked up.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/approval_inbox_flow.dart';
import '../flows/approve_flow.dart' show ContractCallAdapter, ContractCallType;
import 'activity_log_state.dart';
import 'coordination_client_provider.dart';
import 'demo_state.dart';

/// Provider for the [ApprovalInboxFlow] instance.
final approvalInboxFlowProvider = Provider<ApprovalInboxFlow>((ref) {
  final coordination = ref.watch(coordinationClientProvider);
  final activityLog = ref.read(activityLogProvider.notifier);
  final demoState = ref.read(demoStateProvider.notifier);

  return ApprovalInboxFlow(
    coordination: coordination,
    activityLog: activityLog,
    resolveContractCall: () {
      // Resolve the single-signer submission adapter from the connected kit on
      // each approve. Null when no wallet is connected; the flow then short-
      // circuits with a clear "connect a wallet" error.
      final kit = demoState.kit;
      if (kit == null) return null;
      final ContractCallType adapter =
          ContractCallAdapter(kit.transactionOperations);
      return adapter;
    },
    // Resolve the connected smart account on each call so the inbox can scope
    // listings to it and refuse cross-account approvals. Null when disconnected.
    resolveConnectedAccount: () => demoState.currentState.contractId,
  );
});
