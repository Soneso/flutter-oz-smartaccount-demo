/// Business logic for the "Delegate to agent" screen (step 2 of the
/// agent-signer flow).
///
/// [DelegateToAgentFlow] composes a single `addContextRule` call that grants
/// an autonomous agent a scoped, spend-capped, time-bounded authority on the
/// connected smart account:
///
/// - context type `CallContract(token)` — the rule only matches calls to the
///   one token contract the agent may touch.
/// - signers `[Ed25519 external signer]` — the agent's Ed25519 public key,
///   verified through the Ed25519 verifier contract. The agent owns the
///   matching secret; only its public key is pasted into this screen.
/// - policies `{ spending-limit: cap per period }` — a maximum spend over a
///   rolling ledger window.
/// - `validUntil` — an absolute ledger past which the rule stops applying.
///
/// The flow reuses [ContextRuleFlow] for the actual SDK interaction
/// (`addContextRule`, `resolveAbsoluteLedger`, `buildEd25519Signer`,
/// `buildCallContractContextType`, `resolveSpendingLimitDecimals`) so the
/// composition lives in one place and stays unit-testable without a network:
/// the underlying [ContextRuleFlow] is constructed with injectable manager /
/// environment adapters that tests replace with mocks.
library;

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart'
    show KeyPair, StrKey;

import '../config/demo_config.dart' as config;
import '../state/activity_log_state.dart';
import '../util/error_utils.dart' show classifyError;
import '../util/format_utils.dart'
    show stellarDecimalAmountPattern, truncateAddress;
import '../util/policy_type.dart' show PolicyType;
import 'context_rule_builder_types.dart'
    show
        ContextRuleResult,
        FlowPolicyEntry,
        OZContextRuleType,
        OZSmartAccountSigner,
        OZSpendingLimitPolicyParams,
        OZTransactionOperations,
        SmartAccountValidationException;
import 'context_rule_flow.dart' show ContextRuleFlow;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default human-readable name for the delegation context rule.
///
/// Kept within the on-chain 20-byte name limit
/// ([ContextRuleBuilderLimits.maxRuleNameBytes]).
const String defaultDelegationRuleName = 'Agent';

// ---------------------------------------------------------------------------
// DelegationSummary
// ---------------------------------------------------------------------------

/// Structured description of an authorised delegation, shown on the
/// confirmation card after a successful submission.
final class DelegationSummary {
  /// Constructs a delegation summary.
  const DelegationSummary({
    required this.agentPublicKey,
    required this.tokenContract,
    required this.amount,
    required this.periodLedgers,
    required this.validUntilLedger,
    required this.ruleName,
    required this.spendingLimitPolicyAddress,
    required this.verifierAddress,
  });

  /// The agent's Stellar public key (G-address) that was authorised.
  final String agentPublicKey;

  /// The token contract the agent is scoped to (C-address).
  final String tokenContract;

  /// The human-readable spending cap (decimal string).
  final String amount;

  /// The spending-limit rolling window in ledgers.
  final int periodLedgers;

  /// Absolute ledger past which the rule expires, or null when it never
  /// expires.
  final int? validUntilLedger;

  /// The context-rule name written on-chain.
  final String ruleName;

  /// The spending-limit policy contract address (C-address).
  final String spendingLimitPolicyAddress;

  /// The Ed25519 verifier contract address (C-address).
  final String verifierAddress;
}

// ---------------------------------------------------------------------------
// DelegationResult
// ---------------------------------------------------------------------------

/// Outcome of a [DelegateToAgentFlow.delegateToAgent] call.
///
/// [success] is true when the `addContextRule` transaction confirmed
/// on-chain. [hash] and [summary] are populated on success; [error] carries a
/// sanitised user-facing message on failure.
final class DelegationResult {
  /// Constructs a delegation result.
  const DelegationResult({
    required this.success,
    this.hash,
    this.error,
    this.summary,
  });

  /// True on confirmed on-chain submission.
  final bool success;

  /// On-chain transaction hash on success.
  final String? hash;

  /// Sanitised error message on failure.
  final String? error;

  /// Structured rule summary on success.
  final DelegationSummary? summary;
}

// ---------------------------------------------------------------------------
// DelegateToAgentFlow
// ---------------------------------------------------------------------------

/// Business logic for the delegate-to-agent screen.
///
/// Construct once per screen instance, wrapping the shared [ContextRuleFlow].
final class DelegateToAgentFlow {
  /// Constructs a flow with injected dependencies.
  ///
  /// [contextRuleFlow] supplies the SDK seam (its manager / environment
  /// adapters are themselves injectable, which is what makes this flow
  /// testable without a network). [activityLog] receives progress messages.
  DelegateToAgentFlow({
    required ContextRuleFlow contextRuleFlow,
    required ActivityLogNotifier activityLog,
  })  : _contextRuleFlow = contextRuleFlow,
        _activityLog = activityLog;

  final ContextRuleFlow _contextRuleFlow;
  final ActivityLogNotifier _activityLog;

  bool _isSubmitting = false;

  // -------------------------------------------------------------------------
  // Public: configuration accessors
  // -------------------------------------------------------------------------

  /// The spending-limit policy contract address from the demo configuration's
  /// [config.knownPolicies], used as the policy the delegation installs.
  String get spendingLimitPolicyAddress {
    return config.knownPolicies
        .firstWhere((p) => p.type == PolicyType.spendingLimit)
        .address;
  }

  /// The Ed25519 verifier C-address the agent signer is registered under, or
  /// null when no kit environment is configured.
  String? get ed25519VerifierAddress => _contextRuleFlow.ed25519VerifierAddress;

  // -------------------------------------------------------------------------
  // Public: validation
  // -------------------------------------------------------------------------

  /// Validates [value] as a well-formed Stellar agent public key (G-address).
  ///
  /// Returns null when [value] is empty (so the form is not flagged on initial
  /// render) or when it is a valid Stellar account public key. Returns an error
  /// string otherwise. The agent emits its public key as a Stellar G-address
  /// (StrKey, checksummed), so the screen accepts the same representation.
  String? validateAgentPublicKey(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (!StrKey.isValidStellarAccountId(trimmed)) {
      return 'Must be a valid Stellar agent public key (G...).';
    }
    return null;
  }

  /// Validates [value] against the spending-limit amount rules.
  ///
  /// Returns null when [value] is empty. Otherwise returns one of the
  /// validation error strings when the value fails parsing, uses scientific
  /// notation, exceeds 7-decimal precision, or is not positive.
  static String? validateAmount(String value) {
    if (value.isEmpty) return null;
    if (value.toLowerCase().contains('e')) {
      return 'Scientific notation is not supported';
    }
    if (!stellarDecimalAmountPattern.hasMatch(value)) {
      return 'Must be a valid number';
    }
    final parsed = double.tryParse(value);
    if (parsed == null) {
      return 'Must be a valid number';
    }
    if (parsed <= 0) {
      return 'Must be greater than zero';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Public: resolveTokenDecimals
  // -------------------------------------------------------------------------

  /// Resolves the decimal scale of the spending-limit guarded token.
  ///
  /// Delegates to [ContextRuleFlow.resolveSpendingLimitDecimals]: the native
  /// token resolves without a network call; a custom token's `decimals()` is
  /// fetched on-chain. The amount-to-base-units conversion in
  /// [delegateToAgent] must use the value returned here so the cap is scaled
  /// with the correct precision.
  Future<int> resolveTokenDecimals(String tokenContract) {
    return _contextRuleFlow.resolveSpendingLimitDecimals(tokenContract);
  }

  // -------------------------------------------------------------------------
  // Public: delegateToAgent
  // -------------------------------------------------------------------------

  /// Composes and submits ONE `addContextRule` call delegating scoped,
  /// spend-capped, time-bounded authority to the agent.
  ///
  /// - [agentPublicKey] is the agent's Stellar public key (G-address). It is
  ///   validated and converted to the raw 32-byte Ed25519 key the verifier
  ///   contract expects.
  /// - [tokenContract] is the single token the rule scopes to via
  ///   `CallContract`.
  /// - [amount] is the spending cap as a human decimal string, converted to
  ///   base units with [tokenDecimals].
  /// - [periodLedgers] is the spending-limit rolling window.
  /// - [validUntilOffsetLedgers] is the number of ledgers from now at which
  ///   the rule expires; resolved to an absolute ledger via the current
  ///   ledger. A value `<= 0` produces no expiry.
  ///
  /// Submitted via the connected passkey (single-signer path —
  /// `selectedSigners` empty). Returns a [DelegationResult]; on failure
  /// [DelegationResult.error] is sanitised and safe to display verbatim.
  Future<DelegationResult> delegateToAgent({
    required String agentPublicKey,
    required String tokenContract,
    required String amount,
    required int periodLedgers,
    required int validUntilOffsetLedgers,
    required int tokenDecimals,
    String ruleName = defaultDelegationRuleName,
  }) async {
    if (_isSubmitting) {
      throw StateError('A delegation is already in progress.');
    }
    _isSubmitting = true;
    try {
      final trimmedKey = agentPublicKey.trim();
      if (!StrKey.isValidStellarAccountId(trimmedKey)) {
        return const DelegationResult(
          success: false,
          error: 'Enter a valid Stellar agent public key (G...).',
        );
      }

      final Uint8List agentKeyBytes;
      try {
        agentKeyBytes =
            Uint8List.fromList(KeyPair.fromAccountId(trimmedKey).publicKey);
      } catch (_) {
        return const DelegationResult(
          success: false,
          error: 'Enter a valid Stellar agent public key (G...).',
        );
      }

      final trimmedToken = tokenContract.trim();

      // Convert the human cap to base units at the guarded-token scale.
      final BigInt baseUnits;
      try {
        baseUnits = OZTransactionOperations.amountToBaseUnits(
          amount,
          decimals: tokenDecimals,
        );
      } on SmartAccountValidationException catch (e) {
        final message = classifyError(e).message;
        _activityLog.error(message);
        return DelegationResult(success: false, error: message);
      }

      // Build the rule components. buildEd25519Signer validates the 32-byte
      // key length and stamps the configured verifier address;
      // buildCallContractContextType scopes the rule to the token contract.
      final OZSmartAccountSigner agentSigner;
      final OZContextRuleType contextType;
      try {
        agentSigner = _contextRuleFlow.buildEd25519Signer(agentKeyBytes);
        contextType =
            _contextRuleFlow.buildCallContractContextType(trimmedToken);
      } on SmartAccountValidationException catch (e) {
        final message = classifyError(e).message;
        _activityLog.error(message);
        return DelegationResult(success: false, error: message);
      }

      // Resolve the expiry offset to an absolute ledger from the current one.
      final int? validUntil;
      try {
        validUntil =
            await _contextRuleFlow.resolveAbsoluteLedger(validUntilOffsetLedgers);
      } catch (e) {
        final classified =
            classifyError(e, context: 'Failed to resolve the expiry ledger');
        _activityLog.error(classified.message);
        return DelegationResult(success: false, error: classified.message);
      }

      final policy = OZSpendingLimitPolicyParams(
        spendingLimit: baseUnits,
        periodLedgers: periodLedgers,
      );
      final policies = <FlowPolicyEntry>[
        FlowPolicyEntry(
          address: spendingLimitPolicyAddress,
          installParams: policy,
        ),
      ];

      _activityLog.info(
        'Delegating to agent ${truncateAddress(trimmedKey)} '
        'scoped to ${truncateAddress(trimmedToken)}...',
      );

      final ContextRuleResult result = await _contextRuleFlow.addContextRule(
        contextType: contextType,
        name: ruleName,
        validUntil: validUntil,
        signers: <OZSmartAccountSigner>[agentSigner],
        policies: policies,
      );

      if (!result.success) {
        return DelegationResult(
          success: false,
          error: result.error ?? 'Delegation failed.',
        );
      }

      return DelegationResult(
        success: true,
        hash: result.hash,
        summary: DelegationSummary(
          agentPublicKey: trimmedKey,
          tokenContract: trimmedToken,
          amount: amount,
          periodLedgers: periodLedgers,
          validUntilLedger: validUntil,
          ruleName: ruleName,
          spendingLimitPolicyAddress: spendingLimitPolicyAddress,
          verifierAddress:
              ed25519VerifierAddress ?? config.ed25519VerifierAddress,
        ),
      );
    } finally {
      _isSubmitting = false;
    }
  }
}
