/// Riverpod provider exposing the number of pending agent escalations.
///
/// Drives the badge on the main screen's approval-inbox bell. The count is
/// refreshed on demand only — [PendingRequestCountNotifier.refresh] is called
/// when the main screen first builds and after every approve/reject action in
/// the inbox. There is no background timer, so the provider never leaks a
/// periodic poll: callers refresh at the points where the count can change.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'approval_inbox_flow_provider.dart';

/// Notifier holding the pending-escalation count for the inbox bell badge.
///
/// The initial value is `0` (no badge). A failed refresh (for example when the
/// coordination server is unreachable) leaves the previous count in place
/// rather than flashing the badge to zero, so a transient outage does not hide
/// escalations the user has already seen.
class PendingRequestCountNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Reloads the pending count from the coordination server.
  ///
  /// Swallows all failures: the badge is a best-effort hint and must never
  /// surface an error. The state is only updated when the load succeeds and
  /// the notifier is still mounted.
  Future<void> refresh() async {
    final int count;
    try {
      count = await ref.read(approvalInboxFlowProvider).pendingCount();
    } catch (_) {
      return;
    }
    set(count);
  }

  /// Sets the badge to [count] directly, without a network call.
  ///
  /// Callers that already hold the account-scoped pending length (for example
  /// the inbox screen right after loading the list) use this to keep the badge
  /// in sync without a second identical GET. Negative values are clamped to
  /// zero. Safe to call after the container is disposed.
  void set(int count) {
    try {
      state = count < 0 ? 0 : count;
    } catch (_) {
      // The provider container was disposed while the load was in flight
      // (for example a widget test tore down between pumps); ignore.
    }
  }

  /// Resets the badge to zero (no badge).
  ///
  /// Called when the wallet disconnects: the inbox is scoped to the connected
  /// account, so a disconnected app has no pending escalations to surface.
  void reset() => set(0);
}

/// Provider for the pending-escalation count.
final pendingRequestCountProvider =
    NotifierProvider<PendingRequestCountNotifier, int>(
  PendingRequestCountNotifier.new,
);
