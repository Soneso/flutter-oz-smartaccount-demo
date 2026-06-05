/// Business logic for the Account Signers screen.
///
/// [AccountSignersFlow] is the single entry point for loading the
/// deduplicated set of signers registered across every context rule on the
/// connected smart account. The [KnownSignersScreen] delegates every SDK
/// interaction here; screens must not call into the SDK directly.
///
/// The flow fetches all on-chain context rules from
/// [ContextRuleManagerType.listContextRules], deduplicates signers by
/// [OZSmartAccountBuilders.getSignerKey] (preserving insertion order via a
/// [LinkedHashMap]), and groups each unique signer with the rules that
/// reference it.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../util/error_utils.dart';
import 'transfer_flow.dart' show ContextRuleManagerType;

// ---------------------------------------------------------------------------
// SignerEntry — a unique signer with its rule memberships
// ---------------------------------------------------------------------------

/// A single deduplicated signer paired with the list of context rules in
/// which it appears.
///
/// Returned by [AccountSignersFlow.loadAccountSigners] to drive the read-only
/// signers list on the Account Signers screen. The [contextRules] list is
/// ordered by insertion (which matches rule-fetch order from the SDK).
final class SignerEntry {
  /// Constructs a signer entry record.
  const SignerEntry({
    required this.signer,
    required this.contextRules,
  });

  /// The on-chain signer identity (delegated, passkey, or Ed25519).
  final OZSmartAccountSigner signer;

  /// Every context rule that references [signer], in the order rules were
  /// returned by the SDK.
  final List<OZParsedContextRule> contextRules;
}

// ---------------------------------------------------------------------------
// AccountSignersFlow
// ---------------------------------------------------------------------------

/// Business logic for the Account Signers screen.
///
/// Construct once per screen instance, passing the Riverpod notifiers and
/// the [ContextRuleManagerType] adapter as direct dependencies. Mirrors the
/// dependency-injection shape of [TransferFlow] and [ContextRuleFlow] so
/// tests can substitute mocks without needing a live kit.
final class AccountSignersFlow {
  /// Constructs a flow with injected dependencies.
  ///
  /// [demoState] and [activityLog] are the Riverpod notifiers. The flow
  /// reads connection state from [demoState] to decide whether to issue any
  /// SDK calls. [contextRuleManager] is the adapter used to enumerate
  /// on-chain context rules.
  AccountSignersFlow({
    required DemoStateNotifier demoState,
    required ActivityLogNotifier activityLog,
    required ContextRuleManagerType contextRuleManager,
  })  : _demoState = demoState,
        _activityLog = activityLog,
        _contextRuleManager = contextRuleManager;

  final DemoStateNotifier _demoState;
  final ActivityLogNotifier _activityLog;
  final ContextRuleManagerType _contextRuleManager;

  // ---- Re-entrancy guard ----

  /// True while a load is executing. Used to drop concurrent calls so a
  /// rapid Refresh tap cannot kick off overlapping fetches.
  bool _isLoading = false;

  // -------------------------------------------------------------------------
  // Public: loadAccountSigners
  // -------------------------------------------------------------------------

  /// Loads every unique signer registered on the connected smart account.
  ///
  /// Returns an empty list when the wallet is not connected; in that branch
  /// no SDK call is issued and no log entry is emitted.
  ///
  /// On success, logs an info entry of the form:
  /// `Loaded {N} unique signer(s) from {M} context rule(s)`.
  ///
  /// On failure, the underlying exception is wrapped by [classifyError] for
  /// the activity log and rethrown to the caller so the screen can display a
  /// sanitised error card. The internal re-entrancy guard is released even
  /// when the underlying fetch throws.
  Future<List<SignerEntry>> loadAccountSigners() async {
    if (!_demoState.currentState.isConnected) {
      return const <SignerEntry>[];
    }

    if (_isLoading) {
      throw StateError('A signers load is already in progress.');
    }
    _isLoading = true;

    try {
      final List<OZParsedContextRule> rules;
      try {
        rules = await _contextRuleManager.listContextRules();
      } catch (e) {
        final classified = classifyError(e);
        _activityLog.error('Failed to load signers: ${classified.message}');
        rethrow;
      }

      // Insertion-order preserving map keyed by the SDK's stable signer key.
      // The value carries the first-seen signer instance plus an accumulator
      // for rule memberships so order across rules is the order returned by
      // the SDK. Dart's default `{}` literal yields a `LinkedHashMap` which
      // preserves insertion order.
      final accumulator = <String, _SignerAccumulator>{};

      for (final rule in rules) {
        for (final signer in rule.signers) {
          final key = OZSmartAccountBuilders.getSignerKey(signer);
          final existing = accumulator[key];
          if (existing != null) {
            existing.rules.add(rule);
          } else {
            accumulator[key] = _SignerAccumulator(
              signer: signer,
              rules: <OZParsedContextRule>[rule],
            );
          }
        }
      }

      final entries = accumulator.values
          .map(
            (a) => SignerEntry(
              signer: a.signer,
              contextRules: List<OZParsedContextRule>.unmodifiable(a.rules),
            ),
          )
          .toList(growable: false);

      _activityLog.info(
        'Loaded ${entries.length} unique signer(s) '
        'from ${rules.length} context rule(s)',
      );
      return entries;
    } finally {
      _isLoading = false;
    }
  }
}

// ---------------------------------------------------------------------------
// _SignerAccumulator — internal mutable holder used while grouping
// ---------------------------------------------------------------------------

/// Internal mutable holder used while grouping signers by their unique key.
///
/// Not exposed; the public flow returns immutable [SignerEntry] values
/// derived from these accumulators.
final class _SignerAccumulator {
  _SignerAccumulator({required this.signer, required this.rules});

  final OZSmartAccountSigner signer;
  final List<OZParsedContextRule> rules;
}
