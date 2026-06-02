/// Plain-data types used by the Context Rule Builder screen and its flow.
///
/// These types are produced and consumed at the screen / widget layer when
/// staging a context rule before submission. They are intentionally
/// SDK-free so the screen layer never has to construct or hold raw SDK
/// values directly.
///
/// - [StagedSigner]: a single signer the user has added in the builder.
///   The flow converts the wrapped [signer] into an SCVal at submit time.
/// - [StagedPolicy]: a single policy the user has attached in the builder.
///   The [scVal] is computed at add-time and passed through verbatim when
///   the rule is submitted.
/// - [FlowPolicyEntry]: the (address, scVal) tuple the flow layer accepts
///   when building the context-rule install call.
///
/// The file also re-exports the SDK signer / selected-signer / SCVal types
/// the builder UI needs as typedefs so the screen and widget layers can
/// import this single file instead of pulling in the full Stellar SDK
/// surface. This keeps the SDK-import boundary at the flow layer.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' as sdk;

import '../config/demo_config.dart' show PolicyInfo;

// ---------------------------------------------------------------------------
// SDK type re-exports
// ---------------------------------------------------------------------------

/// Re-export of the SDK context-type hierarchy root so the builder screen
/// can hold and pass around ContextRuleType instances returned from flow
/// builder methods without importing `package:stellar_flutter_sdk`.
typedef ContextRuleType = sdk.ContextRuleType;

/// Re-export of the `Default` context-type variant.
typedef ContextRuleTypeDefault = sdk.ContextRuleTypeDefault;

/// Re-export of the `CallContract` context-type variant. Used in edit-mode
/// to pre-populate the contract field from a loaded rule.
typedef ContextRuleTypeCallContract = sdk.ContextRuleTypeCallContract;

/// Re-export of the `CreateContract` context-type variant. Used in
/// edit-mode to pre-populate the WASM hash field from a loaded rule.
typedef ContextRuleTypeCreateContract = sdk.ContextRuleTypeCreateContract;

/// Re-export of the [ParsedContextRule] shape returned by the SDK's
/// context-rule manager. Held on the builder screen during edit-mode to
/// drive form pre-population.
typedef ParsedContextRule = sdk.ParsedContextRule;

/// Re-export of the SDK signer hierarchy root so widgets / screens can hold
/// staged signers without importing `package:stellar_flutter_sdk`.
typedef OZSmartAccountSigner = sdk.OZSmartAccountSigner;

/// Re-export of the delegated (G-address) signer constructor type.
typedef OZDelegatedSigner = sdk.OZDelegatedSigner;

/// Re-export of the external signer type used for both Ed25519 and
/// WebAuthn signers in the builder.
typedef OZExternalSigner = sdk.OZExternalSigner;

/// Re-export of the abstract selected-signer marker used by multi-signer
/// pickers.
typedef SelectedSigner = sdk.SelectedSigner;

/// Re-export of the passkey selected-signer variant.
typedef SelectedSignerPasskey = sdk.SelectedSignerPasskey;

/// Re-export of the wallet (G-address) selected-signer variant.
typedef SelectedSignerWallet = sdk.SelectedSignerWallet;

/// Re-export of the Soroban SCVal type used as the encoded policy
/// install-parameter payload. Widgets pass this type through verbatim
/// after computing it via the policy SCVal builders.
typedef XdrSCVal = sdk.XdrSCVal;

/// Re-export of the WebAuthn cancellation marker exception raised by the
/// passkey provider when the user dismisses the platform prompt. Widgets
/// catch this to distinguish a user cancellation from a real failure.
typedef WebAuthnCancelled = sdk.WebAuthnCancelled;

/// Re-export of the SDK credential storage record. Used by the wallet
/// connection screen to type its pending-credential list without importing
/// the full SDK surface.
typedef StoredCredential = sdk.StoredCredential;

// ---------------------------------------------------------------------------
// Builder-layer constants and helpers
// ---------------------------------------------------------------------------

/// Static constants and helpers consumed by the builder UI. Exposing
/// these here lets widget code avoid a direct dependency on the SDK's
/// `OZConstants` / `OZSmartAccountBuilders` symbols.
abstract final class ContextRuleBuilderLimits {
  /// Maximum number of signers permitted on a single context rule.
  static const int maxSigners = sdk.OZConstants.maxSigners;

  /// Maximum number of policies permitted on a single context rule.
  static const int maxPolicies = sdk.OZConstants.maxPolicies;

  /// Maximum number of bytes allowed for a context rule name.
  ///
  /// Enforced on-chain by the OpenZeppelin smart-account contract via
  /// `SmartAccountError::NameTooLong` (error code 3015). Hardcoded here
  /// because the SDK's [sdk.OZConstants] does not expose this value;
  /// without client-side validation the user would only learn of the
  /// rejection after completing the passkey ceremony and triggering a
  /// simulation, which is poor UX.
  static const int maxRuleNameBytes = 20;
}

/// Returns true when [a] and [b] denote the same on-chain signer identity.
///
/// Wraps the SDK comparator so widgets that need a duplicate-detection
/// check do not need to import `OZSmartAccountBuilders` directly.
bool signersEqual(OZSmartAccountSigner a, OZSmartAccountSigner b) =>
    sdk.OZSmartAccountBuilders.signersEqual(a, b);

/// Returns the Base64URL credential ID string for a WebAuthn-backed signer,
/// or null when [signer] is not a WebAuthn external signer.
///
/// Wraps the SDK helper for the same import-boundary reason as
/// [signersEqual].
String? getCredentialIdStringFromSigner(OZSmartAccountSigner signer) =>
    sdk.OZSmartAccountBuilders.getCredentialIdStringFromSigner(signer);

/// Returns the canonical uniqueness key for a signer.
String getSignerKey(OZSmartAccountSigner signer) =>
    sdk.OZSmartAccountBuilders.getSignerKey(signer);

// ---------------------------------------------------------------------------
// Staged signer
// ---------------------------------------------------------------------------

/// Identifies how a staged signer was added in the builder.
enum StagedSignerType {
  /// Delegated (Stellar G-address) signer.
  delegated,

  /// Ed25519 external signer.
  ed25519,

  /// Passkey (WebAuthn) external signer.
  passkey,
}

/// A signer added to the in-progress context rule.
///
/// [type] drives the type-badge colour and label.
/// [identifier] is the short display string (truncated address or
/// credential-ID snippet).
/// [signer] is the underlying SDK signer that gets passed to
/// `addContextRule` at submit time.
final class StagedSigner {
  /// Constructs a staged signer record.
  const StagedSigner({
    required this.type,
    required this.identifier,
    required this.signer,
  });

  /// The signer type as the user added it.
  final StagedSignerType type;

  /// Short display identifier for badges and remove rows.
  final String identifier;

  /// The underlying SDK signer.
  final OZSmartAccountSigner signer;

  /// Unique key for deduplication checks.
  String get uniqueKey => signer.uniqueKey;
}

// ---------------------------------------------------------------------------
// Staged policy
// ---------------------------------------------------------------------------

/// A policy attached to the in-progress context rule.
///
/// [info] is the canonical metadata (name, type, contract address).
/// [label] is the human-readable summary shown on the policy card.
/// [scVal] is the encoded install parameters, computed at add-time.
final class StagedPolicy {
  /// Constructs a staged policy record.
  const StagedPolicy({
    required this.info,
    required this.label,
    required this.scVal,
  });

  /// Policy metadata (type, name, contract address).
  final PolicyInfo info;

  /// Short human-readable description of the configured policy.
  final String label;

  /// Install parameters encoded as an SCVal map.
  final XdrSCVal scVal;

  /// Policy contract address shortcut.
  String get address => info.address;
}

// ---------------------------------------------------------------------------
// Flow policy entry
// ---------------------------------------------------------------------------

/// (address, SCVal) tuple consumed by
/// [ContextRuleFlow.addContextRule]. Mirrors the OZ SDK map shape using a
/// list so the flow can preserve the user's add-order before the
/// underlying manager sorts entries deterministically for hashing.
final class FlowPolicyEntry {
  /// Constructs a flow policy entry.
  const FlowPolicyEntry({
    required this.address,
    required this.scVal,
  });

  /// Policy contract C-address.
  final String address;

  /// Install parameters encoded as an SCVal map. Null entries are
  /// rejected by [ContextRuleFlow.addContextRule].
  final XdrSCVal? scVal;
}

// ---------------------------------------------------------------------------
// Add context rule result
// ---------------------------------------------------------------------------

/// Outcome of an [ContextRuleFlow.addContextRule] call.
///
/// [success] indicates whether the on-chain transaction was confirmed.
/// [hash] is populated when [success] is true.
/// [error] carries a sanitised user-facing message when [success] is false.
final class ContextRuleResult {
  /// Constructs a context-rule submission result.
  const ContextRuleResult({
    required this.success,
    this.hash,
    this.error,
  });

  /// True on confirmed on-chain submission.
  final bool success;

  /// On-chain transaction hash on success.
  final String? hash;

  /// Sanitised error message on failure.
  final String? error;
}
