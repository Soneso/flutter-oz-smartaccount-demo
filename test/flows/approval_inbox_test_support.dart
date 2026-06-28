/// Shared test support for [ApprovalInboxFlow] and approval-inbox widget tests.
///
/// Provides a [FakeCoordinationClient] (records calls, returns canned
/// responses, or throws) and fixture builders that wire an [ApprovalInboxFlow]
/// against fresh Riverpod notifiers and the shared [MockContractCall]. No
/// network, no testnet.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/approval_inbox_flow.dart';
import 'package:smart_account_demo/services/coordination_client.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'approve_test_support.dart' show MockContractCall;

export 'approve_test_support.dart' show MockContractCall;

// ---------------------------------------------------------------------------
// FakeCoordinationClient
// ---------------------------------------------------------------------------

/// Configurable fake [CoordinationClient].
///
/// [pending] seeds the list endpoint. The `*Error` fields, when set, make the
/// corresponding call throw. Call arguments are recorded so tests can assert
/// the exact `id`, `resultHash`, and `note` sent back.
final class FakeCoordinationClient implements CoordinationClient {
  FakeCoordinationClient({
    List<CoordinationRequest>? pending,
    this.listError,
    this.approveError,
    this.rejectError,
    this.getError,
    this.onGetRequest,
  }) : pending = pending ?? <CoordinationRequest>[];

  List<CoordinationRequest> pending;
  Object? listError;
  Object? approveError;
  Object? rejectError;

  /// When set, [getRequest] throws this instead of returning a record.
  Object? getError;

  /// When set, [getRequest] returns the hook's result, letting a test model a
  /// fresh server status that differs from the (stale) inbox copy.
  CoordinationRequest Function(String id)? onGetRequest;

  int listCount = 0;
  int getCount = 0;
  String? lastApprovedId;
  String? lastApprovedResultHash;
  String? lastRejectedId;
  String? lastRejectedNote;
  bool rejectNoteWasProvided = false;
  bool closed = false;

  @override
  Future<List<CoordinationRequest>> listPending() async {
    listCount++;
    final e = listError;
    if (e != null) throw e;
    return List<CoordinationRequest>.unmodifiable(pending);
  }

  @override
  Future<CoordinationRequest> getRequest(String id) async {
    getCount++;
    final e = getError;
    if (e != null) throw e;
    final hook = onGetRequest;
    if (hook != null) return hook(id);
    return pending.firstWhere(
      (r) => r.id == id,
      orElse: () => buildRequest(id: id),
    );
  }

  @override
  Future<CoordinationRequest> approve(
    String id, {
    required String resultHash,
  }) async {
    final e = approveError;
    if (e != null) throw e;
    lastApprovedId = id;
    lastApprovedResultHash = resultHash;
    return _resolved(id, status: CoordinationRequest.statusApproved,
        resultHash: resultHash);
  }

  @override
  Future<CoordinationRequest> reject(String id, {String? note}) async {
    final e = rejectError;
    if (e != null) throw e;
    lastRejectedId = id;
    lastRejectedNote = note;
    rejectNoteWasProvided = note != null;
    return _resolved(id, status: CoordinationRequest.statusRejected, note: note);
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  CoordinationRequest _resolved(
    String id, {
    required String status,
    String? resultHash,
    String? note,
  }) {
    final original = pending.firstWhere(
      (r) => r.id == id,
      orElse: () => buildRequest(id: id),
    );
    return CoordinationRequest(
      id: original.id,
      smartAccount: original.smartAccount,
      target: original.target,
      targetFn: original.targetFn,
      args: original.args,
      amount: original.amount,
      reason: original.reason,
      status: status,
      createdAt: original.createdAt,
      resolvedAt: 1782485040000,
      resultHash: resultHash,
      note: note,
    );
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// A target contract C-address used across the approval-inbox tests.
const String fixtureTarget =
    'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L';

/// A smart-account C-address used across the approval-inbox tests.
const String fixtureSmartAccount =
    'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';

/// Builds the canonical transfer argument vector the agent would encode:
/// `[from(address), to(address), amount(i128)]`, base64-encoded.
List<String> transferArgsBase64({
  String from = fixtureSmartAccount,
  String to = 'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM',
  int amountBaseUnits = 105000000,
}) {
  return <XdrSCVal>[
    XdrSCVal.forAddressStrKey(from),
    XdrSCVal.forAddressStrKey(to),
    Util.bigIntToI128ScVal(BigInt.from(amountBaseUnits)),
  ].map((a) => a.toBase64EncodedXdrString()).toList(growable: false);
}

/// Builds a pending [CoordinationRequest] with valid encoded args by default.
CoordinationRequest buildRequest({
  String id = 'req-1',
  String smartAccount = fixtureSmartAccount,
  String target = fixtureTarget,
  String targetFn = 'transfer',
  List<String>? args,
  String amount = '10.5',
  int reason = 3016,
  String status = 'pending',
}) {
  return CoordinationRequest(
    id: id,
    smartAccount: smartAccount,
    target: target,
    targetFn: targetFn,
    args: args ?? transferArgsBase64(),
    amount: amount,
    reason: reason,
    status: status,
    createdAt: 1782485036185,
  );
}

// ---------------------------------------------------------------------------
// ApprovalInboxFlowTestDeps
// ---------------------------------------------------------------------------

/// All dependencies returned by [makeInboxFlow].
final class ApprovalInboxFlowTestDeps {
  const ApprovalInboxFlowTestDeps({
    required this.flow,
    required this.coordination,
    required this.contractCall,
    required this.activityLog,
    required this.container,
  });

  final ApprovalInboxFlow flow;
  final FakeCoordinationClient coordination;
  final MockContractCall contractCall;
  final ActivityLogNotifier activityLog;
  final ProviderContainer container;

  List<LogEntry> get logEntries => container.read(activityLogProvider);
}

/// Builds an [ApprovalInboxFlow] wired to a [FakeCoordinationClient] and a
/// [MockContractCall].
///
/// When [connected] is false the flow's `resolveContractCall` and
/// `resolveConnectedAccount` both return null, so approve short-circuits with a
/// "connect a wallet" error and the listing is empty. [connectedAccount] is the
/// C-address the flow reports as connected (used for account-scope filtering
/// and the cross-account guard); defaults to [fixtureSmartAccount].
ApprovalInboxFlowTestDeps makeInboxFlow({
  FakeCoordinationClient? coordination,
  MockContractCall? contractCall,
  bool connected = true,
  String? connectedAccount = fixtureSmartAccount,
}) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final activityLog = container.read(activityLogProvider.notifier);

  final fake = coordination ?? FakeCoordinationClient();
  final mockCall = contractCall ?? MockContractCall();

  final flow = ApprovalInboxFlow(
    coordination: fake,
    activityLog: activityLog,
    resolveContractCall: () => connected ? mockCall : null,
    resolveConnectedAccount: () => connected ? connectedAccount : null,
  );

  return ApprovalInboxFlowTestDeps(
    flow: flow,
    coordination: fake,
    contractCall: mockCall,
    activityLog: activityLog,
    container: container,
  );
}
