/// Shared test support for [AccountSignersFlow] tests.
///
/// Reuses [MockContextRuleManager] from `transfer_test_support.dart` so the
/// same mock surface drives signer-discovery tests across the flow suite.
/// The fixture builder wires up the flow against fresh Riverpod notifiers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/account_signers_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';

import 'transfer_test_support.dart';

// ---------------------------------------------------------------------------
// AccountSignersFixtures
// ---------------------------------------------------------------------------

/// Shared fixture builders for [AccountSignersFlow] tests.
final class AccountSignersFixtures {
  AccountSignersFixtures._();

  static const String defaultContractId =
      'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
  static const String defaultCredentialId =
      'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU';

  /// Two delegated signer fixtures aligned with values used elsewhere in the
  /// test suite.
  static const String delegatedAddress1 =
      'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';
  static const String delegatedAddress2 =
      'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';

  /// Builds an [AccountSignersFlow] with minimal dependencies for unit tests.
  ///
  /// Reuses the existing [MockContextRuleManager] so the same fake powers
  /// every flow that consumes context rules.
  static AccountSignersFlowTestDeps makeFlowWithDeps({
    MockContextRuleManager? contextRuleManager,
    String? contractId,
    String? credentialId,
    bool isConnected = true,
    bool isDeployed = true,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);

    if (isConnected) {
      demoState.setConnected(
        contractId: contractId ?? defaultContractId,
        credentialId: credentialId ?? defaultCredentialId,
        isDeployed: isDeployed,
      );
    }

    final mgr = contextRuleManager ?? MockContextRuleManager();

    final flow = AccountSignersFlow(
      demoState: demoState,
      activityLog: activityLog,
      contextRuleManager: mgr,
    );

    return AccountSignersFlowTestDeps(
      flow: flow,
      demoState: demoState,
      activityLog: activityLog,
      contextRuleManager: mgr,
      container: container,
    );
  }
}

// ---------------------------------------------------------------------------
// AccountSignersFlowTestDeps
// ---------------------------------------------------------------------------

/// All dependencies returned by [AccountSignersFixtures.makeFlowWithDeps].
final class AccountSignersFlowTestDeps {
  const AccountSignersFlowTestDeps({
    required this.flow,
    required this.demoState,
    required this.activityLog,
    required this.contextRuleManager,
    required this.container,
  });

  final AccountSignersFlow flow;
  final DemoStateNotifier demoState;
  final ActivityLogNotifier activityLog;
  final MockContextRuleManager contextRuleManager;
  final ProviderContainer container;

  List<LogEntry> get logEntries => container.read(activityLogProvider);
}
