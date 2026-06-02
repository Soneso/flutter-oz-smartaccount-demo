/// Riverpod provider for the shared [TransferFlow] singleton.
///
/// Caches the flow for the lifetime of the ProviderScope so [TransferScreen]
/// does not rebuild a new flow instance on every handler invocation.
///
/// Returns null when no kit is present (kit not yet initialised).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/main_screen_flow.dart';
import '../flows/transfer_flow.dart';
import 'activity_log_state.dart';
import 'demo_state.dart';
import 'main_screen_flow_provider.dart';

/// Provider for the [TransferFlow] instance.
///
/// Re-evaluated whenever [demoStateProvider] or [activityLogProvider] change,
/// which includes kit initialisation. Returns null when no kit is available.
final transferFlowProvider = Provider<TransferFlow?>((ref) {
  final demoState = ref.read(demoStateProvider.notifier);
  final activityLog = ref.read(activityLogProvider.notifier);
  final mainFlow = ref.read(mainScreenFlowProvider);
  return buildTransferFlow(
    demoState: demoState,
    activityLog: activityLog,
    mainScreenFlow: mainFlow,
  );
});

/// Builds a [TransferFlow] from injected dependencies.
///
/// Returns null when the kit is not yet initialised.
TransferFlow? buildTransferFlow({
  required DemoStateNotifier demoState,
  required ActivityLogNotifier activityLog,
  MainScreenFlow? mainScreenFlow,
}) {
  final kit = demoState.kit;
  if (kit == null) return null;

  return TransferFlow(
    demoState: demoState,
    activityLog: activityLog,
    transactionOperations: TransactionOperationsAdapter(
      kit.transactionOperations,
    ),
    multiSignerManager: MultiSignerManagerAdapter(kit.multiSignerManager),
    contextRuleManager: ContextRuleManagerAdapter(kit.contextRuleManager),
    mainScreenFlow: mainScreenFlow,
  );
}
