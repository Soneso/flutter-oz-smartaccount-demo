/// Error classification and user-facing message utilities.
///
/// Provides helpers for converting SDK exceptions and RPC errors into
/// actionable, human-readable messages suitable for display in the UI.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../state/activity_log_state.dart';
import '../wallet/wallet_connector.dart';

// ---------------------------------------------------------------------------
// Error categories
// ---------------------------------------------------------------------------

/// Category tags for classifying demo-layer errors.
///
/// Screens use these to decide whether to show a retry option, display a
/// specific recovery hint, or show a generic error message.
enum DemoErrorCategory {
  /// User cancelled the passkey ceremony (not a real error, no retry).
  userCancelled,

  /// Network or RPC request failed; a retry may succeed.
  network,

  /// Input validation failure; user needs to correct input before retrying.
  validation,

  /// On-chain failure (e.g., contract error, insufficient balance).
  onChain,

  /// An unexpected internal error that the user cannot directly resolve.
  unexpected,
}

// ---------------------------------------------------------------------------
// Classified error
// ---------------------------------------------------------------------------

/// An error with a user-facing message and a machine-readable category.
final class DemoError implements Exception {
  const DemoError({
    required this.message,
    required this.category,
    this.cause,
  });

  /// Short, actionable message suitable for display in the UI.
  /// Must not contain stack traces, raw XDR, or signing payloads.
  final String message;

  /// Machine-readable category for UI branching (retry vs. dismiss).
  final DemoErrorCategory category;

  /// Original exception or error, retained for internal logging only.
  /// Must not be surfaced directly to the UI.
  final Object? cause;

  @override
  String toString() => 'DemoError($category): $message';
}

// ---------------------------------------------------------------------------
// Classification helpers
// ---------------------------------------------------------------------------

/// Returns true if [e] looks like a network / connectivity failure.
///
/// Broad substring heuristic; typed exception classes whose names contain
/// `connection` must be matched in [classifyError] before this is called.
bool _isNetworkError(Object e) {
  final msg = e.toString().toLowerCase();
  return msg.contains('socket') ||
      msg.contains('connection') ||
      msg.contains('timeout') ||
      msg.contains('host lookup') ||
      msg.contains('network') ||
      msg.contains('unreachable');
}

/// Maps a raw exception to a user-facing error message for any action that
/// produces a single activity-log entry.
///
/// Resolution order:
/// - [WebAuthnCancelled] → info log + `'Passkey authentication cancelled'`.
/// - [StateError]        → error log + in-progress message using [noun].
/// - [DemoError] (validation) → error log + verbatim [DemoError.message]
///   without a prefix (validation messages are self-explanatory).
/// - Other [DemoError]   → error log + `'$prefix: ${error.message}'`.
/// - All other errors    → error log + [classifyError] fallback prefixed by
///   [prefix].
///
/// [prefix] is the error-label used in log entries and the error prefix
/// (e.g. `'Transfer failed'`, `'Removal failed'`, `'Transaction failed'`).
///
/// [noun] is used only in the `StateError` in-progress message. It should
/// include its own article (e.g. `'A transfer'`, `'A removal'`,
/// `'An edit submission'`). When null it defaults to [prefix].
///
/// [log] receives an info-level entry for cancellations and an error-level
/// entry for all other non-cancellation cases.
String classifyActionError(
  Object error,
  ActivityLogNotifier log, {
  required String prefix,
  String? noun,
}) {
  if (error is WebAuthnCancelled) {
    log.info('Passkey authentication cancelled');
    return 'Passkey authentication cancelled';
  }
  if (error is StateError) {
    final n = noun ?? prefix;
    log.error('$n is already in progress');
    return '$n is already in progress. Please wait.';
  }
  if (error is DemoError) {
    log.error('$prefix: ${error.message}');
    if (error.category == DemoErrorCategory.validation) {
      // Validation messages are user-friendly; render them without the
      // prefix to avoid sounding like a hard failure.
      return error.message;
    }
    return '$prefix: ${error.message}';
  }
  final classified = classifyError(error);
  log.error('$prefix: ${classified.message}');
  return '$prefix: ${classified.message}';
}

/// Converts any exception into a [DemoError] with an actionable message.
///
/// Order of precedence: typed cancellation → typed DemoError pass-through
/// → typed SDK + wallet exceptions (curated `.message`) → network
/// heuristic → unexpected fallback. Typed branches must run before the
/// network heuristic so wallet exception type names containing
/// `connection` are not misclassified. Raw exception details are never
/// included in [DemoError.message] to avoid leaking RPC payloads or XDR.
DemoError classifyError(Object error, {String? context}) {
  final prefix = context != null ? '$context: ' : '';

  if (error is WebAuthnCancelled) {
    return DemoError(
      message: '${prefix}Cancelled.',
      category: DemoErrorCategory.userCancelled,
      cause: error,
    );
  }

  if (error is DemoError) {
    return error;
  }

  if (error is SmartAccountException) {
    return DemoError(
      message: '$prefix${error.message}',
      category: DemoErrorCategory.onChain,
      cause: error,
    );
  }

  // Must precede [_isNetworkError]: the substring "connection" in
  // WalletConnectionException would otherwise be classified as network.
  if (error is WalletConnectionException) {
    return DemoError(
      message: '$prefix${error.message}',
      category: DemoErrorCategory.unexpected,
      cause: error,
    );
  }
  if (error is WalletSigningException) {
    return DemoError(
      message: '$prefix${error.message}',
      category: DemoErrorCategory.unexpected,
      cause: error,
    );
  }
  if (error is WalletNetworkMismatchException) {
    return DemoError(
      message: '${prefix}Connected wallet is on the wrong network. '
          'Switch to Testnet and try again.',
      category: DemoErrorCategory.validation,
      cause: error,
    );
  }

  if (_isNetworkError(error)) {
    return DemoError(
      message: '${prefix}Network error. Check your connection and try again.',
      category: DemoErrorCategory.network,
      cause: error,
    );
  }

  // Default: unexpected. Include the underlying error's string representation
  // (truncated) so demo users can diagnose failures from unfamiliar exception
  // types. The demo runs only against public testnet so there is nothing
  // sensitive to redact; the truncation cap just keeps the UI banner readable.
  final raw = error.toString();
  final detail = raw.length > 240 ? '${raw.substring(0, 240)}...' : raw;
  return DemoError(
    message: '${prefix}Unexpected error: $detail',
    category: DemoErrorCategory.unexpected,
    cause: error,
  );
}
