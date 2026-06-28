// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'agent_config.dart';
import 'agent_ed25519_signer_adapter.dart';
import 'coordination_client.dart';
import 'outcome.dart';

/// Establishes the kit's connected state for the configured smart account.
///
/// Behind an interface so the runner can be unit-tested without a live account
/// or a network round-trip.
abstract interface class WalletSession {
  /// Connects to the smart account headlessly and returns its contract id.
  Future<String> connect();
}

/// Submits a multi-signer scoped contract call.
///
/// Mirrors the demo app's `MultiSignerContractCallType`: the production
/// adapter wraps [OZMultiSignerManager], while tests inject a fake that returns
/// canned [OZTransactionResult]s or throws.
abstract interface class MultiSignerContractCallType {
  /// Invokes [targetFn] on [target] with [targetArgs], authorised by the
  /// explicit [selectedSigners] list.
  Future<OZTransactionResult> multiSignerContractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
    required List<OZSelectedSigner> selectedSigners,
  });
}

/// Sink for the agent's progress messages.
abstract interface class AgentLogger {
  /// Logs an informational message.
  void info(String message);

  /// Logs a success message.
  void success(String message);

  /// Logs an error message.
  void error(String message);
}

/// [AgentLogger] that writes to stdout. Stdout is the headless agent's console
/// output channel, so a direct write is intentional here.
class StdoutAgentLogger implements AgentLogger {
  /// Constructs a stdout logger.
  const StdoutAgentLogger();

  @override
  void info(String message) => _write('INFO', message);

  @override
  void success(String message) => _write('OK', message);

  @override
  void error(String message) => _write('ERROR', message);

  void _write(String level, String message) {
    // ignore: avoid_print
    print('[agent] [$level] $message');
  }
}

/// Terminal result of an [AgentRunner.run] invocation.
sealed class AgentResult {
  const AgentResult();
}

/// The scoped call confirmed on-chain; no escalation was needed.
final class AgentCallSucceeded extends AgentResult {
  /// Constructs a call-succeeded result carrying the transaction [hash].
  const AgentCallSucceeded(this.hash);

  /// On-chain transaction hash.
  final String hash;

  @override
  String toString() => 'AgentCallSucceeded(hash: $hash)';
}

/// The scoped call failed for a non-policy reason; the agent did not escalate.
final class AgentCallFailed extends AgentResult {
  /// Constructs a call-failed result with a [message].
  const AgentCallFailed(this.message);

  /// Sanitised failure description.
  final String message;

  @override
  String toString() => 'AgentCallFailed(message: $message)';
}

/// The escalated policy rejection was approved by the user. The agent learns
/// the outcome by polling and does NOT re-submit — the mobile app re-submits
/// the call under the Default rule and reports [resultHash].
final class AgentEscalationApproved extends AgentResult {
  /// Constructs an escalation-approved result.
  const AgentEscalationApproved({
    required this.requestId,
    required this.resultHash,
    required this.errorCode,
  });

  /// Coordination request id.
  final String requestId;

  /// Transaction/result hash reported by the resolving app.
  final String resultHash;

  /// Contract error code that triggered the escalation.
  final int errorCode;

  @override
  String toString() =>
      'AgentEscalationApproved(requestId: $requestId, resultHash: $resultHash)';
}

/// The escalated policy rejection was declined by the user.
final class AgentEscalationRejected extends AgentResult {
  /// Constructs an escalation-rejected result.
  const AgentEscalationRejected({
    required this.requestId,
    required this.errorCode,
    this.note,
  });

  /// Coordination request id.
  final String requestId;

  /// Contract error code that triggered the escalation.
  final int errorCode;

  /// Optional note left by the resolving user.
  final String? note;

  @override
  String toString() =>
      'AgentEscalationRejected(requestId: $requestId, note: $note)';
}

/// The escalation was created but no resolution arrived within the poll budget.
final class AgentEscalationPending extends AgentResult {
  /// Constructs an escalation-pending result.
  const AgentEscalationPending({
    required this.requestId,
    required this.errorCode,
    required this.attempts,
  });

  /// Coordination request id (still pending on the server).
  final String requestId;

  /// Contract error code that triggered the escalation.
  final int errorCode;

  /// Number of polls performed before giving up.
  final int attempts;

  @override
  String toString() =>
      'AgentEscalationPending(requestId: $requestId, attempts: $attempts)';
}

Future<void> _defaultSleep(Duration duration) =>
    Future<void>.delayed(duration);

/// Orchestrates one autonomous agent cycle: connect, register, submit a scoped
/// call, classify the outcome, and (on a policy rejection) escalate and poll.
///
/// All collaborators are injected so unit tests can drive the success,
/// rejection, escalate-and-approved, and escalate-and-rejected paths without a
/// network or a live account.
class AgentRunner {
  /// Constructs a runner from its injected collaborators.
  ///
  /// [signerAdapter] is the same adapter instance supplied to the kit's
  /// [OZSmartAccountConfig.externalEd25519Adapter]; the runner registers
  /// [agentKeypair] on it before submission and clears it afterwards.
  /// [sleep] is injectable so tests can run the poll loop without real delays.
  AgentRunner({
    required this.config,
    required WalletSession session,
    required MultiSignerContractCallType contractCall,
    required CoordinationClient coordination,
    required AgentEd25519SignerAdapter signerAdapter,
    required KeyPair agentKeypair,
    AgentLogger logger = const StdoutAgentLogger(),
    Future<void> Function(Duration) sleep = _defaultSleep,
  })  : _session = session,
        _contractCall = contractCall,
        _coordination = coordination,
        _signerAdapter = signerAdapter,
        _agentKeypair = agentKeypair,
        _logger = logger,
        _sleep = sleep;

  /// The resolved run configuration.
  final AgentConfig config;

  final WalletSession _session;
  final MultiSignerContractCallType _contractCall;
  final CoordinationClient _coordination;
  final AgentEd25519SignerAdapter _signerAdapter;
  final KeyPair _agentKeypair;
  final AgentLogger _logger;
  final Future<void> Function(Duration) _sleep;

  /// The function the agent calls on the target token.
  static const String targetFn = 'transfer';

  /// Runs one agent cycle and returns its terminal [AgentResult].
  Future<AgentResult> run() async {
    _logger.info(
      'Starting agent: account=${config.smartAccountContractId}, '
      'token=${config.tokenContractId}, amount=${config.amount}',
    );
    // Print the agent's own public key as raw 64-character hex so an operator
    // can paste it into the demo's "Delegate to agent" screen, which registers
    // it as the Ed25519 external signer this agent then signs with.
    _logger.info(
      'Agent public key (paste into Delegate-to-agent): '
      '${Util.bytesToHex(_agentPublicKey)}',
    );

    final smartAccount = await _session.connect();
    _logger.info('Connected to smart account $smartAccount');

    _signerAdapter.add(config.ed25519VerifierAddress, _agentKeypair);
    try {
      final args = _buildTransferArgs(smartAccount);
      final selectedSigners = <OZSelectedSigner>[
        OZSelectedSignerEd25519(
          verifierAddress: config.ed25519VerifierAddress,
          publicKey: _agentPublicKey,
        ),
      ];

      final outcome = await _attemptCall(args, selectedSigners);

      switch (outcome) {
        case CallSucceeded(:final hash):
          _logger.success('Scoped call confirmed. Hash: $hash');
          return AgentCallSucceeded(hash);
        case CallFailed(:final message):
          _logger.error('Scoped call failed (not a policy rejection): $message');
          return AgentCallFailed(message);
        case CallRejected():
          return _escalateAndPoll(outcome, args, smartAccount);
      }
    } finally {
      // Drop the adapter's reference to the signing keypair after the attempt.
      _signerAdapter.clearAll();
    }
  }

  Uint8List get _agentPublicKey => Uint8List.fromList(_agentKeypair.publicKey);

  Future<CallOutcome> _attemptCall(
    List<XdrSCVal> args,
    List<OZSelectedSigner> selectedSigners,
  ) async {
    try {
      final result = await _contractCall.multiSignerContractCall(
        target: config.tokenContractId,
        targetFn: targetFn,
        targetArgs: args,
        selectedSigners: selectedSigners,
      );
      return classifyResult(result);
    } catch (e) {
      return classifyError(e);
    }
  }

  Future<AgentResult> _escalateAndPoll(
    CallRejected rejection,
    List<XdrSCVal> args,
    String smartAccount,
  ) async {
    _logger.info(
      'Policy rejection (code ${rejection.errorCode}'
      '${rejection.errorName == null ? '' : ' / ${rejection.errorName}'}). '
      'Escalating to ${config.coordinationBaseUrl}.',
    );

    final encodedArgs =
        args.map((a) => a.toBase64EncodedXdrString()).toList(growable: false);

    final created = await _coordination.createRequest(
      smartAccount: smartAccount,
      target: config.tokenContractId,
      targetFn: targetFn,
      args: encodedArgs,
      amount: config.amount,
      reason: rejection.errorCode,
    );
    final requestId = created.id;
    _logger.info('Escalation request created: id=$requestId (pending).');

    for (var attempt = 1; attempt <= config.pollMaxAttempts; attempt++) {
      await _sleep(config.pollInterval);

      final CoordinationRequest current;
      try {
        current = await _coordination.getRequest(requestId);
      } on CoordinationException catch (e) {
        // The escalation request is already created and still live on the
        // server; a transient 5xx or network blip on a single poll does not
        // invalidate it. Log and retry on the next tick so the request
        // survives across the poll window.
        _logger.info(
          'Transient error polling escalation $requestId '
          '(attempt $attempt/${config.pollMaxAttempts}): ${e.message}. '
          'Retrying.',
        );
        continue;
      }
      switch (current.status) {
        case CoordinationRequest.statusApproved:
          final resultHash = current.resultHash ?? '';
          _logger.success(
            'Escalation approved by user. resultHash=$resultHash. '
            'The mobile app re-submitted under the Default rule; the agent '
            'does not re-submit.',
          );
          return AgentEscalationApproved(
            requestId: requestId,
            resultHash: resultHash,
            errorCode: rejection.errorCode,
          );
        case CoordinationRequest.statusRejected:
          _logger.info(
            'Escalation rejected by user'
            '${current.note == null ? '' : ': ${current.note}'}.',
          );
          return AgentEscalationRejected(
            requestId: requestId,
            errorCode: rejection.errorCode,
            note: current.note,
          );
        default:
          // Still pending — keep polling.
          break;
      }
    }

    _logger.info(
      'Escalation $requestId still pending after ${config.pollMaxAttempts} '
      'polls; stopping.',
    );
    return AgentEscalationPending(
      requestId: requestId,
      errorCode: rejection.errorCode,
      attempts: config.pollMaxAttempts,
    );
  }

  /// Builds the `transfer(from, to, amount)` argument vector.
  ///
  /// The encoded form of this exact list is sent to the coordination server so
  /// the mobile inbox can rebuild the call verbatim.
  List<XdrSCVal> _buildTransferArgs(String smartAccount) {
    final destination = config.destinationAddress;
    if (destination == null || destination.isEmpty) {
      throw const AgentConfigException(
        'destinationAddress is required to build the transfer call.',
      );
    }
    final baseUnits = OZTransactionOperations.amountToBaseUnits(
      config.amount,
      decimals: config.tokenDecimals,
    );
    return <XdrSCVal>[
      XdrSCVal.forAddressStrKey(smartAccount),
      XdrSCVal.forAddressStrKey(destination),
      Util.bigIntToI128ScVal(baseUnits),
    ];
  }
}
