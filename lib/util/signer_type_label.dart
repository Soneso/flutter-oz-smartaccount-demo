import '../flows/context_rule_builder_types.dart' show StagedSignerType;

/// Display labels for the OZ smart-account signer kinds.
abstract final class SignerTypeLabel {
  static const String passkeyLong = 'Passkey (WebAuthn)';
  static const String passkeyShort = 'Passkey';
  static const String gAddress = 'G-Address';
  static const String stellarAccount = 'Stellar Account';
  static const String ed25519 = 'Ed25519';
  static const String external = 'External';
}

/// Returns a display label for a [StagedSignerType].
///
/// Maps each [StagedSignerType] variant to a short user-facing string
/// appropriate for signer-weight rows and inline badges.
String labelForStagedSignerType(StagedSignerType type) {
  switch (type) {
    case StagedSignerType.delegated:
      return 'Delegated';
    case StagedSignerType.ed25519:
      return SignerTypeLabel.ed25519;
    case StagedSignerType.passkey:
      return SignerTypeLabel.passkeyShort;
  }
}
