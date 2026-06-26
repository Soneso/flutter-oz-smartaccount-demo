// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// Records the connect call and returns a fixed smart-account contract id.
class FakeWalletSession implements WalletSession {
  FakeWalletSession(this.contractId);

  final String contractId;
  int connectCount = 0;

  @override
  Future<String> connect() async {
    connectCount++;
    return contractId;
  }
}

/// Returns a canned [OZTransactionResult] or throws a canned exception.
class FakeContractCall implements MultiSignerContractCallType {
  FakeContractCall({this.result, this.error})
      : assert(result != null || error != null,
            'Provide either a result or an error');

  final OZTransactionResult? result;
  final Object? error;

  int callCount = 0;
  List<OZSelectedSigner>? lastSelectedSigners;
  List<XdrSCVal>? lastArgs;
  String? lastTarget;
  String? lastTargetFn;

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
    lastArgs = targetArgs;
    lastSelectedSigners = selectedSigners;
    final err = error;
    if (err != null) throw err;
    return result!;
  }
}

/// Captures the created request and replays a queued status sequence.
class FakeCoordinationClient implements CoordinationClient {
  FakeCoordinationClient({required this.pollResponses});

  /// Status records returned by successive [getRequest] calls.
  final List<CoordinationRequest> pollResponses;

  int closeCount = 0;
  int getCount = 0;
  Map<String, Object?>? createBody;

  @override
  Future<CoordinationRequest> createRequest({
    required String smartAccount,
    required String target,
    required String targetFn,
    required List<String> args,
    String? amount,
    required int reason,
  }) async {
    createBody = <String, Object?>{
      'smartAccount': smartAccount,
      'target': target,
      'targetFn': targetFn,
      'args': args,
      'amount': amount,
      'reason': reason,
    };
    return CoordinationRequest(
      id: 'req-1',
      smartAccount: smartAccount,
      target: target,
      targetFn: targetFn,
      args: args,
      amount: amount ?? '',
      reason: reason,
      status: CoordinationRequest.statusPending,
      createdAt: 1,
    );
  }

  @override
  Future<CoordinationRequest> getRequest(String id) async {
    final index = getCount < pollResponses.length
        ? getCount
        : pollResponses.length - 1;
    getCount++;
    return pollResponses[index];
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

class RecordingLogger implements AgentLogger {
  final List<String> messages = <String>[];

  @override
  void info(String message) => messages.add('INFO:$message');

  @override
  void success(String message) => messages.add('OK:$message');

  @override
  void error(String message) => messages.add('ERROR:$message');
}

void main() {
  // A valid testnet C-address used as the connected smart account.
  const smartAccount = 'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';
  const ed25519Verifier = 'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6';

  late KeyPair agentKeypair;
  late String destination;
  late AgentEd25519SignerAdapter signerAdapter;

  setUp(() {
    agentKeypair = KeyPair.random();
    destination = KeyPair.random().accountId;
    signerAdapter = AgentEd25519SignerAdapter();
  });

  // The runner is constructed with the agent keypair directly; the config's
  // hex seed is not re-derived here, so any valid 64-hex seed is sufficient.
  const agentSeedHex =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  AgentConfig buildConfig() => AgentConfig(
        smartAccountContractId: smartAccount,
        agentSecretSeed: agentSeedHex,
        destinationAddress: destination,
        amount: '5',
        pollInterval: Duration.zero,
        pollMaxAttempts: 5,
      );

  AgentRunner buildRunner({
    required FakeContractCall contractCall,
    required FakeCoordinationClient coordination,
    required FakeWalletSession session,
    required RecordingLogger logger,
  }) {
    return AgentRunner(
      config: buildConfig(),
      session: session,
      contractCall: contractCall,
      coordination: coordination,
      signerAdapter: signerAdapter,
      agentKeypair: agentKeypair,
      logger: logger,
      sleep: (_) async {},
    );
  }

  test('successful scoped call returns AgentCallSucceeded with the hash', () async {
    final contractCall = FakeContractCall(
      result: const OZTransactionResult(success: true, hash: 'TXHASH123'),
    );
    final coordination =
        FakeCoordinationClient(pollResponses: const <CoordinationRequest>[]);
    final session = FakeWalletSession(smartAccount);
    final logger = RecordingLogger();

    final runner = buildRunner(
      contractCall: contractCall,
      coordination: coordination,
      session: session,
      logger: logger,
    );

    final result = await runner.run();

    expect(result, isA<AgentCallSucceeded>());
    expect((result as AgentCallSucceeded).hash, 'TXHASH123');
    expect(session.connectCount, 1);
    expect(contractCall.callCount, 1);
    // The selected signer is the agent's Ed25519 external signer.
    expect(contractCall.lastSelectedSigners, hasLength(1));
    expect(contractCall.lastSelectedSigners!.single, isA<OZSelectedSignerEd25519>());
    final selected =
        contractCall.lastSelectedSigners!.single as OZSelectedSignerEd25519;
    expect(selected.verifierAddress, ed25519Verifier);
    expect(selected.publicKey, agentKeypair.publicKey);
    expect(contractCall.lastTargetFn, 'transfer');
    // No escalation occurred.
    expect(coordination.createBody, isNull);
    expect(coordination.getCount, 0);
    // The adapter reference is cleared after the attempt.
    expect(signerAdapter.canSignFor(ed25519Verifier,
        Uint8List.fromList(agentKeypair.publicKey)), isFalse);
  });

  test('logs the agent public key as raw 64-char hex on startup', () async {
    final contractCall = FakeContractCall(
      result: const OZTransactionResult(success: true, hash: 'TXHASH123'),
    );
    final coordination =
        FakeCoordinationClient(pollResponses: const <CoordinationRequest>[]);
    final logger = RecordingLogger();

    final runner = buildRunner(
      contractCall: contractCall,
      coordination: coordination,
      session: FakeWalletSession(smartAccount),
      logger: logger,
    );

    await runner.run();

    // The agent prints its own public key as raw 64-character hex so an
    // operator can paste it into the demo's Delegate-to-agent screen. The
    // emitted value must be the keypair's raw public-key bytes in hex.
    final expectedHex =
        Util.bytesToHex(Uint8List.fromList(agentKeypair.publicKey));
    final startupLine = logger.messages.firstWhere(
      (m) => m.contains('Delegate-to-agent'),
      orElse: () => '',
    );
    expect(startupLine, isNotEmpty);
    expect(startupLine, contains(expectedHex));
    expect(expectedHex, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('non-policy failure returns AgentCallFailed without escalating', () async {
    final contractCall = FakeContractCall(
      result: const OZTransactionResult(
        success: false,
        error: 'RPC endpoint unreachable',
      ),
    );
    final coordination =
        FakeCoordinationClient(pollResponses: const <CoordinationRequest>[]);
    final logger = RecordingLogger();

    final runner = buildRunner(
      contractCall: contractCall,
      coordination: coordination,
      session: FakeWalletSession(smartAccount),
      logger: logger,
    );

    final result = await runner.run();

    expect(result, isA<AgentCallFailed>());
    expect((result as AgentCallFailed).message, contains('unreachable'));
    expect(coordination.createBody, isNull);
  });

  test('policy rejection escalates and returns approved with the result hash',
      () async {
    final contractCall = FakeContractCall(
      result: const OZTransactionResult(
        success: false,
        error: 'HostError: Error(Contract, #3016)',
      ),
    );
    const approved = CoordinationRequest(
      id: 'req-1',
      smartAccount: smartAccount,
      target: smartAccount,
      targetFn: 'transfer',
      args: <String>[],
      amount: '5',
      reason: 3016,
      status: CoordinationRequest.statusApproved,
      createdAt: 1,
      resolvedAt: 2,
      resultHash: 'RESOLVEDHASH',
    );
    // First poll still pending, second poll approved — exercises the loop.
    const pending = CoordinationRequest(
      id: 'req-1',
      smartAccount: smartAccount,
      target: smartAccount,
      targetFn: 'transfer',
      args: <String>[],
      amount: '5',
      reason: 3016,
      status: CoordinationRequest.statusPending,
      createdAt: 1,
    );
    final coordination = FakeCoordinationClient(
      pollResponses: <CoordinationRequest>[pending, approved],
    );
    final logger = RecordingLogger();

    final runner = buildRunner(
      contractCall: contractCall,
      coordination: coordination,
      session: FakeWalletSession(smartAccount),
      logger: logger,
    );

    final result = await runner.run();

    expect(result, isA<AgentEscalationApproved>());
    final approvedResult = result as AgentEscalationApproved;
    expect(approvedResult.requestId, 'req-1');
    expect(approvedResult.resultHash, 'RESOLVEDHASH');
    expect(approvedResult.errorCode, 3016);
    expect(coordination.getCount, 2);

    // The escalation body matches the wire contract.
    final body = coordination.createBody!;
    expect(body['smartAccount'], smartAccount);
    expect(body['target'], buildConfig().tokenContractId);
    expect(body['targetFn'], 'transfer');
    expect(body['reason'], 3016);
    expect(body['amount'], '5');
    // args are the three base64-encoded XdrSCVal call args (from, to, amount).
    final args = body['args']! as List<String>;
    expect(args, hasLength(3));
    for (final encoded in args) {
      // Each entry round-trips through the SDK base64 helper.
      expect(
        XdrSCVal.fromBase64EncodedXdrString(encoded).toBase64EncodedXdrString(),
        encoded,
      );
    }
  });

  test('policy rejection escalates and returns rejected with the note',
      () async {
    final contractCall = FakeContractCall(
      // Exercise the thrown-exception classification path.
      error: SmartAccountTransactionException.simulationFailed(
        'Simulation error: Error(Contract, #3016)',
      ),
    );
    const rejected = CoordinationRequest(
      id: 'req-1',
      smartAccount: smartAccount,
      target: smartAccount,
      targetFn: 'transfer',
      args: <String>[],
      amount: '5',
      reason: 3016,
      status: CoordinationRequest.statusRejected,
      createdAt: 1,
      resolvedAt: 2,
      note: 'looks malicious',
    );
    final coordination = FakeCoordinationClient(
      pollResponses: <CoordinationRequest>[rejected],
    );
    final logger = RecordingLogger();

    final runner = buildRunner(
      contractCall: contractCall,
      coordination: coordination,
      session: FakeWalletSession(smartAccount),
      logger: logger,
    );

    final result = await runner.run();

    expect(result, isA<AgentEscalationRejected>());
    final rejectedResult = result as AgentEscalationRejected;
    expect(rejectedResult.requestId, 'req-1');
    expect(rejectedResult.note, 'looks malicious');
    expect(rejectedResult.errorCode, 3016);
  });

  test('escalation that never resolves returns AgentEscalationPending', () async {
    final contractCall = FakeContractCall(
      result: const OZTransactionResult(
        success: false,
        error: 'Error(Contract, #3016)',
      ),
    );
    const pending = CoordinationRequest(
      id: 'req-1',
      smartAccount: smartAccount,
      target: smartAccount,
      targetFn: 'transfer',
      args: <String>[],
      amount: '5',
      reason: 3016,
      status: CoordinationRequest.statusPending,
      createdAt: 1,
    );
    final coordination = FakeCoordinationClient(
      pollResponses: <CoordinationRequest>[pending],
    );
    final logger = RecordingLogger();

    final runner = buildRunner(
      contractCall: contractCall,
      coordination: coordination,
      session: FakeWalletSession(smartAccount),
      logger: logger,
    );

    final result = await runner.run();

    expect(result, isA<AgentEscalationPending>());
    final pendingResult = result as AgentEscalationPending;
    expect(pendingResult.attempts, 5);
    expect(coordination.getCount, 5);
  });
}
