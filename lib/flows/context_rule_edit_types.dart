/// Plain-data types used by the Context Rule Builder screen when running in
/// edit mode.
///
/// These types track the on-chain state of signers and policies for a rule
/// being edited, plus the diff between the original on-chain state and the
/// current form state. The diff is consumed by the edit-flow orchestrator
/// to plan and execute a sequence of per-operation on-chain transactions.
///
/// The shapes are designed so the orchestrator can dispatch operations
/// without re-deriving fields from the underlying SDK signer / policy types.
library;

import '../config/demo_config.dart' show PolicyInfo;
import '../util/policy_type.dart';
import 'context_rule_builder_types.dart';

// ---------------------------------------------------------------------------
// PolicyWeightedEntry
// ---------------------------------------------------------------------------

/// A signer-weight pair staged in the weighted-threshold add form.
///
/// Carries the signer object and its assigned vote weight so the edit
/// flow can forward it to [OZPolicyManager.addWeightedThreshold] without
/// requiring the screen to encode an SCVal.
final class PolicyWeightedEntry {
  /// Constructs a signer-weight pair.
  const PolicyWeightedEntry({required this.signer, required this.weight});

  /// The signer contributing [weight] votes when it authorises.
  final OZSmartAccountSigner signer;

  /// Vote weight contributed by the signer. Must be greater than zero.
  final int weight;
}

// ---------------------------------------------------------------------------
// PolicyInstallSpec
// ---------------------------------------------------------------------------

/// Primitive description of a policy staged in the edit add-policy form.
///
/// Carries enough information for the flow layer to call the appropriate
/// [OZPolicyManager] convenience method (addSimpleThreshold, addWeightedThreshold,
/// addSpendingLimit) without any SDK-encoded blob crossing the UI/flow boundary.
///
/// Only used on the EDIT path (new policies added to an existing rule). The
/// CREATE path continues to use typed [OZPolicyInstallParams] and encodes via
/// [OZPolicyInstallParams.toScVal] at submit time.
sealed class PolicyInstallSpec {
  const PolicyInstallSpec();
}

/// Simple-threshold policy: requires [threshold] of the context rule's
/// signers to authorise. All signers carry equal weight.
final class PolicyInstallSpecSimpleThreshold extends PolicyInstallSpec {
  /// Constructs a simple-threshold spec.
  const PolicyInstallSpecSimpleThreshold({required this.threshold});

  /// Number of signers required to authorise.
  final int threshold;
}

/// Weighted-threshold policy: authorisation succeeds when the summed weights
/// of authorising signers meet or exceed [threshold].
final class PolicyInstallSpecWeightedThreshold extends PolicyInstallSpec {
  /// Constructs a weighted-threshold spec.
  const PolicyInstallSpecWeightedThreshold({
    required this.entries,
    required this.threshold,
  });

  /// Per-signer weight entries.
  final List<PolicyWeightedEntry> entries;

  /// Minimum aggregate weight required to authorise.
  final int threshold;
}

/// Spending-limit policy: caps cumulative spend within a rolling window.
///
/// [amount] is the decimal display string the user entered (e.g. `"100.5"`).
/// [decimals] is the token's scale, resolved before staging.
/// [periodLedgers] is the already-computed ledger count for the chosen period.
final class PolicyInstallSpecSpendingLimit extends PolicyInstallSpec {
  /// Constructs a spending-limit spec.
  const PolicyInstallSpecSpendingLimit({
    required this.amount,
    required this.decimals,
    required this.periodLedgers,
  });

  /// Decimal amount string as entered by the user (e.g. `"100.5"`).
  final String amount;

  /// Decimal scale of the guarded token.
  final int decimals;

  /// Rolling window size in ledgers.
  final int periodLedgers;
}

// ---------------------------------------------------------------------------
// EditSignerEntry
// ---------------------------------------------------------------------------

/// A signer in the edit-mode form, tracking its on-chain state.
///
/// Named [EditSignerEntry] to keep its on-chain bookkeeping fields distinct
/// from [StagedSigner], which is only used in create mode.
final class EditSignerEntry {
  /// Constructs an edit-mode signer entry.
  const EditSignerEntry({
    required this.signer,
    required this.onChainId,
    required this.isOriginal,
    this.isPending = false,
  });

  /// The underlying SDK signer.
  final OZSmartAccountSigner signer;

  /// The on-chain signer ID assigned by the contract, or null if newly
  /// added.
  final int? onChainId;

  /// True when this signer was loaded from the existing on-chain rule.
  final bool isOriginal;

  /// True when this signer is a pending passkey credential (registered
  /// locally but not yet promoted to confirmed status on-chain).
  final bool isPending;

  /// Returns a copy of this entry with selected fields replaced.
  EditSignerEntry copyWith({
    OZSmartAccountSigner? signer,
    int? onChainId,
    bool? isOriginal,
    bool? isPending,
  }) {
    return EditSignerEntry(
      signer: signer ?? this.signer,
      onChainId: onChainId ?? this.onChainId,
      isOriginal: isOriginal ?? this.isOriginal,
      isPending: isPending ?? this.isPending,
    );
  }
}

// ---------------------------------------------------------------------------
// PolicyParams
// ---------------------------------------------------------------------------

/// On-chain parameters for a policy, read from contract storage.
///
/// The fields are union-style: only the ones relevant to the [type] are
/// populated; the others are null.
final class PolicyParams {
  /// Constructs a policy parameters record.
  const PolicyParams({
    required this.type,
    this.threshold,
    this.spendingLimit,
    this.periodDays,
    this.signerWeights,
  });

  /// Policy type identifier: `threshold`, `spending_limit`, or
  /// `weighted_threshold`.
  final String type;

  /// Threshold value for `threshold` and `weighted_threshold` policies.
  final int? threshold;

  /// Formatted XLM amount string for `spending_limit` policies (e.g.
  /// `"1000"`).
  final String? spendingLimit;

  /// Period in days for `spending_limit` policies (periodLedgers /
  /// ledgersPerDay, minimum 1).
  final int? periodDays;

  /// Map of signer-key string to weight for `weighted_threshold` policies.
  final Map<String, int>? signerWeights;
}

// ---------------------------------------------------------------------------
// EditPolicyEntry
// ---------------------------------------------------------------------------

/// A policy in the edit-mode form, tracking its on-chain state and any
/// inline modifications the user has applied.
final class EditPolicyEntry {
  /// Constructs an edit-mode policy entry.
  const EditPolicyEntry({
    required this.info,
    required this.label,
    required this.address,
    required this.onChainId,
    required this.isOriginal,
    this.installSpec,
    this.modified = false,
    this.originalParams,
  });

  /// Known policy metadata (type, name, contract address), or null for an
  /// unknown policy contract.
  final PolicyInfo? info;

  /// Display label shown on the policy card.
  final String label;

  /// Policy contract C-address.
  final String address;

  /// On-chain policy ID assigned by the contract, or null if newly added.
  final int? onChainId;

  /// True when this policy was loaded from the existing on-chain rule.
  final bool isOriginal;

  /// Typed primitive install specification when the user has added a new
  /// policy or edited an existing one. Null while displaying an unchanged
  /// original. The flow dispatches the correct SDK convenience method
  /// (addSimpleThreshold / addWeightedThreshold / addSpendingLimit) based on
  /// the runtime type of this spec at submit time.
  final PolicyInstallSpec? installSpec;

  /// True when the user changed parameters on an existing on-chain policy.
  final bool modified;

  /// On-chain parameters loaded at edit start, used for the inline edit
  /// form's pre-populated values and for change detection.
  final PolicyParams? originalParams;

  /// Returns a copy of this entry with selected fields replaced. Pass
  /// [clearInstallSpec] to set [installSpec] back to null.
  EditPolicyEntry copyWith({
    PolicyInfo? info,
    String? label,
    String? address,
    int? onChainId,
    bool? isOriginal,
    PolicyInstallSpec? installSpec,
    bool clearInstallSpec = false,
    bool? modified,
    PolicyParams? originalParams,
  }) {
    return EditPolicyEntry(
      info: info ?? this.info,
      label: label ?? this.label,
      address: address ?? this.address,
      onChainId: onChainId ?? this.onChainId,
      isOriginal: isOriginal ?? this.isOriginal,
      installSpec: clearInstallSpec ? null : (installSpec ?? this.installSpec),
      modified: modified ?? this.modified,
      originalParams: originalParams ?? this.originalParams,
    );
  }
}

// ---------------------------------------------------------------------------
// ContextRuleEditDiff
// ---------------------------------------------------------------------------

/// Describes the difference between the original on-chain state of a rule
/// and the current form state in the edit-mode builder.
///
/// Produced by the screen layer and consumed by the edit-flow orchestrator.
final class ContextRuleEditDiff {
  /// Constructs a context-rule edit diff.
  const ContextRuleEditDiff({
    required this.ruleId,
    required this.nameChanged,
    required this.newName,
    required this.newSigners,
    required this.removedSigners,
    required this.newPolicies,
    required this.removedPolicies,
    required this.modifiedPolicies,
    required this.expiryChanged,
    required this.newExpiry,
  });

  /// On-chain context rule ID being edited.
  final int ruleId;

  /// True when the rule name was changed.
  final bool nameChanged;

  /// The new name, or null when [nameChanged] is false.
  final String? newName;

  /// Signer entries that are newly added (not yet on-chain).
  final List<EditSignerEntry> newSigners;

  /// Original signer entries that were removed by the user.
  final List<EditSignerEntry> removedSigners;

  /// Policy entries that are newly added (not yet on-chain).
  final List<EditPolicyEntry> newPolicies;

  /// Original policy entries that were removed by the user.
  final List<EditPolicyEntry> removedPolicies;

  /// Original policy entries whose parameters were modified inline.
  final List<EditPolicyEntry> modifiedPolicies;

  /// True when the expiry was changed (set, cleared, or replaced).
  final bool expiryChanged;

  /// The new expiry as a ledger value. When [expiryChanged] is true and
  /// [newExpiry] is null, the rule's expiry should be cleared. The value
  /// is first captured as an offset by the screen layer and converted to an
  /// absolute ledger via the flow's `resolveEditDiffExpiry` call before
  /// submission.
  final int? newExpiry;

  /// True when no changes have been recorded.
  bool get isEmpty =>
      !nameChanged &&
      newSigners.isEmpty &&
      removedSigners.isEmpty &&
      newPolicies.isEmpty &&
      removedPolicies.isEmpty &&
      modifiedPolicies.isEmpty &&
      !expiryChanged;

  /// Total number of on-chain operations that will execute when this diff
  /// is applied.
  ///
  /// Threshold-only policy modifications count as a single `set_threshold`
  /// transaction. All other policy modifications use `remove + re-add` (two
  /// transactions). Every signer add / remove and every policy add / remove
  /// counts as one transaction. Name and expiry changes each count as one.
  int get totalOperations {
    var count = 0;
    if (nameChanged) count++;
    count += newSigners.length;
    count += removedSigners.length;
    count += removedPolicies.length;
    count += newPolicies.length;
    for (final p in modifiedPolicies) {
      count += (p.info?.type == PolicyType.threshold) ? 1 : 2;
    }
    if (expiryChanged) count++;
    return count;
  }

  /// Returns a copy of this diff with selected fields replaced.
  ContextRuleEditDiff copyWith({
    int? ruleId,
    bool? nameChanged,
    String? newName,
    List<EditSignerEntry>? newSigners,
    List<EditSignerEntry>? removedSigners,
    List<EditPolicyEntry>? newPolicies,
    List<EditPolicyEntry>? removedPolicies,
    List<EditPolicyEntry>? modifiedPolicies,
    bool? expiryChanged,
    int? newExpiry,
    bool clearNewExpiry = false,
  }) {
    return ContextRuleEditDiff(
      ruleId: ruleId ?? this.ruleId,
      nameChanged: nameChanged ?? this.nameChanged,
      newName: newName ?? this.newName,
      newSigners: newSigners ?? this.newSigners,
      removedSigners: removedSigners ?? this.removedSigners,
      newPolicies: newPolicies ?? this.newPolicies,
      removedPolicies: removedPolicies ?? this.removedPolicies,
      modifiedPolicies: modifiedPolicies ?? this.modifiedPolicies,
      expiryChanged: expiryChanged ?? this.expiryChanged,
      newExpiry: clearNewExpiry ? null : (newExpiry ?? this.newExpiry),
    );
  }
}

// ---------------------------------------------------------------------------
// ContextRuleEditResult
// ---------------------------------------------------------------------------

/// Result of an edit submission.
///
/// Carries per-operation completion counts, an optional auth-guard
/// indication when the orchestrator pauses to require a fresh reload, the
/// hashes of completed transactions, and the description of the step that
/// failed when [success] is false.
final class ContextRuleEditResult {
  /// Constructs a context-rule edit submission result.
  const ContextRuleEditResult({
    required this.success,
    required this.completedOperations,
    required this.totalOperations,
    required this.partialDueToAuthGuard,
    required this.authGuardMessage,
    required this.error,
    required this.failedStep,
    this.transactionHashes = const <String>[],
  });

  /// True when all planned operations completed successfully.
  ///
  /// May still be true when [partialDueToAuthGuard] is true: the
  /// orchestrator successfully applied every operation it was allowed to
  /// run before the auth-guard pause, and reported the remainder for the
  /// user to re-submit on the next round-trip.
  final bool success;

  /// Number of operations that completed.
  final int completedOperations;

  /// Total number of operations the diff planned to execute.
  final int totalOperations;

  /// True when policy or expiry operations were skipped because the
  /// preceding signer changes invalidated the auth context. The screen
  /// should reload the rule from chain before allowing the user to
  /// re-submit the remaining changes.
  final bool partialDueToAuthGuard;

  /// Human-readable message describing the auth-guard pause, or null when
  /// [partialDueToAuthGuard] is false.
  final String? authGuardMessage;

  /// Sanitised error message when [success] is false. Null otherwise.
  final String? error;

  /// Human-readable description of the step that failed, or null on
  /// success.
  final String? failedStep;

  /// Hashes of every confirmed transaction, in execution order.
  final List<String> transactionHashes;
}
