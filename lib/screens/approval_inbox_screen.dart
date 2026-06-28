/// Approval inbox screen (steps 4 + 5 of the agent-signer flow).
///
/// Lists the policy-rejected smart-account calls the autonomous agent escalated
/// to the coordination server, scoped to the connected smart account. Each card
/// shows the smart account, target contract, function, the decoded rejection
/// reason, and — as the authoritative consent data — the recipient and on-chain
/// amount DECODED from the call arguments that actually execute (never the
/// server-supplied display amount). Per-card Approve and Reject actions.
/// Approving rebuilds the agent's exact call and re-submits it under the user's
/// Default rule (single-signer passkey), then reports the resulting transaction
/// hash back to the server.
///
/// Screens-never-call-SDK rule:
/// This screen never references SDK kit classes or the HTTP client directly.
/// Only [ApprovalInboxFlow] talks to the SDK and the coordination server; the
/// decoded consent data is produced by [ApprovalInboxFlow.decodeCall].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/approval_inbox_flow.dart';
import '../navigation/routes.dart';
import '../services/coordination_client.dart';
import '../state/approval_inbox_flow_provider.dart';
import '../state/demo_state.dart';
import '../state/pending_request_count_provider.dart';
import '../theme/app_theme.dart' show snackBarDefaultDuration;
import '../theme/spacing.dart';
import '../util/clipboard.dart' show copyAndToast;
import '../util/format_utils.dart' show truncateAddress;
import '../util/url_opener.dart' show openTxInExplorer;
import '../widgets/empty_state_card.dart';
import '../widgets/error_card.dart';
import '../widgets/key_value_row.dart';
import '../widgets/loading_button.dart';
import '../widgets/section_description_card.dart';

// ---------------------------------------------------------------------------
// ApprovalInboxScreen
// ---------------------------------------------------------------------------

/// Approval inbox screen.
///
/// [flow] is an optional injected [ApprovalInboxFlow] for testing. When null
/// (production), the screen resolves the flow from [approvalInboxFlowProvider].
class ApprovalInboxScreen extends ConsumerStatefulWidget {
  /// Creates an [ApprovalInboxScreen].
  const ApprovalInboxScreen({this.flow, super.key});

  /// Optional injected [ApprovalInboxFlow] for testing.
  final ApprovalInboxFlow? flow;

  @override
  ConsumerState<ApprovalInboxScreen> createState() =>
      _ApprovalInboxScreenState();
}

class _ApprovalInboxScreenState extends ConsumerState<ApprovalInboxScreen> {
  // ---- Load state ----

  bool _isLoading = false;
  bool _loaded = false;
  String? _loadError;
  List<CoordinationRequest> _pending = const <CoordinationRequest>[];

  /// The in-flight action per request id, so the active card shows the spinner
  /// only on the button whose action is running (approve, reject, or report),
  /// not on every action button.
  final Map<String, _InboxAction> _busyAction = <String, _InboxAction>{};

  /// True while any approve/reject/report action is in flight. All cards'
  /// actions are disabled during that window so a second card cannot start a
  /// concurrent approval.
  bool _actionInFlight = false;

  /// IDs whose transaction confirmed on-chain but whose report-back is still
  /// outstanding: their card shows "Retry report" instead of "Approve" so the
  /// call is never re-submitted.
  final Set<String> _reportPending = <String>{};

  /// Session-scoped list of approved escalations, newest first. Each entry
  /// carries the full on-chain transaction hash so it stays selectable,
  /// copyable, and linkable to an explorer after the confirmation toast has
  /// dismissed. Confirmed-on-chain results that returned no hash are recorded
  /// with an empty [_ApprovedResult.hash] and degrade to a plain notice.
  final List<_ApprovedResult> _approved = <_ApprovedResult>[];

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load());
    });
  }

  /// Resolves the inbox flow at action time so a kit that becomes available
  /// after this screen mounts is picked up on the next call. Tests inject the
  /// flow via [widget.flow] and bypass the provider.
  ApprovalInboxFlow _resolveFlow() {
    return widget.flow ?? ref.read(approvalInboxFlowProvider);
  }

  // -------------------------------------------------------------------------
  // Load
  // -------------------------------------------------------------------------

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final flow = _resolveFlow();
      final pending = await flow.loadPending();
      if (!mounted) return;
      setState(() {
        _pending = pending;
        _isLoading = false;
        _loaded = true;
        // Restore the retry-report affordance for any request whose tx already
        // confirmed but whose report-back is still outstanding.
        _reportPending
          ..clear()
          ..addAll(
            pending.map((r) => r.id).where(flow.isAwaitingReport),
          );
      });
      // Keep the bell badge in sync with the account-scoped list we just
      // loaded, without a second identical GET.
      ref.read(pendingRequestCountProvider.notifier).set(_pending.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = _describeLoadError(e);
        _isLoading = false;
        _loaded = true;
      });
    }
  }

  String _describeLoadError(Object error) {
    if (error is CoordinationException) {
      return 'Could not reach the coordination server: ${error.message}';
    }
    return 'Could not load pending approvals: $error';
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _approve(CoordinationRequest request) async {
    if (_actionInFlight) {
      _showSnack('Another approval is in progress.');
      return;
    }
    setState(() {
      _actionInFlight = true;
      _busyAction[request.id] = _InboxAction.approve;
    });
    ApprovalResult result;
    try {
      result = await _resolveFlow().approveRequest(request);
    } on StateError {
      // The flow's re-entrancy guard tripped (a concurrent approval is
      // already running). Surface clear feedback rather than failing silently.
      if (mounted) _showSnack('Another approval is in progress.');
      return;
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
          _busyAction.remove(request.id);
        });
      }
    }
    if (!mounted) return;
    if (result.success) {
      _recordApproved(request, result.hash ?? '');
      _removeResolved(request.id);
      _showSnack('Approved. Transaction hash shown below.');
      unawaited(SemanticsService.announce(
        'Approval submitted',
        Directionality.of(context),
      ));
    } else if (result.confirmedOnChain) {
      // The transaction confirmed on-chain but reporting it back failed.
      // Persist the outcome regardless of whether a hash is present: when a
      // hash exists it stays copyable/linkable below instead of living only in
      // the transient error snackbar; when it is empty the entry degrades to a
      // plain notice with no copy/explorer affordance. A later successful
      // retry-report replaces this entry (deduped by request id), so no
      // duplicate appears.
      _recordApproved(request, result.hash ?? '');
      // Switch this card to "Retry report" so the call is never re-submitted.
      setState(() => _reportPending.add(request.id));
      _showSnack(result.error ??
          'Transaction confirmed on-chain, but reporting it back failed. '
              'Retry the report.');
    } else {
      _showSnack(result.error ?? 'Approval failed.');
    }
  }

  Future<void> _retryReport(CoordinationRequest request) async {
    if (_actionInFlight) {
      _showSnack('Another approval is in progress.');
      return;
    }
    setState(() {
      _actionInFlight = true;
      _busyAction[request.id] = _InboxAction.retryReport;
    });
    ApprovalResult result;
    try {
      result = await _resolveFlow().retryReport(request);
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
          _busyAction.remove(request.id);
        });
      }
    }
    if (!mounted) return;
    if (result.success) {
      _recordApproved(request, result.hash ?? '');
      _removeResolved(request.id);
      _showSnack('Reported. Transaction hash shown below.');
    } else {
      _showSnack(result.error ?? 'Reporting failed.');
    }
  }

  Future<void> _reject(CoordinationRequest request) async {
    if (_actionInFlight) {
      _showSnack('Another approval is in progress.');
      return;
    }
    final note = await _promptRejectNote();
    // Null means the dialog was dismissed without confirming.
    if (note == null || !mounted) return;

    setState(() {
      _actionInFlight = true;
      _busyAction[request.id] = _InboxAction.reject;
    });
    RejectionResult result;
    try {
      result = await _resolveFlow().rejectRequest(request, note: note);
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
          _busyAction.remove(request.id);
        });
      }
    }
    if (!mounted) return;
    if (result.success) {
      _removeResolved(request.id);
      _showSnack('Rejected.');
    } else {
      _showSnack(result.error ?? 'Rejection failed.');
    }
  }

  /// Appends an approved result to the persistent session list (newest first).
  ///
  /// [hash] is the full on-chain transaction hash, or empty when the
  /// transaction confirmed on-chain without returning a reportable hash. A
  /// short context label is derived from the same decoded recipient/amount the
  /// card already showed, when cheaply available. Re-recording the same request
  /// id replaces the prior entry so a retry-report does not duplicate it.
  void _recordApproved(CoordinationRequest request, String hash) {
    final entry = _ApprovedResult(
      requestId: request.id,
      hash: hash,
      contextLabel: _contextLabelFor(request),
    );
    setState(() {
      _approved
        ..removeWhere((e) => e.requestId == request.id)
        ..insert(0, entry);
    });
  }

  /// Derives a short, human-readable context label from the request's decoded
  /// consent data (the recipient/amount the card already displayed), or null
  /// when no cheap label is available.
  String? _contextLabelFor(CoordinationRequest request) {
    final decoded = _resolveFlow().decodeCall(request);
    switch (decoded.kind) {
      case DecodedCallKind.transfer:
      case DecodedCallKind.approve:
        final amount = decoded.amount;
        final recipient = decoded.recipient;
        if (amount != null && recipient != null) {
          final verb =
              decoded.kind == DecodedCallKind.approve ? 'Approve' : 'Transfer';
          return '$verb $amount to ${truncateAddress(recipient)}';
        }
        return request.targetFn;
      case DecodedCallKind.unknown:
      case DecodedCallKind.undecodable:
        return '${request.targetFn} on ${truncateAddress(request.target)}';
    }
  }

  /// Removes a resolved request from the list and keeps the badge in sync.
  void _removeResolved(String id) {
    setState(() {
      _pending = _pending.where((r) => r.id != id).toList(growable: false);
      _reportPending.remove(id);
    });
    ref.read(pendingRequestCountProvider.notifier).set(_pending.length);
  }

  /// Prompts for an optional rejection note. Returns the (possibly empty) note
  /// when the user confirms, or null when the dialog is dismissed.
  Future<String?> _promptRejectNote() {
    return showDialog<String>(
      context: context,
      builder: (_) => const _RejectNoteDialog(),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: snackBarDefaultDuration),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isConnected = ref.watch(
      demoStateProvider.select((s) => s.isConnected),
    );
    final connectedAccount = ref.watch(
      demoStateProvider.select((s) => s.contractId),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Approval Inbox'),
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => popOrGoMain(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : () => unawaited(_load()),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: kCardPadding,
          children: [
            const SectionDescriptionCard(
              title: 'Agent Escalations',
              message:
                  'Calls the agent attempted that its on-chain policy rejected. '
                  'Approving re-submits the exact call under your Default rule '
                  '(single-signer passkey); rejecting declines it. The recipient '
                  'and amount shown are decoded from the call that executes.',
              tint: SectionDescriptionTint.primary,
            ),
            const SizedBox(height: 12),
            if (isConnected)
              _SigningAsNote(account: connectedAccount)
            else
              const _NotConnectedNote(),
            const SizedBox(height: 12),
            if (_approved.isNotEmpty) ...[
              _ApprovedResultsCard(results: _approved),
              const SizedBox(height: 12),
            ],
            ..._buildContent(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildContent() {
    if (_isLoading && !_loaded) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (_loadError != null) {
      return [
        ErrorCard(
          message: _loadError!,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      ];
    }

    if (_pending.isEmpty) {
      return const [
        EmptyStateCard(
          icon: Icons.inbox_outlined,
          title: 'No pending approvals',
          message:
              'When the agent escalates a policy-rejected call it appears here '
              'for you to approve or reject.',
        ),
      ];
    }

    final flow = _resolveFlow();
    final cards = <Widget>[];
    for (final request in _pending) {
      cards.add(_RequestCard(
        request: request,
        decoded: flow.decodeCall(request),
        loadingAction: _busyAction[request.id],
        enabled: !_actionInFlight,
        needsReport: _reportPending.contains(request.id),
        onApprove: () => _approve(request),
        onReject: () => _reject(request),
        onRetryReport: () => _retryReport(request),
      ));
      cards.add(const SizedBox(height: 12));
    }
    return cards;
  }
}

// ---------------------------------------------------------------------------
// _RejectNoteDialog
// ---------------------------------------------------------------------------

/// Modal that captures an optional rejection note.
///
/// Owns its [TextEditingController] so the controller is disposed only after
/// the dialog route is fully removed (in [State.dispose]), avoiding a
/// "used after disposed" error during the close transition. Pops with the
/// (possibly empty) note on confirm and with `null` on cancel/dismiss.
class _RejectNoteDialog extends StatefulWidget {
  const _RejectNoteDialog();

  @override
  State<_RejectNoteDialog> createState() => _RejectNoteDialogState();
}

class _RejectNoteDialogState extends State<_RejectNoteDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject escalation'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: 'Note (optional)',
          hintText: 'Why are you rejecting this call?',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _SigningAsNote
// ---------------------------------------------------------------------------

/// Inline note shown when connected: names the smart account that will sign and
/// pay for any approval, so the user knows which authority the call executes
/// under.
class _SigningAsNote extends StatelessWidget {
  const _SigningAsNote({required this.account});

  final String? account;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Row(
          children: [
            Icon(Icons.verified_user_outlined,
                size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Approvals sign as '),
                    TextSpan(
                      text: truncateAddress(account ?? ''),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const TextSpan(
                      text: '. Only escalations for this account are shown.',
                    ),
                  ],
                ),
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _NotConnectedNote
// ---------------------------------------------------------------------------

/// Inline hint shown when no wallet is connected. Escalations are scoped to a
/// connected smart account, so the list is empty until the user connects.
class _NotConnectedNote extends StatelessWidget {
  const _NotConnectedNote();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Connect a wallet to review escalations for your smart account. '
                'The inbox shows only the calls raised against the account you '
                'are connected to.',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ApprovedResult
// ---------------------------------------------------------------------------

/// A single approved escalation recorded for the session.
///
/// [hash] is the full on-chain transaction hash; an empty string marks a
/// transaction that confirmed on-chain without returning a reportable hash.
/// [contextLabel] is a short, optional description (the decoded recipient and
/// amount already shown on the card) for identifying the result at a glance.
final class _ApprovedResult {
  const _ApprovedResult({
    required this.requestId,
    required this.hash,
    this.contextLabel,
  });

  final String requestId;
  final String hash;
  final String? contextLabel;

  /// Whether a reportable on-chain transaction hash is available.
  bool get hasHash => hash.isNotEmpty;
}

// ---------------------------------------------------------------------------
// _ApprovedResultsCard
// ---------------------------------------------------------------------------

/// Persistent card listing the session's approved escalations.
///
/// Each entry keeps the full transaction hash on screen — selectable, copyable,
/// and linkable to the testnet explorer — so the hash no longer depends on the
/// transient confirmation toast. Results that confirmed on-chain without a hash
/// degrade to a plain notice with no copy or explorer control.
class _ApprovedResultsCard extends StatelessWidget {
  const _ApprovedResultsCard({required this.results});

  final List<_ApprovedResult> results;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final children = <Widget>[];
    for (var i = 0; i < results.length; i++) {
      if (i > 0) {
        children.add(Divider(
          height: 24,
          color: colorScheme.outlineVariant,
        ));
      }
      children.add(_ApprovedResultTile(result: results[i]));
    }

    return Card(
      elevation: 0,
      color: colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 18, color: colorScheme.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    'Approved',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// One approved-result row inside [_ApprovedResultsCard].
class _ApprovedResultTile extends StatelessWidget {
  const _ApprovedResultTile({required this.result});

  final _ApprovedResult result;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final onContainer = colorScheme.onPrimaryContainer;

    final label = result.contextLabel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null && label.isNotEmpty) ...[
          Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: onContainer,
            ),
          ),
          const SizedBox(height: 6),
        ],
        if (result.hasHash)
          _ApprovedHashContent(hash: result.hash, color: onContainer)
        else
          Text(
            'Confirmed on-chain (no transaction hash returned).',
            style: textTheme.bodySmall?.copyWith(color: onContainer),
          ),
      ],
    );
  }
}

/// Renders the full transaction hash as selectable text plus a copy control and
/// a "View on Explorer" affordance.
class _ApprovedHashContent extends StatelessWidget {
  const _ApprovedHashContent({required this.hash, required this.color});

  final String hash;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Transaction hash',
          style: textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 4),
        // SelectableText keeps the full hash selectable/copyable directly; the
        // explicit Copy button writes the same full hash to the clipboard.
        SelectableText(
          hash,
          style: textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: color,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Semantics(
              button: true,
              label: 'Copy transaction hash',
              value: hash,
              excludeSemantics: true,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(copyAndToast(
                  context,
                  hash,
                  message: 'Transaction hash copied',
                  announce: true,
                )),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: BorderSide(color: color.withAlpha(80)),
                  foregroundColor: color,
                ),
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Copy', style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => unawaited(openTxInExplorer(hash)),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: color,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label:
                  const Text('View on Explorer', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _InboxAction
// ---------------------------------------------------------------------------

/// The action currently running on a request card, so only the button whose
/// action is in flight shows a spinner (not every action button).
enum _InboxAction { approve, reject, retryReport }

// ---------------------------------------------------------------------------
// _RequestCard
// ---------------------------------------------------------------------------

/// A single pending-escalation card with Approve and Reject actions (or a
/// "Retry report" action once the transaction has confirmed on-chain).
class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.decoded,
    required this.loadingAction,
    required this.enabled,
    required this.needsReport,
    required this.onApprove,
    required this.onReject,
    required this.onRetryReport,
  });

  final CoordinationRequest request;
  final DecodedCall decoded;
  final _InboxAction? loadingAction;
  final bool enabled;
  final bool needsReport;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;
  final Future<void> Function() onRetryReport;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt_outlined, size: 18, color: colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    request.targetFn,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                _ReasonChip(reason: request.reason),
              ],
            ),
            const SizedBox(height: 12),
            KeyValueRow.text(
              label: 'Smart Account',
              value: truncateAddress(request.smartAccount),
              monospace: true,
            ),
            KeyValueRow.text(
              label: 'Target',
              value: truncateAddress(request.target),
              monospace: true,
            ),
            KeyValueRow.text(
              label: 'Function',
              value: request.targetFn,
            ),
            ..._buildDecodedRows(context, textTheme, colorScheme),
            const SizedBox(height: 16),
            if (needsReport)
              _buildRetryReportRow(context)
            else
              _buildApproveRejectRow(context),
          ],
        ),
      ),
    );
  }

  /// Renders the authoritative consent data decoded from the call arguments
  /// that actually execute. The server-supplied display amount is never used.
  List<Widget> _buildDecodedRows(
    BuildContext context,
    TextTheme textTheme,
    ColorScheme colorScheme,
  ) {
    switch (decoded.kind) {
      case DecodedCallKind.transfer:
      case DecodedCallKind.approve:
        return [
          KeyValueRow.text(
            label: decoded.recipientLabel ?? 'Recipient',
            value: truncateAddress(decoded.recipient ?? '—'),
            monospace: true,
          ),
          KeyValueRow.text(
            label: 'Amount',
            value: decoded.amount ?? '—',
            emphasised: true,
          ),
        ];
      case DecodedCallKind.unknown:
        return [
          const SizedBox(height: 6),
          Text(
            'Arguments',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          for (final arg in decoded.arguments)
            KeyValueRow.text(
              label: arg.label,
              value: arg.value,
              monospace: true,
            ),
        ];
      case DecodedCallKind.undecodable:
        return [
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_outlined,
                  size: 18, color: colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  decoded.error ??
                      'Cannot decode the stored call arguments. Do not approve.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ];
    }
  }

  Widget _buildApproveRejectRow(BuildContext context) {
    // Approving is blocked while any action is in flight and when the call
    // arguments could not be decoded (the user cannot consent to an unknown
    // call). Rejecting stays available so an undecodable escalation can be
    // declined.
    final canApprove = enabled && decoded.kind != DecodedCallKind.undecodable;
    return Row(
      children: [
        Expanded(
          child: LoadingButton(
            label: 'Approve',
            loadingLabel: 'Approving...',
            isLoading: loadingAction == _InboxAction.approve,
            enabled: canApprove,
            action: onApprove,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LoadingButton(
            label: 'Reject',
            style: LoadingButtonStyle.outlined,
            isLoading: loadingAction == _InboxAction.reject,
            enabled: enabled,
            action: onReject,
          ),
        ),
      ],
    );
  }

  Widget _buildRetryReportRow(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.check_circle_outline,
                size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Confirmed on-chain. Reporting the result back to the agent '
                'failed; retry the report (the call is not re-submitted).',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LoadingButton(
          label: 'Retry report',
          loadingLabel: 'Reporting...',
          isLoading: loadingAction == _InboxAction.retryReport,
          enabled: enabled,
          action: onRetryReport,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _ReasonChip
// ---------------------------------------------------------------------------

/// A small chip rendering the decoded rejection reason name.
class _ReasonChip extends StatelessWidget {
  const _ReasonChip({required this.reason});

  final int reason;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final label = describeRejectionReason(reason);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          color: colorScheme.onErrorContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
