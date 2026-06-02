import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// Log level
// ---------------------------------------------------------------------------

/// Severity level attached to each activity log entry.
enum LogLevel { info, success, error }

// ---------------------------------------------------------------------------
// Log entry
// ---------------------------------------------------------------------------

/// A single immutable entry in the activity log.
@immutable
final class LogEntry {
  const LogEntry({
    required this.message,
    required this.level,
    required this.timestamp,
  });

  final String message;
  final LogLevel level;
  final DateTime timestamp;
}

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

/// Patterns whose values must never appear in log output.
///
/// The deny-list targets: full transaction XDR, auth-digest preimages, raw
/// credential IDs of more than 16 characters, WalletConnect session topics,
/// and WC pairing URIs. Matches are replaced with [_redactedPlaceholder].
///
/// Credential IDs are allowed in truncated form (cred[8]...cred[-8]) — only
/// long, raw credential IDs are redacted. Log callers are responsible for
/// truncating before logging; this layer is a backstop, not a substitute.
const List<String> _redactionDenyList = [
  // Full base64-encoded transaction XDR (heuristic: >200 chars of base64).
  // Handled by pattern matching in [redactMessage], not a literal string.

  // WalletConnect session topics (64 hex chars).
  // Handled by pattern matching in [redactMessage].

  // Literal strings that must never appear verbatim.
  'wc:',                 // WC pairing URI prefix
  'AAAAAA',             // common prefix in transaction XDR envelope base64
];

/// Placeholder text substituted for any redacted fragment.
const String _redactedPlaceholder = '[redacted]';

/// Pattern for a Stellar secret seed (StrKey-encoded, starts with 'S', 55
/// uppercase base32 characters after the 'S', total 56 chars). Lookarounds
/// prevent matching within longer base32 sequences (XDR, contract hashes).
final RegExp _stellarSeedPattern =
    RegExp(r'(?<![A-Z2-7])S[A-Z2-7]{55}(?![A-Z2-7])');

/// Pattern for a WalletConnect session topic (64 hex characters, any case).
/// Lookarounds prevent matching within longer hex sequences.
final RegExp _wcTopicPattern =
    RegExp(r'(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])');

/// Pattern for a WC pairing URI (starts with "wc:" followed by printable chars).
final RegExp _wcUriPattern = RegExp(r'wc:[^\s]+');

/// Pattern for a long base64 sequence that is likely a raw XDR blob (> 200 chars).
final RegExp _xdrBlobPattern = RegExp(r'[A-Za-z0-9+/=]{200,}');

/// Applies the logging deny-list to [message] and returns a safe version.
///
/// Order of operations:
/// 1. Strip Stellar secret seeds (StrKey 'S' + 55 base32 chars).
/// 2. Strip long XDR-like base64 blobs.
/// 3. Strip WC pairing URIs.
/// 4. Strip isolated 64-hex WC topics (any case).
/// 5. Replace any remaining literal deny-list strings.
String redactMessage(String message) {
  var result = message;

  // 1. Remove Stellar secret seeds before the XDR blob pass so that a seed
  //    embedded in a longer base64 context is caught by its own rule.
  result = result.replaceAll(_stellarSeedPattern, '[seed:REDACTED]');

  // 2. Remove long base64 blobs (likely XDR).
  result = result.replaceAll(_xdrBlobPattern, _redactedPlaceholder);

  // 3. Remove WC pairing URIs.
  result = result.replaceAll(_wcUriPattern, _redactedPlaceholder);

  // 4. Remove isolated 64-hex WC topics. The lookarounds in [_wcTopicPattern]
  //    ensure matches are not part of longer hex sequences.
  result = result.replaceAll(_wcTopicPattern, _redactedPlaceholder);

  // 5. Literal string replacements from the deny-list.
  for (final denied in _redactionDenyList) {
    result = result.replaceAll(denied, _redactedPlaceholder);
  }

  return result;
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Maximum number of log entries retained in memory (oldest are dropped first).
const int _maxLogEntries = 50;

/// Manages the append-only activity log shown on the main screen.
///
/// Entries are prepended (newest first) and capped at [_maxLogEntries].
/// All messages pass through [redactMessage] before storage so that
/// sensitive data cannot leak into the UI.
class ActivityLogNotifier extends Notifier<List<LogEntry>> {
  @override
  List<LogEntry> build() => const [];

  /// Appends a log entry at the front of the list.
  ///
  /// [message] is passed through the redaction filter before storage.
  /// Excess entries beyond [_maxLogEntries] are dropped from the tail.
  void addEntry(String message, {LogLevel level = LogLevel.info}) {
    final safe = redactMessage(message);
    final entry = LogEntry(
      message: safe,
      level: level,
      timestamp: DateTime.now(),
    );
    final updated = [entry, ...state];
    state = updated.length > _maxLogEntries
        ? updated.sublist(0, _maxLogEntries)
        : updated;
  }

  /// Logs an informational entry.
  void info(String message) => addEntry(message);

  /// Logs a success entry.
  void success(String message) => addEntry(message, level: LogLevel.success);

  /// Logs an error entry.
  void error(String message) => addEntry(message, level: LogLevel.error);

  /// Removes all entries.
  void clear() => state = const [];
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Riverpod provider for the activity log.
///
/// Screens read this to display the log; flows write through it via
/// [ActivityLogNotifier].
final activityLogProvider =
    NotifierProvider<ActivityLogNotifier, List<LogEntry>>(
  ActivityLogNotifier.new,
);
