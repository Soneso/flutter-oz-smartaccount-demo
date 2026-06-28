/// Unit tests for [ApprovalInboxFlow] (steps 4 + 5 of the agent-signer flow).
///
/// All collaborators are injected ([FakeCoordinationClient], [MockContractCall])
/// so the list, approve (rebuild + submit + report-back), and reject paths run
/// without a network or a live testnet.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/approval_inbox_flow.dart';
import 'package:smart_account_demo/flows/approve_flow.dart' show ContractCallType;
import 'package:smart_account_demo/services/coordination_client.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'approval_inbox_test_support.dart';

/// The recipient G-address the transfer fixtures encode in their args.
const String _fixtureRecipient =
    'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';

/// Builds an `approve(from, spender, amount, expiration)` argument vector,
/// base64-encoded, the way the agent would for an allowance call.
List<String> _approveArgsBase64({
  String spender = _fixtureRecipient,
  int amountBaseUnits = 250000000,
  int expiration = 123456,
}) {
  return <XdrSCVal>[
    XdrSCVal.forAddressStrKey(fixtureSmartAccount),
    XdrSCVal.forAddressStrKey(spender),
    Util.bigIntToI128ScVal(BigInt.from(amountBaseUnits)),
    XdrSCVal.forU32(expiration),
  ].map((a) => a.toBase64EncodedXdrString()).toList(growable: false);
}

/// Encodes an arbitrary argument list as base64 `XdrSCVal` strings.
List<String> _encode(List<XdrSCVal> args) =>
    args.map((a) => a.toBase64EncodedXdrString()).toList(growable: false);

void main() {
  group('describeRejectionReason', () {
    test('maps known OZ contract error codes to human names', () {
      expect(describeRejectionReason(OZContractErrorCodes.unauthorizedSigner),
          'Unauthorized signer');
      expect(describeRejectionReason(OZContractErrorCodes.mathOverflow),
          'Math overflow');
      expect(describeRejectionReason(OZContractErrorCodes.nameTooLong),
          'Name too long');
    });

    test('falls back to a generic label for unknown codes', () {
      expect(describeRejectionReason(9999), 'Contract error #9999');
    });
  });

  group('ApprovalInboxFlow.loadPending / pendingCount', () {
    test('returns the pending requests the server reports', () async {
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[
            buildRequest(id: 'a'),
            buildRequest(id: 'b'),
          ],
        ),
      );

      final pending = await deps.flow.loadPending();
      expect(pending.map((r) => r.id), <String>['a', 'b']);
      expect(await deps.flow.pendingCount(), 2);
    });

    test('propagates a CoordinationException when the server is unreachable',
        () async {
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          listError: const CoordinationException('GET /requests failed: down'),
        ),
      );

      await expectLater(
        deps.flow.loadPending(),
        throwsA(isA<CoordinationException>()),
      );
    });
  });

  group('ApprovalInboxFlow.approveRequest', () {
    test('rebuilds the agent call verbatim, submits, and reports the hash back',
        () async {
      final args = transferArgsBase64();
      final request = buildRequest(args: args);
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      final result = await deps.flow.approveRequest(request);

      // Submission used the exact target + function + decoded args.
      expect(deps.contractCall.callCount, 1);
      expect(deps.contractCall.lastTarget, fixtureTarget);
      expect(deps.contractCall.lastTargetFn, 'transfer');
      final reEncoded = deps.contractCall.lastTargetArgs!
          .map((a) => a.toBase64EncodedXdrString())
          .toList(growable: false);
      expect(reEncoded, args);

      // The on-chain hash was reported back to the coordination server.
      expect(deps.coordination.lastApprovedId, request.id);
      expect(deps.coordination.lastApprovedResultHash, 'TXHASH');

      expect(result.success, isTrue);
      expect(result.hash, 'TXHASH');
    });

    test('returns an error and does not submit when no wallet is connected',
        () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        connected: false,
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      expect(result.error, contains('No wallet connected'));
      expect(deps.contractCall.callCount, 0);
      expect(deps.coordination.lastApprovedId, isNull);
    });

    test('handles malformed encoded arguments gracefully', () async {
      final request = buildRequest(args: const <String>['!!!not-base64!!!']);
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      expect(result.error, contains('decode'));
      expect(deps.contractCall.callCount, 0);
      expect(deps.coordination.lastApprovedId, isNull);
    });

    test('does not report back when the on-chain submission fails', () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      deps.contractCall.result = const OZTransactionResult(
        success: false,
        error: 'rejected on-chain',
      );

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      expect(result.error, contains('rejected on-chain'));
      expect(deps.coordination.lastApprovedId, isNull);
    });

    test('surfaces a cancelled passkey ceremony without reporting back',
        () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      deps.contractCall.error = const WebAuthnCancelled();

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      expect(result.error, contains('cancelled'));
      expect(deps.coordination.lastApprovedId, isNull);
    });

    test(
        'preserves the on-chain hash when reporting the approval back fails',
        () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
          approveError:
              const CoordinationException('approve returned 409', statusCode: 409),
        ),
      );
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      // The transaction confirmed, so the hash is preserved for a manual retry.
      expect(result.hash, 'TXHASH');
      expect(result.error, contains('TXHASH'));
    });
  });

  group('ApprovalInboxFlow.rejectRequest', () {
    test('reports the trimmed note back to the server', () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );

      final result =
          await deps.flow.rejectRequest(request, note: '  looks malicious  ');

      expect(result.success, isTrue);
      expect(deps.coordination.lastRejectedId, request.id);
      expect(deps.coordination.lastRejectedNote, 'looks malicious');
    });

    test('sends no note when the note is empty or whitespace', () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );

      final result = await deps.flow.rejectRequest(request, note: '   ');

      expect(result.success, isTrue);
      expect(deps.coordination.rejectNoteWasProvided, isFalse);
      expect(deps.coordination.lastRejectedNote, isNull);
    });

    test('returns a sanitised error when the server rejects the call',
        () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
          rejectError:
              const CoordinationException('reject returned 409', statusCode: 409),
        ),
      );

      final result = await deps.flow.rejectRequest(request);

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      expect(
        deps.logEntries.any((e) => e.level == LogLevel.error),
        isTrue,
      );
    });
  });

  group('ApprovalInboxFlow.decodeCall (displayed == submitted)', () {
    test('decodes the transfer recipient and the on-chain amount from the args, '
        'not the untrusted server amount', () {
      // transferArgsBase64 defaults to _fixtureRecipient and 105000000 base
      // units (== 10.5 at 7 decimals).
      final args = transferArgsBase64();
      // The server-supplied display amount is a lie; it must not be used.
      final request = buildRequest(args: args, amount: '999');
      final decoded = makeInboxFlow().flow.decodeCall(request);

      expect(decoded.kind, DecodedCallKind.transfer);
      expect(decoded.recipientLabel, 'Recipient');
      expect(decoded.recipient, _fixtureRecipient);
      expect(decoded.amountBaseUnits, BigInt.from(105000000));
      // 105000000 at 7 decimals == 10.5, regardless of the server's '999'.
      expect(decoded.amount, '10.5');
      expect(decoded.amount, isNot('999'));
    });

    test('decodes a contract recipient back to its C-address', () {
      final args = transferArgsBase64(to: fixtureTarget);
      final decoded =
          makeInboxFlow().flow.decodeCall(buildRequest(args: args));

      expect(decoded.kind, DecodedCallKind.transfer);
      expect(decoded.recipient, fixtureTarget);
    });

    test('decodes the approve spender and amount', () {
      // _approveArgsBase64 defaults to 250000000 base units (== 25).
      final request = buildRequest(
        targetFn: 'approve',
        args: _approveArgsBase64(),
      );
      final decoded = makeInboxFlow().flow.decodeCall(request);

      expect(decoded.kind, DecodedCallKind.approve);
      expect(decoded.recipientLabel, 'Spender');
      expect(decoded.recipient, _fixtureRecipient);
      expect(decoded.amount, '25');
    });

    test('returns the full decoded argument list for an unknown shape', () {
      final args = _encode(<XdrSCVal>[
        XdrSCVal.forAddressStrKey(_fixtureRecipient),
        Util.bigIntToI128ScVal(BigInt.from(42)),
      ]);
      final request = buildRequest(targetFn: 'mint', args: args);
      final decoded = makeInboxFlow().flow.decodeCall(request);

      expect(decoded.kind, DecodedCallKind.unknown);
      expect(decoded.recipient, isNull);
      expect(decoded.arguments, hasLength(2));
      expect(decoded.arguments[0].value, _fixtureRecipient);
      expect(decoded.arguments[1].value, '42');
    });

    test('flags undecodable arguments instead of crashing', () {
      final request = buildRequest(args: const <String>['!!!not-base64!!!']);
      final decoded = makeInboxFlow().flow.decodeCall(request);

      expect(decoded.kind, DecodedCallKind.undecodable);
      expect(decoded.error, isNotNull);
      expect(decoded.recipient, isNull);
    });
  });

  group('ApprovalInboxFlow account scoping', () {
    test('loadPending and pendingCount list only the connected account', () async {
      // buildRequest defaults to smartAccount == fixtureSmartAccount, which is
      // also the connectedAccount makeInboxFlow defaults to.
      final mine = buildRequest(id: 'mine');
      final other = buildRequest(id: 'other', smartAccount: fixtureTarget);
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[mine, other],
        ),
      );

      final pending = await deps.flow.loadPending();
      expect(pending.map((r) => r.id), <String>['mine']);
      expect(await deps.flow.pendingCount(), 1);
    });

    test('loadPending and pendingCount are empty when disconnected', () async {
      final deps = makeInboxFlow(
        connected: false,
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[buildRequest()],
        ),
      );

      expect(await deps.flow.loadPending(), isEmpty);
      expect(await deps.flow.pendingCount(), 0);
    });
  });

  group('ApprovalInboxFlow.approveRequest guards', () {
    test('refuses and does not submit when the escalation targets a different '
        'smart account', () async {
      // The request targets fixtureSmartAccount (the buildRequest default).
      final request = buildRequest();
      final deps = makeInboxFlow(
        connectedAccount: fixtureTarget, // connected to a different account
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      expect(result.error, contains('different smart account'));
      // Refused before any ceremony AND before the pre-submit re-check.
      expect(deps.contractCall.callCount, 0);
      expect(deps.coordination.getCount, 0);
      expect(deps.coordination.lastApprovedId, isNull);
    });

    test('aborts without submitting when the re-fetched status is not pending',
        () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
          // The inbox copy is stale; the server now reports it resolved.
          onGetRequest: (_) =>
              buildRequest(id: request.id, status: 'approved'),
        ),
      );
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      expect(result.error, contains('no longer pending'));
      expect(deps.contractCall.callCount, 0);
      expect(deps.coordination.lastApprovedId, isNull);
    });

    test('aborts without submitting when the pre-submit re-check fails',
        () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
          getError: const CoordinationException('GET /requests/x failed: down'),
        ),
      );
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      final result = await deps.flow.approveRequest(request);

      expect(result.success, isFalse);
      expect(deps.contractCall.callCount, 0);
      expect(deps.coordination.lastApprovedId, isNull);
    });
  });

  group('ApprovalInboxFlow report retry (double-spend safety)', () {
    test('after a confirmed hash, a failed report offers retry-report and never '
        're-submits', () async {
      final request = buildRequest();
      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[request],
        approveError:
            const CoordinationException('report failed', statusCode: 500),
      );
      final deps = makeInboxFlow(coordination: fake);
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      final first = await deps.flow.approveRequest(request);
      expect(first.success, isFalse);
      expect(first.confirmedOnChain, isTrue);
      expect(first.hash, 'TXHASH');
      expect(deps.contractCall.callCount, 1);
      expect(deps.flow.isAwaitingReport(request.id), isTrue);

      // The server recovers; retry-report ONLY reports — no second submission.
      fake.approveError = null;
      final retried = await deps.flow.retryReport(request);
      expect(retried.success, isTrue);
      expect(retried.hash, 'TXHASH');
      expect(deps.contractCall.callCount, 1); // contractCall invoked exactly once
      expect(fake.lastApprovedId, request.id);
      expect(fake.lastApprovedResultHash, 'TXHASH');
      expect(deps.flow.isAwaitingReport(request.id), isFalse);
    });

    test('a re-tapped approve after confirmation reports instead of re-submitting',
        () async {
      final request = buildRequest();
      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[request],
        approveError:
            const CoordinationException('report failed', statusCode: 500),
      );
      final deps = makeInboxFlow(coordination: fake);
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      await deps.flow.approveRequest(request); // confirms, report fails
      expect(deps.contractCall.callCount, 1);

      fake.approveError = null;
      final again = await deps.flow.approveRequest(request); // user re-taps
      expect(again.success, isTrue);
      expect(again.hash, 'TXHASH');
      expect(deps.contractCall.callCount, 1); // NOT re-submitted
    });

    test('retryReport treats a 409 (already resolved) as success', () async {
      final request = buildRequest();
      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[request],
        approveError:
            const CoordinationException('report failed', statusCode: 500),
      );
      final deps = makeInboxFlow(coordination: fake);
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      await deps.flow.approveRequest(request); // confirms, first report fails

      fake.approveError =
          const CoordinationException('already resolved', statusCode: 409);
      final retried = await deps.flow.retryReport(request);

      expect(retried.success, isTrue);
      expect(retried.hash, 'TXHASH');
      expect(deps.flow.isAwaitingReport(request.id), isFalse);
    });

    test('a confirmed tx with no hash is not treated as a re-submittable failure',
        () async {
      final request = buildRequest();
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      // A confirmed result with no hash (hash defaults to null).
      deps.contractCall.result = const OZTransactionResult(success: true);

      final result = await deps.flow.approveRequest(request);
      expect(result.success, isFalse);
      expect(result.confirmedOnChain, isTrue);
      expect(result.hash, isNull);
      expect(deps.contractCall.callCount, 1);

      // Re-tapping must not re-submit even though the hash was empty.
      final again = await deps.flow.approveRequest(request);
      expect(again.success, isFalse);
      expect(deps.contractCall.callCount, 1);
      // Nothing to report: there is no hash to send.
      expect(deps.flow.isAwaitingReport(request.id), isFalse);
    });
  });

  group('ApprovalInboxFlow concurrency', () {
    test('a second concurrent approve throws StateError without re-submitting',
        () async {
      final request = buildRequest();
      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[request],
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final activityLog = container.read(activityLogProvider.notifier);
      final blocking = _BlockingContractCall();
      final flow = ApprovalInboxFlow(
        coordination: fake,
        activityLog: activityLog,
        resolveContractCall: () => blocking,
        resolveConnectedAccount: () => fixtureSmartAccount,
      );

      final firstFuture = flow.approveRequest(request); // in flight, blocked
      await expectLater(
        flow.approveRequest(request),
        throwsA(isA<StateError>()),
      );

      blocking.completer
          .complete(const OZTransactionResult(success: true, hash: 'H'));
      final first = await firstFuture;
      expect(first.success, isTrue);
      expect(blocking.callCount, 1);
    });
  });
}

/// A [ContractCallType] whose call blocks on an external [Completer], so a test
/// can hold an approval in flight while asserting the concurrency guard.
final class _BlockingContractCall implements ContractCallType {
  final Completer<OZTransactionResult> completer =
      Completer<OZTransactionResult>();
  int callCount = 0;

  @override
  Future<OZTransactionResult> contractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
  }) {
    callCount++;
    return completer.future;
  }
}
