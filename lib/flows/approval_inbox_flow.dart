/// Business logic for the approval inbox (steps 4 + 5 of the agent-signer
/// flow).
///
/// [ApprovalInboxFlow] is the single entry point the [ApprovalInboxScreen]
/// uses to talk to the coordination server and the smart-account SDK. Screens
/// must not call into the SDK or the HTTP client directly.
///
/// The flow:
/// - [loadPending] / [pendingCount] — read the pending escalations the agent
///   posted (`GET /requests?status=pending`), scoped client-side to the
///   smart account the user is connected to.
/// - [decodeCall] — derive the authoritative consent data (recipient + on-chain
///   amount) from the stored, base64-encoded `XdrSCVal` arguments that are
///   actually re-submitted, NOT from the server-supplied display-only `amount`.
/// - [approveRequest] — step 4 + 5: rebuild the agent's EXACT call from the
///   stored arguments and re-submit it under the user's Default rule
///   (single-signer passkey path; `selectedSigners` empty), which routes
///   through the relayer (gasless) when a relayer URL is configured on the kit.
///   On a confirmed on-chain result, report the transaction hash back via
///   `POST /requests/{id}/approve`.
/// - [retryReport] — re-report a previously confirmed on-chain approval whose
///   report-back POST failed, WITHOUT re-submitting on-chain.
/// - [rejectRequest] — decline the escalation via `POST /requests/{id}/reject`
///   with an optional note.
///
/// The coordination client and the contract-call submission are both injected,
/// so every path is unit/widget-testable without a network or a live testnet.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart'
    show
        Address,
        OZContractErrorCodes,
        OZTransactionResult,
        StrKey,
        WebAuthnCancelled,
        XdrSCVal,
        XdrSCValType;

import '../config/demo_config.dart' show demoTokenDecimals;
import '../services/coordination_client.dart';
import '../state/activity_log_state.dart';
import '../util/error_utils.dart' show classifyError;
import '../util/format_utils.dart'
    show formatBaseUnitsAsDecimal, truncateAddress;
import 'approve_flow.dart' show ContractCallType;

// ---------------------------------------------------------------------------
// Rejection-reason mapping
// ---------------------------------------------------------------------------

/// Maps an on-chain contract error [reason] code to a human-readable name.
///
/// The numbers come from the OpenZeppelin smart-account contract's `Error`
/// enum and are surfaced by the SDK via [OZContractErrorCodes]. Unknown codes
/// fall back to a generic `Contract error #<n>` label so the inbox never hides
/// a rejection it cannot name.
String describeRejectionReason(int reason) {
  switch (reason) {
    case OZContractErrorCodes.mathOverflow:
      return 'Math overflow';
    case OZContractErrorCodes.keyDataTooLarge:
      return 'Key data too large';
    case OZContractErrorCodes.contextRuleIdsLengthMismatch:
      return 'Context rule IDs length mismatch';
    case OZContractErrorCodes.nameTooLong:
      return 'Name too long';
    case OZContractErrorCodes.unauthorizedSigner:
      return 'Unauthorized signer';
    default:
      return 'Contract error #$reason';
  }
}

// ---------------------------------------------------------------------------
// DecodedCall
// ---------------------------------------------------------------------------

/// The call shape the inbox recognised in a request's decoded arguments.
enum DecodedCallKind {
  /// `transfer(from, to, amount)` — the recipient is the `to` argument.
  transfer,

  /// `approve(from, spender, amount, expiration)` — the recipient is the
  /// `spender` argument.
  approve,

  /// A shape the inbox does not special-case; the full argument list is shown.
  unknown,

  /// The stored arguments could not be decoded at all.
  undecodable,
}

/// A single decoded argument rendered for an unrecognised call shape.
final class DecodedArgument {
  /// Constructs a decoded argument display entry.
  const DecodedArgument({required this.label, required this.value});

  /// Position + type label, for example `Arg 1 (address)`.
  final String label;

  /// Human-readable value (a decoded address, integer, symbol, or — for
  /// exotic types — the verbatim base64 that re-submits).
  final String value;
}

/// Authoritative consent data derived from a request's stored `args`.
///
/// These values come from decoding the opaque base64 `XdrSCVal` arguments that
/// are actually re-submitted on-chain, NOT from the server-supplied,
/// display-only `amount` string. The card the user approves renders THESE
/// values so the displayed call matches the executed call exactly. A
/// buggy/malicious relay cannot show one amount while the args drain a wallet.
final class DecodedCall {
  /// Constructs decoded consent data.
  const DecodedCall({
    required this.kind,
    this.recipient,
    this.recipientLabel,
    this.amountBaseUnits,
    this.amount,
    this.arguments = const <DecodedArgument>[],
    this.error,
  });

  /// The recognised call shape.
  final DecodedCallKind kind;

  /// Decoded recipient address (`to`/`spender`) as a StrKey, or null when the
  /// shape is unknown/undecodable.
  final String? recipient;

  /// Label for [recipient]: `Recipient` for transfer, `Spender` for approve.
  final String? recipientLabel;

  /// Raw decoded on-chain amount in base units (the i128), or null.
  final BigInt? amountBaseUnits;

  /// [amountBaseUnits] formatted at the token's decimal scale, or null.
  final String? amount;

  /// Full decoded argument list, populated when [kind] is
  /// [DecodedCallKind.unknown].
  final List<DecodedArgument> arguments;

  /// User-facing message when [kind] is [DecodedCallKind.undecodable].
  final String? error;
}

// ---------------------------------------------------------------------------
// ApprovalResult
// ---------------------------------------------------------------------------

/// Outcome of an [ApprovalInboxFlow.approveRequest] or
/// [ApprovalInboxFlow.retryReport] call.
///
/// [success] is true when the rebuilt call confirmed on-chain AND the result
/// was reported back to the coordination server. [hash] carries the on-chain
/// transaction hash when one is known. [error] carries a sanitised user-facing
/// message on failure. [confirmedOnChain] is true whenever the transaction
/// confirmed on-chain — even when reporting it back failed — so the inbox can
/// switch the card from a re-submittable "Approve" to an idempotent
/// "Retry report" and NEVER submit the same call twice.
final class ApprovalResult {
  /// Constructs an approval result.
  const ApprovalResult({
    required this.success,
    this.hash,
    this.error,
    this.confirmedOnChain = false,
  });

  /// True when the call confirmed on-chain and the outcome was reported back.
  final bool success;

  /// On-chain transaction hash when known; null otherwise.
  final String? hash;

  /// Sanitised user-facing error message on failure; null on success.
  final String? error;

  /// True when the transaction confirmed on-chain regardless of whether the
  /// report-back succeeded. Once true, the request must never be re-submitted.
  final bool confirmedOnChain;
}

// ---------------------------------------------------------------------------
// RejectionResult
// ---------------------------------------------------------------------------

/// Outcome of an [ApprovalInboxFlow.rejectRequest] call.
final class RejectionResult {
  /// Constructs a rejection result.
  const RejectionResult({required this.success, this.error});

  /// True when the rejection was recorded on the coordination server.
  final bool success;

  /// Sanitised user-facing error message on failure; null on success.
  final String? error;
}

// ---------------------------------------------------------------------------
// ApprovalInboxFlow
// ---------------------------------------------------------------------------

/// Business logic for the approval inbox.
///
/// Construct once per screen instance with the injected coordination client,
/// the activity-log notifier, a [resolveContractCall] callback returning the
/// single-signer submission adapter for the connected kit (or null when no
/// wallet is connected), and a [resolveConnectedAccount] callback returning the
/// C-address of the connected smart account (or null when disconnected). The
/// callbacks are resolved lazily on each call so a kit that becomes available
/// after the flow is created is picked up without rebuilding the flow.
final class ApprovalInboxFlow {
  /// Constructs a flow with injected dependencies.
  ApprovalInboxFlow({
    required CoordinationClient coordination,
    required ActivityLogNotifier activityLog,
    required ContractCallType? Function() resolveContractCall,
    required String? Function() resolveConnectedAccount,
    int tokenDecimals = demoTokenDecimals,
  })  : _coordination = coordination,
        _activityLog = activityLog,
        _resolveContractCall = resolveContractCall,
        _resolveConnectedAccount = resolveConnectedAccount,
        _tokenDecimals = tokenDecimals;

  final CoordinationClient _coordination;
  final ActivityLogNotifier _activityLog;
  final ContractCallType? Function() _resolveContractCall;
  final String? Function() _resolveConnectedAccount;
  final int _tokenDecimals;

  /// True while an approve call is executing, guarding against concurrent
  /// in-flight submissions.
  bool _isApproving = false;

  /// Transaction hashes of requests whose on-chain submission already
  /// confirmed, keyed by request id. A request recorded here must NEVER be
  /// re-submitted on-chain; only its report-back may be retried. The sentinel
  /// [_confirmedNoHashSentinel] marks a request that confirmed on-chain but
  /// returned no hash to report.
  final Map<String, String> _confirmedHashes = <String, String>{};

  /// Marks a request that confirmed on-chain but produced no reportable hash.
  static const String _confirmedNoHashSentinel = '<confirmed-without-hash>';

  /// Error shown when a connected wallet is required for an action.
  static const String _noWalletError =
      'No wallet connected. Connect a wallet to approve.';

  /// Error shown when an escalation targets a different account than the one
  /// the user is connected to.
  static const String _accountMismatchError =
      'This escalation targets a different smart account than the one you are '
      'connected to.';

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  /// Loads the pending escalations for the connected smart account, newest
  /// first.
  ///
  /// The coordination server filters only by status, so the listing is scoped
  /// client-side to `request.smartAccount == ` the connected account. Returns
  /// an empty list when no wallet is connected (there is no account to scope
  /// to). Propagates [CoordinationException] so the screen can render an error
  /// state when the server is unreachable.
  Future<List<CoordinationRequest>> loadPending() async {
    final pending = await _coordination.listPending();
    return _scopeToConnectedAccount(pending);
  }

  /// Returns the number of pending escalations for the connected account.
  ///
  /// Used by the bell badge on the main screen. Scoped to the connected
  /// account exactly like [loadPending]; zero when no wallet is connected.
  Future<int> pendingCount() async {
    final pending = await _coordination.listPending();
    return _scopeToConnectedAccount(pending).length;
  }

  List<CoordinationRequest> _scopeToConnectedAccount(
    List<CoordinationRequest> all,
  ) {
    final account = _resolveConnectedAccount();
    if (account == null) return const <CoordinationRequest>[];
    return all
        .where((r) => r.smartAccount == account)
        .toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // Decode (authoritative consent data)
  // -------------------------------------------------------------------------

  /// Decodes the authoritative consent data the user is actually authorising.
  ///
  /// Decodes each base64 `XdrSCVal` entry in [request.args] and, for the known
  /// `transfer(from, to, amount)` and `approve(from, spender, amount, expiry)`
  /// shapes, derives the on-chain recipient and amount. For any other shape the
  /// full decoded argument list is returned. The server-supplied
  /// [CoordinationRequest.amount] is deliberately ignored: it is display-only
  /// and untrusted.
  DecodedCall decodeCall(CoordinationRequest request) {
    final List<XdrSCVal> args;
    try {
      args = _decodeArgs(request.args);
    } catch (_) {
      return const DecodedCall(
        kind: DecodedCallKind.undecodable,
        error: 'Cannot decode the stored call arguments. Do not approve.',
      );
    }

    switch (request.targetFn) {
      case 'transfer':
        // transfer(from, to, amount)
        if (args.length == 3) {
          final decoded = _decodeTransferLike(
            args,
            recipientIndex: 1,
            amountIndex: 2,
            recipientLabel: 'Recipient',
          );
          if (decoded != null) return decoded;
        }
        break;
      case 'approve':
        // approve(from, spender, amount, expiration)
        if (args.length == 4) {
          final decoded = _decodeTransferLike(
            args,
            recipientIndex: 1,
            amountIndex: 2,
            recipientLabel: 'Spender',
          );
          if (decoded != null) return decoded;
        }
        break;
    }

    // Unknown shape (or a known function with an unexpected argument count):
    // surface the full decoded argument list so nothing is hidden.
    return DecodedCall(
      kind: DecodedCallKind.unknown,
      arguments: _summariseArgs(args),
    );
  }

  DecodedCall? _decodeTransferLike(
    List<XdrSCVal> args, {
    required int recipientIndex,
    required int amountIndex,
    required String recipientLabel,
  }) {
    final recipient = _decodeAddress(args[recipientIndex]);
    final amountBaseUnits = args[amountIndex].toBigInt();
    if (recipient == null || amountBaseUnits == null) return null;
    return DecodedCall(
      kind: recipientLabel == 'Spender'
          ? DecodedCallKind.approve
          : DecodedCallKind.transfer,
      recipient: recipient,
      recipientLabel: recipientLabel,
      amountBaseUnits: amountBaseUnits,
      amount: formatBaseUnitsAsDecimal(amountBaseUnits, decimals: _tokenDecimals),
    );
  }

  // -------------------------------------------------------------------------
  // Approve (steps 4 + 5)
  // -------------------------------------------------------------------------

  /// Rebuilds and re-submits the agent's exact call, then reports the outcome.
  ///
  /// Before submitting, guards in order: a wallet must be connected; the
  /// escalation must target the connected smart account ([_accountMismatchError]
  /// otherwise, BEFORE any passkey ceremony); the stored arguments must decode;
  /// and a fresh `GET /requests/{id}` must still report `pending` (a stale
  /// inbox / cross-device resolution aborts the submission). Once
  /// [OZTransactionResult] confirms a hash, that request is recorded and can
  /// never be re-submitted — a failed report-back returns
  /// [ApprovalResult.confirmedOnChain] true so the inbox offers [retryReport]
  /// instead of a second submit.
  ///
  /// A server-side atomic claim (pending -> in_progress on the first read)
  /// would additionally close the cross-device time-of-check/time-of-use
  /// window; that server change is out of scope here, so this guard is the
  /// best-effort client-side mitigation.
  Future<ApprovalResult> approveRequest(CoordinationRequest request) async {
    if (_isApproving) {
      throw StateError('An approval is already in progress.');
    }
    _isApproving = true;

    try {
      // If this request already confirmed on-chain, never re-submit: route to
      // the idempotent report-back path instead.
      if (_confirmedHashes.containsKey(request.id)) {
        return retryReport(request);
      }

      final contractCall = _resolveContractCall();
      if (contractCall == null) {
        return const ApprovalResult(success: false, error: _noWalletError);
      }

      // Account-scope guard: refuse before any ceremony when the escalation
      // targets a different smart account than the connected one.
      final connectedAccount = _resolveConnectedAccount();
      if (connectedAccount == null) {
        return const ApprovalResult(success: false, error: _noWalletError);
      }
      if (connectedAccount != request.smartAccount) {
        _activityLog.error(_accountMismatchError);
        return const ApprovalResult(
          success: false,
          error: _accountMismatchError,
        );
      }

      final List<XdrSCVal> targetArgs;
      try {
        targetArgs = _decodeArgs(request.args);
      } on FormatException catch (e) {
        final message = 'Cannot decode the stored call arguments: ${e.message}';
        _activityLog.error(message);
        return ApprovalResult(success: false, error: message);
      }

      // Re-check the request is still pending immediately before submitting so
      // a stale inbox / cross-device resolution does not trigger a duplicate
      // on-chain transfer. Refuse to submit if it is not pending or the check
      // fails.
      try {
        final latest = await _coordination.getRequest(request.id);
        if (latest.status != CoordinationRequest.statusPending) {
          final message =
              'This escalation is no longer pending (status: ${latest.status}); '
              'it was resolved elsewhere. Refresh the inbox.';
          _activityLog.info(message);
          return ApprovalResult(success: false, error: message);
        }
      } catch (e) {
        final classified = classifyError(
          e,
          context: 'Could not re-check the escalation before submitting',
        );
        _activityLog.error(classified.message);
        return ApprovalResult(success: false, error: classified.message);
      }

      _activityLog.info(
        'Approving agent call ${request.targetFn} on '
        '${truncateAddress(request.target)}',
      );

      final OZTransactionResult result;
      try {
        result = await contractCall.contractCall(
          target: request.target,
          targetFn: request.targetFn,
          targetArgs: targetArgs,
        );
      } on WebAuthnCancelled {
        _activityLog.info('Passkey authentication cancelled');
        return const ApprovalResult(
          success: false,
          error: 'Passkey authentication cancelled',
        );
      } catch (e) {
        final classified = classifyError(e, context: 'Approval failed');
        _activityLog.error(classified.message);
        return ApprovalResult(success: false, error: classified.message);
      }

      if (!result.success) {
        final message = 'Approval failed: ${result.error ?? 'Unknown error'}';
        _activityLog.error(message);
        return ApprovalResult(success: false, error: message);
      }

      final hash = result.hash ?? '';
      // The transaction confirmed on-chain. From here on this request must
      // NEVER be re-submitted, even when the hash is empty or the report-back
      // fails. Record it before attempting the report.
      _confirmedHashes[request.id] =
          hash.isEmpty ? _confirmedNoHashSentinel : hash;

      if (hash.isEmpty) {
        // A confirmed tx with no hash cannot be reported (the server requires a
        // non-empty resultHash), but it must not be treated as a re-submittable
        // failure: flag it confirmed so the inbox removes the Approve button.
        const message =
            'Approval confirmed on-chain but no transaction hash was returned; '
            'the agent could not be notified automatically.';
        _activityLog.error(message);
        return const ApprovalResult(
          success: false,
          confirmedOnChain: true,
          error: message,
        );
      }

      // Step 5: report the confirmed hash back so the agent learns the outcome.
      return _reportApproval(request.id, hash);
    } finally {
      _isApproving = false;
    }
  }

  /// Re-reports a previously confirmed on-chain approval WITHOUT re-submitting.
  ///
  /// Used by the inbox's "Retry report" affordance after [approveRequest]
  /// confirmed the transaction on-chain but the report-back POST failed. Looks
  /// up the hash recorded against [request.id] during the confirmed approve and
  /// POSTs only `/requests/{id}/approve`. Never calls `contractCall`. The
  /// server is idempotent: a `409` (already resolved) is treated as success.
  Future<ApprovalResult> retryReport(CoordinationRequest request) async {
    final recordedHash = _confirmedHashes[request.id];
    if (recordedHash == null || recordedHash == _confirmedNoHashSentinel) {
      const message =
          'No confirmed transaction hash is available to report for this '
          'escalation.';
      _activityLog.error(message);
      return const ApprovalResult(success: false, error: message);
    }

    try {
      await _coordination.approve(request.id, resultHash: recordedHash);
    } on CoordinationException catch (e) {
      if (e.statusCode == 409) {
        // Already resolved server-side: the report is effectively complete.
        _confirmedHashes.remove(request.id);
        _activityLog.info(
          'Escalation already resolved on the coordination server. '
          'Hash: $recordedHash',
        );
        return ApprovalResult(success: true, hash: recordedHash);
      }
      final message =
          'Reporting the approval failed: ${e.message} '
          '(transaction confirmed on-chain: $recordedHash)';
      _activityLog.error(message);
      return ApprovalResult(
        success: false,
        hash: recordedHash,
        confirmedOnChain: true,
        error: message,
      );
    } catch (e) {
      final classified =
          classifyError(e, context: 'Reporting the approval failed');
      _activityLog.error(classified.message);
      return ApprovalResult(
        success: false,
        hash: recordedHash,
        confirmedOnChain: true,
        error: '${classified.message} '
            '(transaction confirmed on-chain: $recordedHash)',
      );
    }

    _confirmedHashes.remove(request.id);
    _activityLog.success('Agent call approved. Hash: $recordedHash');
    return ApprovalResult(success: true, hash: recordedHash);
  }

  /// Reports a confirmed [hash] back to the coordination server for [id].
  ///
  /// On failure the result keeps the hash and flags [ApprovalResult]
  /// `confirmedOnChain` so the inbox offers a retry that never re-submits.
  Future<ApprovalResult> _reportApproval(String id, String hash) async {
    try {
      await _coordination.approve(id, resultHash: hash);
    } catch (e) {
      final classified =
          classifyError(e, context: 'Reporting the approval failed');
      _activityLog.error(classified.message);
      return ApprovalResult(
        success: false,
        hash: hash,
        confirmedOnChain: true,
        error: '${classified.message} '
            '(transaction confirmed on-chain: $hash)',
      );
    }

    _confirmedHashes.remove(id);
    _activityLog.success('Agent call approved. Hash: $hash');
    return ApprovalResult(success: true, hash: hash);
  }

  /// Whether [id] has a confirmed on-chain transaction whose report-back is
  /// still outstanding.
  ///
  /// The inbox uses this after reloading the list to keep showing a
  /// "Retry report" affordance (instead of a re-submittable "Approve") for a
  /// request whose transaction already confirmed but whose report never
  /// reached the server. The no-hash sentinel does not count: there is nothing
  /// to report.
  bool isAwaitingReport(String id) {
    final hash = _confirmedHashes[id];
    return hash != null && hash != _confirmedNoHashSentinel;
  }

  // -------------------------------------------------------------------------
  // Reject
  // -------------------------------------------------------------------------

  /// Declines [request], recording an optional [note] on the coordination
  /// server.
  ///
  /// An empty or whitespace-only note is sent as no note. Returns a
  /// [RejectionResult]; on failure [RejectionResult.error] is sanitised and
  /// safe to display verbatim.
  Future<RejectionResult> rejectRequest(
    CoordinationRequest request, {
    String? note,
  }) async {
    final trimmed = note?.trim();
    final effectiveNote =
        (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    try {
      await _coordination.reject(request.id, note: effectiveNote);
      _activityLog.info(
        'Rejected agent call ${request.targetFn} on '
        '${truncateAddress(request.target)}',
      );
      return const RejectionResult(success: true);
    } catch (e) {
      final classified = classifyError(e, context: 'Rejection failed');
      _activityLog.error(classified.message);
      return RejectionResult(success: false, error: classified.message);
    }
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Decodes the base64-encoded `XdrSCVal` argument list verbatim.
  ///
  /// Throws [FormatException] when an entry is not valid base64 or not a valid
  /// `XdrSCVal` encoding, so the caller can surface a graceful error rather
  /// than crash.
  List<XdrSCVal> _decodeArgs(List<String> encoded) {
    final decoded = <XdrSCVal>[];
    for (final entry in encoded) {
      try {
        decoded.add(XdrSCVal.fromBase64EncodedXdrString(entry));
      } on FormatException {
        rethrow;
      } catch (e) {
        throw FormatException('invalid XdrSCVal argument', e.toString());
      }
    }
    return decoded;
  }

  /// Decodes an address `XdrSCVal` to its StrKey form, or null when [val] is
  /// not an address or cannot be decoded.
  String? _decodeAddress(XdrSCVal val) {
    if (val.discriminant != XdrSCValType.SCV_ADDRESS) return null;
    try {
      final address = Address.fromXdrSCVal(val);
      switch (address.type) {
        case Address.TYPE_ACCOUNT:
          return address.accountId;
        case Address.TYPE_MUXED_ACCOUNT:
          return address.muxedAccountId;
        case Address.TYPE_CONTRACT:
          // Address.fromXdr stores a contract id as hex; render the C-address.
          final hex = address.contractId;
          return hex == null ? null : StrKey.encodeContractIdHex(hex);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  List<DecodedArgument> _summariseArgs(List<XdrSCVal> args) {
    final out = <DecodedArgument>[];
    for (var i = 0; i < args.length; i++) {
      out.add(DecodedArgument(
        label: 'Arg $i (${_scValTypeName(args[i].discriminant)})',
        value: _describeScVal(args[i]),
      ));
    }
    return out;
  }

  String _describeScVal(XdrSCVal val) {
    final type = val.discriminant;
    if (type == XdrSCValType.SCV_ADDRESS) {
      final decoded = _decodeAddress(val);
      if (decoded != null) return decoded;
    }
    final asBigInt = val.toBigInt();
    if (asBigInt != null) return asBigInt.toString();
    if (type == XdrSCValType.SCV_U32 && val.u32 != null) {
      return val.u32!.uint32.toString();
    }
    if (type == XdrSCValType.SCV_I32 && val.i32 != null) {
      return val.i32!.int32.toString();
    }
    if (type == XdrSCValType.SCV_U64 && val.u64 != null) {
      return val.u64!.uint64.toString();
    }
    if (type == XdrSCValType.SCV_I64 && val.i64 != null) {
      return val.i64!.int64.toString();
    }
    if (type == XdrSCValType.SCV_BOOL && val.b != null) {
      return val.b!.toString();
    }
    if (type == XdrSCValType.SCV_SYMBOL && val.sym != null) {
      return val.sym!;
    }
    if (type == XdrSCValType.SCV_STRING && val.str != null) {
      return val.str!;
    }
    // Exotic types: show the verbatim base64 that re-submits rather than hide
    // it, so the value remains verifiable.
    return val.toBase64EncodedXdrString();
  }

  String _scValTypeName(XdrSCValType type) {
    if (type == XdrSCValType.SCV_ADDRESS) return 'address';
    if (type == XdrSCValType.SCV_I128) return 'i128';
    if (type == XdrSCValType.SCV_U128) return 'u128';
    if (type == XdrSCValType.SCV_I256) return 'i256';
    if (type == XdrSCValType.SCV_U256) return 'u256';
    if (type == XdrSCValType.SCV_U32) return 'u32';
    if (type == XdrSCValType.SCV_I32) return 'i32';
    if (type == XdrSCValType.SCV_U64) return 'u64';
    if (type == XdrSCValType.SCV_I64) return 'i64';
    if (type == XdrSCValType.SCV_BOOL) return 'bool';
    if (type == XdrSCValType.SCV_SYMBOL) return 'symbol';
    if (type == XdrSCValType.SCV_STRING) return 'string';
    if (type == XdrSCValType.SCV_BYTES) return 'bytes';
    if (type == XdrSCValType.SCV_VEC) return 'vec';
    if (type == XdrSCValType.SCV_MAP) return 'map';
    return 'value';
  }
}
