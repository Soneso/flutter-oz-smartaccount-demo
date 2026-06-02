/// Color mapping for signer type labels in the UI.
library;

import 'package:flutter/material.dart';

import 'signer_type_label.dart';

/// Returns a display color for a signer based on its type label string.
///
/// The [signerType] string matches the values produced by the SDK's
/// signer-description utilities:
///   - "Passkey (WebAuthn)" → purple
///   - "Stellar Account"    → blue
///   - "Ed25519"            → teal
///   - anything else        → blue-grey (fallback)
Color signerTypeColor(String signerType) {
  return switch (signerType) {
    SignerTypeLabel.passkeyLong => const Color(0xFF9C27B0),
    SignerTypeLabel.stellarAccount => const Color(0xFF2196F3),
    SignerTypeLabel.ed25519 => const Color(0xFF009688),
    _ => const Color(0xFF607D8B),
  };
}

/// Returns the badge color for a signer's short display label.
///
/// Display labels emitted by the signer formatter ("Passkey", "G-Address",
/// "Ed25519", "External") differ from the longer keys used by
/// [signerTypeColor] ("Passkey (WebAuthn)", "Stellar Account", "Ed25519").
/// This helper bridges the two vocabularies so widgets can pass a display
/// label directly without translating it at the call site.
Color signerTypeColorForDisplayLabel(String displayLabel) {
  final canonical = switch (displayLabel) {
    SignerTypeLabel.passkeyShort => SignerTypeLabel.passkeyLong,
    SignerTypeLabel.gAddress => SignerTypeLabel.stellarAccount,
    SignerTypeLabel.ed25519 => SignerTypeLabel.ed25519,
    _ => displayLabel,
  };
  return signerTypeColor(canonical);
}
