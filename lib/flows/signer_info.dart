/// Shared signer descriptor types used by the transfer, context-rule, and
/// approve flows, and by widgets that pick signers.
///
/// Kept in a standalone file so `transfer_flow.dart` and
/// `selected_signer_builder.dart` can both depend on these types without a
/// mutual import.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../util/format_utils.dart' show bytesToHex, truncateAddress, truncateCredentialId;

export 'ed25519_signer_identity.dart';

// ---------------------------------------------------------------------------
// SignerKind — categorization of signer types
// ---------------------------------------------------------------------------

/// Categorization of the signer represented by a [SignerInfo].
///
/// Determines the section the signer is rendered in within the signer picker
/// and the auth path used when the transaction is submitted.
enum SignerKind {
  /// WebAuthn passkey signer (an [OZExternalSigner] whose [keyData] contains
  /// a credential ID).
  passkey,

  /// Stellar account ("delegated") signer authorized by a G-address keypair.
  delegated,

  /// Ed25519 external signer (an [OZExternalSigner] without a WebAuthn
  /// credential ID).
  ed25519,
}

// ---------------------------------------------------------------------------
// SignerInfo — signer descriptor used by the transfer and context-rule flows
// ---------------------------------------------------------------------------

/// Describes a signer on the connected smart account, returned by
/// [TransferFlow.loadAvailableSigners] and
/// [ContextRuleFlow.loadAvailableSigners].
final class SignerInfo {
  /// Constructs a signer info record.
  const SignerInfo({
    required this.displayLabel,
    required this.address,
    required this.kind,
    required this.isConnectedCredential,
    this.credentialId,
    this.rawSigner,
  });

  /// Human-readable label (e.g. passkey credential ID snippet, G-address).
  final String displayLabel;

  /// Stellar address (G-address for delegated signers, empty otherwise).
  final String address;

  /// Category of this signer; controls how the picker groups and authorizes
  /// it.
  final SignerKind kind;

  /// True when this passkey matches the currently connected credential.
  ///
  /// Only meaningful when [kind] is [SignerKind.passkey].
  final bool isConnectedCredential;

  /// Base64URL credential ID for passkey signers, null for delegated and
  /// Ed25519 signers.
  final String? credentialId;

  /// The underlying SDK signer this entry was extracted from.
  ///
  /// Carries the on-chain `keyData` required by
  /// [OZMultiSignerManager.submitWithMultipleSigners] for rule resolution.
  /// May be null when the entry was constructed by a widget test that does
  /// not exercise multi-signer submission.
  final OZSmartAccountSigner? rawSigner;
}

// ---------------------------------------------------------------------------
// extractSignerInfos — deduplicated signer list from context rules
// ---------------------------------------------------------------------------

/// Extracts deduplicated [SignerInfo] entries from [rules].
///
/// Each [OZParsedContextRule]'s signers are inspected:
///
/// - [OZExternalSigner] with a WebAuthn credential ID in [keyData] →
///   [SignerKind.passkey]. The entry is flagged [SignerInfo.isConnectedCredential]
///   when its credential ID matches [connectedCredentialId].
/// - [OZExternalSigner] without a credential ID → [SignerKind.ed25519] with
///   a short hex preview of [keyData].
/// - [OZDelegatedSigner] → [SignerKind.delegated].
///
/// Signers with the same [OZSmartAccountSigner.uniqueKey] across multiple
/// rules are deduplicated — each unique signer appears once.
List<SignerInfo> extractSignerInfos(
  List<OZParsedContextRule> rules, {
  String? connectedCredentialId,
}) {
  final seen = <String>{};
  final signers = <SignerInfo>[];

  for (final rule in rules) {
    for (final signer in rule.signers) {
      final key = signer.uniqueKey;
      if (!seen.add(key)) continue;

      if (signer is OZExternalSigner) {
        final credentialId =
            OZSmartAccountBuilders.getCredentialIdStringFromSigner(signer);
        if (credentialId != null) {
          final isConnected = connectedCredentialId != null &&
              credentialId == connectedCredentialId;
          signers.add(SignerInfo(
            displayLabel: truncateCredentialId(credentialId),
            address: '',
            kind: SignerKind.passkey,
            isConnectedCredential: isConnected,
            credentialId: credentialId,
            rawSigner: signer,
          ));
        } else {
          // Ed25519 signers are identified by their public key, not the
          // verifier contract address. Show a short hex preview of keyData.
          final keyHex = bytesToHex(signer.keyData);
          final keyPreview =
              keyHex.length > 8 ? keyHex.substring(0, 8) : keyHex;
          signers.add(SignerInfo(
            displayLabel: 'key:$keyPreview...',
            address: signer.verifierAddress,
            kind: SignerKind.ed25519,
            isConnectedCredential: false,
            rawSigner: signer,
          ));
        }
      } else if (signer is OZDelegatedSigner) {
        final address = signer.address;
        signers.add(SignerInfo(
          displayLabel: truncateAddress(address),
          address: address,
          kind: SignerKind.delegated,
          isConnectedCredential: false,
          rawSigner: signer,
        ));
      }
    }
  }

  return signers;
}
