/// Cross-platform clipboard helpers.
///
/// Public addresses and transaction hashes may be copied without restriction.
/// Credential IDs are marked with [markSensitive] as a caller-visible hint;
/// the flag is a no-op today and the copy proceeds identically regardless.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart' show snackBarDefaultDuration;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Copies [text] to the system clipboard.
///
/// [markSensitive] is a caller-visible hint that the item contains sensitive
/// data (e.g. a credential ID). It is a no-op today; the copy proceeds
/// identically regardless of the flag value.
Future<void> copyToClipboard(String text, {bool markSensitive = false}) async {
  await Clipboard.setData(ClipboardData(text: text));
}

/// Copies a transaction hash to the clipboard.
///
/// Transaction hashes are public post-submission metadata; not sensitive.
Future<void> copyTxHash(String hash) => copyToClipboard(hash);

/// Copies [value] to the system clipboard and shows a brief snackbar.
///
/// [message] defaults to `'Copied'`. When [sensitive] is true the caller is
/// responsible for picking a safe snackbar [message] that does not echo the
/// raw value (e.g. `'Contract address copied'`); the flag is also forwarded
/// to [copyToClipboard] as the sensitivity hint.
///
/// The snackbar is dispatched via [ScaffoldMessenger.of] using
/// [snackBarDefaultDuration]. The call is a no-op if the [BuildContext] has
/// been unmounted before the clipboard write resolves.
///
/// When [announce] is true the [message] is also routed to assistive
/// technologies via [SemanticsService.announce] after the snackbar is shown,
/// so screen-reader users hear the confirmation that the visual snackbar
/// conveys.
Future<void> copyAndToast(
  BuildContext context,
  String value, {
  String message = 'Copied',
  bool sensitive = false,
  bool announce = false,
}) async {
  await copyToClipboard(value, markSensitive: sensitive);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: snackBarDefaultDuration,
    ),
  );
  if (announce) {
    await SemanticsService.announce(message, Directionality.of(context));
  }
}

/// Copies a credential ID fragment to the clipboard.
///
/// [truncatedCredentialId] should be pre-truncated by the caller
/// (e.g. cred[0..8]...cred[-8..]) before passing here.
///
/// Passes [markSensitive: true] as a hint.
Future<void> copyCredentialId(String truncatedCredentialId) =>
    copyToClipboard(truncatedCredentialId, markSensitive: true);
