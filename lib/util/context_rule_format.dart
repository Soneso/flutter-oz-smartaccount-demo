/// Formatting utilities for context-rule display labels.
///
/// Converts SDK types ([ContextRuleType], [OZSmartAccountSigner]) into the
/// short, user-visible strings shown in the Context Rules screen. None of
/// these functions perform network I/O or SDK calls.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'format_utils.dart';
import 'signer_type_label.dart';

// ---------------------------------------------------------------------------
// Context-type labels
// ---------------------------------------------------------------------------

/// Returns the user-visible label for a [ContextRuleType].
///
/// - Default              → "Default (Any Operation)"
/// - CallContract(addr)   → "Call Contract: ${truncated address}"
/// - CreateContract(hash) → "Create Contract: ${first 8 hex chars}..."
String formatContextType(ContextRuleType contextType) {
  if (contextType is ContextRuleTypeDefault) {
    return 'Default (Any Operation)';
  }
  if (contextType is ContextRuleTypeCallContract) {
    return 'Call Contract: ${truncateAddress(contextType.contractAddress)}';
  }
  if (contextType is ContextRuleTypeCreateContract) {
    final hexFull = bytesToHex(contextType.wasmHash);
    final preview = hexFull.length > 8 ? hexFull.substring(0, 8) : hexFull;
    return 'Create Contract: $preview...';
  }
  // Defensive fallback — new subtypes would land here.
  return 'Unknown';
}

// ---------------------------------------------------------------------------
// Signer labels
// ---------------------------------------------------------------------------

/// Describes how a signer is displayed in the context-rule detail view.
final class SignerDisplayInfo {
  /// Constructs a signer display info record.
  const SignerDisplayInfo({
    required this.typeLabel,
    required this.displayValue,
  });

  /// Short type badge, e.g. "Passkey", "G-Address", "Ed25519", "External".
  final String typeLabel;

  /// Truncated identifier, e.g. credential-ID snippet or address snippet.
  final String displayValue;
}

/// Returns the display label and short identifier for [signer].
///
/// - [OZDelegatedSigner] with G-address → type "G-Address", `truncateAddress(6)`
/// - [OZExternalSigner] (WebAuthn)      → type "Passkey",   credential-ID snippet
/// - [OZExternalSigner] (Ed25519, 32 B) → type "Ed25519",   `key:${hex.take(8)}...`
/// - [OZExternalSigner] (other/fallback)→ type "External",  `truncateAddress(4)`
SignerDisplayInfo formatSignerForDisplay(OZSmartAccountSigner signer) {
  if (signer is OZDelegatedSigner) {
    final addr = signer.address;
    return SignerDisplayInfo(
      typeLabel: SignerTypeLabel.gAddress,
      displayValue: truncateAddress(addr, chars: 6),
    );
  }

  if (signer is OZExternalSigner) {
    // WebAuthn signers carry a 65-byte uncompressed secp256r1 public key
    // followed by the credential ID. The SDK helper returns the Base64URL
    // credential-ID string for WebAuthn signers and null for any other
    // external-signer shape, so it is the single source of truth for the
    // WebAuthn detection branch.
    final credentialId =
        OZSmartAccountBuilders.getCredentialIdStringFromSigner(signer);
    if (credentialId != null) {
      return SignerDisplayInfo(
        typeLabel: SignerTypeLabel.passkeyShort,
        displayValue: truncateCredentialId(credentialId),
      );
    }

    // Ed25519 signers carry a 32-byte public key.
    const ed25519PubKeyLen = 32;
    if (signer.keyData.length == ed25519PubKeyLen) {
      final hex = bytesToHex(signer.keyData);
      final preview = hex.length > 8 ? hex.substring(0, 8) : hex;
      return SignerDisplayInfo(
        typeLabel: SignerTypeLabel.ed25519,
        displayValue: 'key:$preview...',
      );
    }

    // Fallback: unknown external signer.
    return SignerDisplayInfo(
      typeLabel: SignerTypeLabel.external,
      displayValue: truncateAddress(signer.verifierAddress, chars: 4),
    );
  }

  // Defensive fallback for sealed hierarchy changes.
  return const SignerDisplayInfo(
    typeLabel: 'Unknown',
    displayValue: '—',
  );
}

// ---------------------------------------------------------------------------
// Signer / policy count badges
// ---------------------------------------------------------------------------

/// Returns the pluralised signer badge label, e.g. "2 signers" / "1 signer".
String signerCountLabel(int count) =>
    '$count signer${count != 1 ? 's' : ''}';

/// Returns the pluralised policy badge label, e.g. "2 policies" / "1 policy".
String policyCountLabel(int count) =>
    '$count polic${count != 1 ? 'ies' : 'y'}';
