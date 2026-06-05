/// Shared test support for [ApproveFlow] tests.
///
/// Provides mock implementations of [ContractCallType],
/// [MultiSignerContractCallType], and [AllowanceFetcherType] plus a
/// fixture builder that wires up an [ApproveFlow] against fresh
/// Riverpod notifiers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/approve_flow.dart';
import 'package:smart_account_demo/flows/context_rule_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'context_rule_test_support.dart';

// ---------------------------------------------------------------------------
// MockContractCall
// ---------------------------------------------------------------------------

/// Configurable mock for [ContractCallType].
///
/// Controls outcome via [result] and [error]. Records call arguments so
/// tests can assert on the exact payload passed to the SDK.
final class MockContractCall implements ContractCallType {
  OZTransactionResult? result;
  Object? error;

  String? lastTarget;
  String? lastTargetFn;
  List<XdrSCVal>? lastTargetArgs;
  int callCount = 0;

  @override
  Future<OZTransactionResult> contractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
  }) async {
    callCount++;
    lastTarget = target;
    lastTargetFn = targetFn;
    lastTargetArgs = targetArgs;
    final e = error;
    if (e != null) throw e;
    final r = result;
    if (r == null) {
      throw StateError(
        'MockContractCall: neither result nor error configured.',
      );
    }
    return r;
  }
}

// ---------------------------------------------------------------------------
// MockMultiSignerContractCall
// ---------------------------------------------------------------------------

/// Configurable mock for [MultiSignerContractCallType].
final class MockMultiSignerContractCall implements MultiSignerContractCallType {
  OZTransactionResult? result;
  Object? error;

  String? lastTarget;
  String? lastTargetFn;
  List<XdrSCVal>? lastTargetArgs;
  List<OZSelectedSigner>? lastSelectedSigners;
  int callCount = 0;

  @override
  Future<OZTransactionResult> multiSignerContractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
    required List<OZSelectedSigner> selectedSigners,
  }) async {
    callCount++;
    lastTarget = target;
    lastTargetFn = targetFn;
    lastTargetArgs = targetArgs;
    lastSelectedSigners = selectedSigners;
    final e = error;
    if (e != null) throw e;
    final r = result;
    if (r == null) {
      throw StateError(
        'MockMultiSignerContractCall: neither result nor error configured.',
      );
    }
    return r;
  }
}

// ---------------------------------------------------------------------------
// MockAllowanceFetcher
// ---------------------------------------------------------------------------

/// Configurable mock for [AllowanceFetcherType].
final class MockAllowanceFetcher implements AllowanceFetcherType {
  BigInt? result;
  Object? error;

  String? lastTokenContract;
  String? lastFromAddress;
  String? lastSpenderAddress;
  int callCount = 0;

  @override
  Future<BigInt?> fetchAllowance({
    required String tokenContract,
    required String fromAddress,
    required String spenderAddress,
  }) async {
    callCount++;
    lastTokenContract = tokenContract;
    lastFromAddress = fromAddress;
    lastSpenderAddress = spenderAddress;
    final e = error;
    if (e != null) throw e;
    return result;
  }
}

// ---------------------------------------------------------------------------
// ApproveFixtures
// ---------------------------------------------------------------------------

/// Shared fixture builders for [ApproveFlow] tests.
final class ApproveFixtures {
  ApproveFixtures._();

  // Fixture constants — re-export the values used in other flow tests so a
  // single set of test addresses appears across the suite.
  static const String defaultContractId =
      'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
  static const String defaultCredentialId =
      'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU';
  static const String defaultSpender =
      'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';
  static const String defaultContractSpender =
      'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';
  static const String defaultAmount = '10.0';
  static const String defaultTokenContract =
      'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';
  static const String defaultTxHash =
      'abc123def456abc123def456abc123def456abc123def456abc123def456abcd';

  /// A successful [OZTransactionResult].
  static OZTransactionResult successResult({String? hash}) =>
      OZTransactionResult(success: true, hash: hash ?? defaultTxHash);

  /// A failed [OZTransactionResult].
  static OZTransactionResult failureResult({String? errorMessage}) =>
      OZTransactionResult(
        success: false,
        error: errorMessage ?? 'Approve failed on-chain.',
      );

  /// Builds an [ApproveFlow] with minimal dependencies for unit tests.
  ///
  /// The supplied [ContextRuleFlow] is built from a mock manager and a mock
  /// environment so the ledger-offset resolution can be exercised without a
  /// live kit.
  static ApproveFlowTestDeps makeFlowWithDeps({
    MockContractCall? contractCall,
    MockMultiSignerContractCall? multiSignerContractCall,
    MockAllowanceFetcher? allowanceFetcher,
    MockContextRuleFlowManager? contextRuleManager,
    MockBuilderEnvironment? environment,
    String? contractId,
    bool isConnected = true,
    bool isDeployed = true,
    String? demoTokenContractId,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);

    if (isConnected) {
      demoState.setConnected(
        contractId: contractId ?? defaultContractId,
        credentialId: defaultCredentialId,
        isDeployed: isDeployed,
      );
      if (demoTokenContractId != null) {
        demoState.updateDemoTokenContract(demoTokenContractId);
      }
    }

    final ccCall = contractCall ?? MockContractCall();
    final msCall = multiSignerContractCall ?? MockMultiSignerContractCall();
    final allowance = allowanceFetcher ?? MockAllowanceFetcher();
    final mgr = contextRuleManager ?? MockContextRuleFlowManager();
    final env = environment ?? MockBuilderEnvironment();

    final contextRuleFlow = ContextRuleFlow(
      demoState: demoState,
      activityLog: activityLog,
      contextRuleManager: mgr,
      environment: env,
    );

    final flow = ApproveFlow(
      demoState: demoState,
      activityLog: activityLog,
      contractCall: ccCall,
      multiSignerContractCall: msCall,
      contextRuleFlow: contextRuleFlow,
      allowanceFetcher: allowance,
    );

    return ApproveFlowTestDeps(
      flow: flow,
      demoState: demoState,
      activityLog: activityLog,
      contractCall: ccCall,
      multiSignerContractCall: msCall,
      allowanceFetcher: allowance,
      contextRuleFlow: contextRuleFlow,
      environment: env,
      container: container,
    );
  }
}

// ---------------------------------------------------------------------------
// ApproveFlowTestDeps
// ---------------------------------------------------------------------------

/// All dependencies returned by [ApproveFixtures.makeFlowWithDeps].
final class ApproveFlowTestDeps {
  const ApproveFlowTestDeps({
    required this.flow,
    required this.demoState,
    required this.activityLog,
    required this.contractCall,
    required this.multiSignerContractCall,
    required this.allowanceFetcher,
    required this.contextRuleFlow,
    required this.environment,
    required this.container,
  });

  final ApproveFlow flow;
  final DemoStateNotifier demoState;
  final ActivityLogNotifier activityLog;
  final MockContractCall contractCall;
  final MockMultiSignerContractCall multiSignerContractCall;
  final MockAllowanceFetcher allowanceFetcher;
  final ContextRuleFlow contextRuleFlow;
  final MockBuilderEnvironment environment;
  final ProviderContainer container;

  List<LogEntry> get logEntries => container.read(activityLogProvider);
}
