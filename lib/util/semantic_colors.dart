/// Semantic color tokens for the demo app UI.
///
/// Provides a [cardBackground] extension on [ColorScheme] that resolves to
/// the appropriate Material 3 surface container token. Using a semantic token
/// instead of a hard-coded color ensures the value adapts correctly when the
/// system toggles between light and dark modes.
///
/// Activity-log level badge colors are fixed values. They are intentionally
/// not theme tokens because the badge palette must remain constant regardless
/// of light/dark mode. The [activityLogInfo], [activityLogOk], and
/// [activityLogErr] getters are placed on [ColorScheme] only to co-locate all
/// color decisions in one file; they do not adapt to the active theme.
library;

import 'package:flutter/material.dart';

import '../theme/spacing.dart';

// ---------------------------------------------------------------------------
// ThemeData extension
// ---------------------------------------------------------------------------

extension SemanticColors on ColorScheme {
  /// Background color for card-style surfaces rendered against a grouped-list
  /// or page backdrop.
  ///
  /// Resolves to [ColorScheme.surfaceContainer], the Material 3 token for
  /// non-interactive container surfaces that sit one elevation step above the
  /// page background. This matches the visual intent of
  /// [UIColor.secondarySystemGroupedBackground] on iOS without requiring any
  /// platform conditional.
  Color get cardBackground => surfaceContainer;

  /// Fixed blue used for INFO-level activity-log badges.
  ///
  /// Value: #2196F3.
  Color get activityLogInfo => const Color(0xFF2196F3);

  /// Fixed green used for OK-level (success) activity-log badges.
  ///
  /// Value: #4CAF50.
  Color get activityLogOk => const Color(0xFF4CAF50);

  /// Fixed red used for ERR-level (error) activity-log badges.
  ///
  /// Value: #F44336.
  Color get activityLogErr => const Color(0xFFF44336);

  /// Background color for warning-semantic containers (amber/yellow tint).
  ///
  /// Light mode: #FFF3CD (amber-100). Dark mode: #5C4400 (dark amber).
  /// These values match warning-semantic conventions and are intentionally
  /// fixed rather than seed-derived, since Material 3 tertiaryContainer can
  /// resolve to purple depending on the seed color.
  Color get warningContainer => brightness == Brightness.dark
      ? const Color(0xFF5C4400)
      : const Color(0xFFFFF3CD);

  /// Foreground color for text/icons on [warningContainer].
  ///
  /// Light mode: #856404 (dark amber). Dark mode: #FFE69C (light amber).
  Color get onWarningContainer => brightness == Brightness.dark
      ? const Color(0xFFFFE69C)
      : const Color(0xFF856404);

  // -------------------------------------------------------------------------
  // Context-rule badge tokens
  // -------------------------------------------------------------------------
  //
  // Each badge resolves to a (background, foreground) pair anchored on a
  // Material 3 container family. The values stay legible against the card
  // background in both brightness modes and provide WCAG AA contrast for the
  // small-label text the badges carry.

  /// Background colour for the signer-count badge on a context rule.
  ///
  /// Resolves to [ColorScheme.tertiaryContainer], the Material 3 token for
  /// accent/informational chips that sit on a card surface.
  Color get signerBadgeBackground => tertiaryContainer;

  /// Foreground colour (text and iconography) for the signer-count badge.
  Color get signerBadgeForeground => onTertiaryContainer;

  /// Background colour for the policy-count badge on a context rule.
  ///
  /// Resolves to [ColorScheme.secondaryContainer] to differentiate the
  /// policy chip from the signer chip while keeping both rooted in the
  /// scheme.
  Color get policyBadgeBackground => secondaryContainer;

  /// Foreground colour (text and iconography) for the policy-count badge.
  Color get policyBadgeForeground => onSecondaryContainer;

  /// Background colour for the expiry badge on a context rule.
  ///
  /// Reuses [warningContainer] so expiring rules read as a soft warning
  /// without competing with [Colors.error] for attention.
  Color get expiryBadgeBackground => warningContainer;

  /// Foreground colour (text and iconography) for the expiry badge.
  Color get expiryBadgeForeground => onWarningContainer;

  /// Background colour for the inline policy chip shown on the expanded
  /// detail view of a context rule.
  ///
  /// Uses [ColorScheme.primary] so the badge stands out against the muted
  /// chip row even in dark mode where the surface saturation is low.
  Color get policyChipBackground => primary;

  /// Foreground colour for text rendered on [policyChipBackground].
  Color get policyChipForeground => onPrimary;

  // -------------------------------------------------------------------------
  // Result and status tokens (edit-mode result card, badges)
  // -------------------------------------------------------------------------
  //
  // These tokens anchor success / partial / modified / on-chain semantics on
  // Material 3 container families so the foreground/background pairs hold
  // WCAG AA contrast in both brightness modes without hardcoded literals.

  /// Background colour for the full-success result card.
  ///
  /// Light mode: #D4EDDA (soft pastel green). Dark mode: #1B5E20 (Material
  /// green 900). Fixed rather than seed-derived so the success card reads
  /// as unambiguously green; Material 3 tertiaryContainer can resolve to
  /// pink / lavender depending on the seed colour.
  Color get successBackground => brightness == Brightness.dark
      ? const Color(0xFF1B5E20)
      : const Color(0xFFD4EDDA);

  /// Foreground colour (text and iconography) on [successBackground].
  ///
  /// Light mode: #155724 (dark green). Dark mode: #C8E6C9 (Material green
  /// 100). Paired with [successBackground] for WCAG AA contrast in both
  /// brightness modes.
  Color get successForeground => brightness == Brightness.dark
      ? const Color(0xFFC8E6C9)
      : const Color(0xFF155724);

  /// Background colour for the partial-success result card.
  ///
  /// Resolves to [ColorScheme.secondaryContainer]. The Material 3 secondary
  /// container family conveys an informational, in-progress meaning that
  /// reads as distinct from full success without competing with error
  /// surfaces.
  Color get partialBackground => secondaryContainer;

  /// Foreground colour (text and iconography) on [partialBackground].
  Color get partialForeground => onSecondaryContainer;

  /// Foreground colour (text) for the "on-chain" badge.
  Color get onChainBadgeForeground => signerBadgeForeground;

  /// Foreground colour (text) for the "modified" badge.
  Color get modifiedBadgeForeground => onWarningContainer;

  /// Subtle border colour drawn around error-tinted surfaces.
  ///
  /// Resolves to [ColorScheme.error] with [kErrorBorderAlpha] alpha so the
  /// outline reads as a warning without competing with the foreground text.
  Color get errorBorder => error.withAlpha(kErrorBorderAlpha);
}

// ---------------------------------------------------------------------------
// Signer-picker badge colors
// ---------------------------------------------------------------------------

/// Background colour for a "Verified" badge shown when a delegated or Ed25519
/// signer's secret key has been validated in the signer picker.
///
/// Value: #4CAF50 (Material green 500). Fixed rather than theme-derived so
/// the "verified" state reads as unambiguously green regardless of the active
/// Material seed colour.
const Color verifiedBadgeBackground = Color(0xFF4CAF50);

/// Background colour for a wallet-connected badge shown in the signer picker
/// when an external wallet session is active for a delegated signer.
///
/// Value: #1565C0 (Material blue 800). Fixed so the wallet badge is
/// consistently identifiable as a connected-state indicator across brightness
/// modes and seed colours.
const Color walletBadgeBackground = Color(0xFF1565C0);
