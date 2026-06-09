/// Signer management subsection for the Context Rule Builder screen.
///
/// Renders the signers header, the list of staged signers, and the
/// "Add Signer" chooser card that hosts the per-kind add form
/// (delegated, Ed25519, or passkey). The per-kind add forms each live in
/// their own file under `signer_add_forms/` and own their controllers
/// and per-form error state.
///
/// All mutable state visible to the parent screen is owned by the caller
/// and threaded in through callbacks. The widget never calls into the
/// Stellar SDK directly — it delegates discovery and registration to the
/// supplied callbacks, which in turn route through [ContextRuleFlow].
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../flows/context_rule_builder_types.dart';
import '../flows/context_rule_edit_types.dart';
import '../theme/spacing.dart';
import '../util/context_rule_format.dart';
import '../util/semantic_colors.dart';
import '../util/signer_colors.dart';
import '../util/signer_type_label.dart';
import 'field_error_text.dart';
import 'rich_dropdown_item.dart';
import 'signer_add_forms/delegated_add_form.dart';
import 'signer_add_forms/ed25519_add_form.dart';
import 'signer_add_forms/passkey_add_form.dart';
import 'signer_identity_chip.dart';

/// Add-form mode for the signer type dropdown.
enum SignerAddMode {
  /// Delegated Stellar account signer.
  delegated('Delegated (G-address)',
      'Stellar account using native require_auth verification'),

  /// Ed25519 external signer.
  ed25519('Ed25519 Public Key',
      'Ed25519 key verified by an external verifier contract'),

  /// Passkey (WebAuthn) external signer.
  passkey(SignerTypeLabel.passkeyLong,
      'Passkey verified by the WebAuthn verifier contract');

  const SignerAddMode(this.displayName, this.description);

  /// Display name shown in the dropdown.
  final String displayName;

  /// Short description shown below the dropdown entry.
  final String description;
}

// ---------------------------------------------------------------------------
// SignerManagementSection
// ---------------------------------------------------------------------------

/// Renders the signers section of the Context Rule Builder.
class SignerManagementSection extends StatefulWidget {
  /// Constructs a signer management section.
  const SignerManagementSection({
    required this.signers,
    required this.fieldError,
    required this.isSubmitting,
    required this.maxSigners,
    required this.ed25519VerifierAddress,
    required this.buildDelegatedSigner,
    required this.buildEd25519Signer,
    required this.onAddSigner,
    required this.onRemoveSigner,
    required this.loadPasskeySigners,
    required this.registerPasskeySigner,
    this.editEntries,
    this.connectedCredentialId,
    this.availableExistingPasskeys,
    super.key,
  });

  /// The current list of staged signers.
  ///
  /// In create-mode this list is the authoritative source for everything the
  /// section renders. In edit-mode (when [editEntries] is non-null) the
  /// section derives its own view from [editEntries] and ignores this list;
  /// the field is still required because [PolicyManagementSection] consumes
  /// it for the weighted-threshold form, but [SignerManagementSection] does
  /// not read it in edit mode.
  final List<StagedSigner> signers;

  /// Optional inline error for the signers section (banner above list).
  final String? fieldError;

  /// True while a submission is in flight; disables the add forms.
  final bool isSubmitting;

  /// Maximum number of signers permitted on a rule (OZ contract limit).
  final int maxSigners;

  /// Ed25519 verifier C-address; truncated and shown as helper text.
  final String? ed25519VerifierAddress;

  /// Builds an [OZSmartAccountSigner] for a delegated (Stellar G-address)
  /// signer from a validated address string. Routed through the flow so
  /// the widget never constructs SDK signer instances directly.
  final OZSmartAccountSigner Function(String address) buildDelegatedSigner;

  /// Builds an [OZSmartAccountSigner] for an Ed25519 external signer from
  /// a 32-byte public key. The flow supplies the verifier C-address from
  /// its environment; callers must guard against a null
  /// [ed25519VerifierAddress] before invoking, since the flow throws when
  /// the verifier is unavailable.
  final OZSmartAccountSigner Function(Uint8List publicKey) buildEd25519Signer;

  /// Called when the user successfully adds a new signer.
  ///
  /// Returns null on success or an error string when the signer cannot be
  /// added (e.g. duplicate / cap exceeded).
  final String? Function(StagedSigner signer) onAddSigner;

  /// Called when the user taps the remove (X) button for a signer.
  final void Function(StagedSigner signer) onRemoveSigner;

  /// Called when the user taps "Reuse Signer". The returned future
  /// resolves to the list of available passkey signers excluding the
  /// connected wallet's own credential.
  final Future<List<OZExternalSigner>> Function() loadPasskeySigners;

  /// Called when the user taps "Register New". The returned future
  /// resolves to a constructed WebAuthn [OZSmartAccountSigner] ready for
  /// staging.
  final Future<OZSmartAccountSigner> Function(String name)
      registerPasskeySigner;

  /// When non-null, the section renders in edit-mode using these entries
  /// instead of the create-mode [signers] list. The shape carries
  /// on-chain identity bookkeeping that drives the `(on-chain)` badge and
  /// the `You` label for the connected wallet's own passkey.
  ///
  /// Mutations are reported back via [onAddSigner] (for new entries) and
  /// [onRemoveSigner] (for removed entries). [signers] is still consumed
  /// by the weighted-threshold inner form regardless of mode, so callers
  /// should keep its contents synchronised with [editEntries] in edit
  /// mode.
  final List<EditSignerEntry>? editEntries;

  /// Connected wallet's Base64URL credential ID. Used in edit-mode to
  /// label the connected passkey's remove button as `You`. Ignored in
  /// create-mode.
  final String? connectedCredentialId;

  /// Pre-loaded existing-rule passkey signers shown in edit-mode's reuse
  /// section. When null, edit-mode falls back to the create-mode
  /// `Reuse Signer` button + lazy load. When non-null, the reuse buttons
  /// render immediately (no separate `Reuse Signer` trigger).
  final List<OZExternalSigner>? availableExistingPasskeys;

  @override
  State<SignerManagementSection> createState() =>
      _SignerManagementSectionState();
}

class _SignerManagementSectionState extends State<SignerManagementSection> {
  SignerAddMode _mode = SignerAddMode.delegated;

  bool get _isEditMode => widget.editEntries != null;

  /// Announces a signer removal to assistive technology.
  void _announceSignerRemoved() {
    SemanticsService.announce('Removed signer', Directionality.of(context));
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final editEntries = widget.editEntries;
    final atCap = _isEditMode
        ? (editEntries!.length >= widget.maxSigners)
        : (widget.signers.length >= widget.maxSigners);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SignersHeaderCard(
          colorScheme: colorScheme,
          textTheme: textTheme,
          maxSigners: widget.maxSigners,
          fieldError: widget.fieldError,
          isEditMode: _isEditMode,
        ),
        const SizedBox(height: 12),
        if (_isEditMode)
          _EditSignersList(
            entries: editEntries!,
            connectedCredentialId: widget.connectedCredentialId,
            colorScheme: colorScheme,
            textTheme: textTheme,
            isSubmitting: widget.isSubmitting,
            onRemove: _onRemoveEditEntry,
          )
        else
          _SignersList(
            signers: widget.signers,
            colorScheme: colorScheme,
            textTheme: textTheme,
            isSubmitting: widget.isSubmitting,
            onRemove: (signer) {
              widget.onRemoveSigner(signer);
              _announceSignerRemoved();
            },
          ),
        if (_isEditMode
            ? editEntries!.isNotEmpty
            : widget.signers.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            _isEditMode
                ? '${editEntries!.length} signer(s) configured'
                : '${widget.signers.length} signer(s) added',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (!widget.isSubmitting)
          _AddSignerCard(
            colorScheme: colorScheme,
            textTheme: textTheme,
            mode: _mode,
            atCap: atCap,
            onModeChanged: (m) {
              setState(() => _mode = m);
            },
            body: _buildModeBody(colorScheme, textTheme, atCap),
          ),
      ],
    );
  }

  /// In edit mode the remove button reports the entry to the caller via
  /// the staged-shape adapter so the screen can drop it from the edit
  /// entry list.
  void _onRemoveEditEntry(EditSignerEntry entry) {
    final adapted = StagedSigner(
      type: _stagedTypeFor(entry.signer),
      identifier: formatSignerForDisplay(entry.signer).displayValue,
      signer: entry.signer,
    );
    widget.onRemoveSigner(adapted);
    _announceSignerRemoved();
  }

  StagedSignerType _stagedTypeFor(OZSmartAccountSigner signer) {
    if (signer is OZDelegatedSigner) return StagedSignerType.delegated;
    if (signer is OZExternalSigner) {
      final credId = getCredentialIdStringFromSigner(signer);
      if (credId != null) return StagedSignerType.passkey;
      return StagedSignerType.ed25519;
    }
    return StagedSignerType.delegated;
  }

  Widget _buildModeBody(
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool atCap,
  ) {
    if (atCap) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Maximum ${widget.maxSigners} signers allowed',
          style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
        ),
      );
    }
    switch (_mode) {
      case SignerAddMode.delegated:
        return DelegatedAddForm(
          // Keyed by mode so the form's state resets on mode switch.
          key: const ValueKey<SignerAddMode>(SignerAddMode.delegated),
          isSubmitting: widget.isSubmitting,
          buildDelegatedSigner: widget.buildDelegatedSigner,
          onAddSigner: widget.onAddSigner,
        );
      case SignerAddMode.ed25519:
        return Ed25519AddForm(
          key: const ValueKey<SignerAddMode>(SignerAddMode.ed25519),
          isSubmitting: widget.isSubmitting,
          ed25519VerifierAddress: widget.ed25519VerifierAddress,
          buildEd25519Signer: widget.buildEd25519Signer,
          onAddSigner: widget.onAddSigner,
        );
      case SignerAddMode.passkey:
        return PasskeyAddForm(
          key: const ValueKey<SignerAddMode>(SignerAddMode.passkey),
          isSubmitting: widget.isSubmitting,
          loadPasskeySigners: widget.loadPasskeySigners,
          registerPasskeySigner: widget.registerPasskeySigner,
          isAlreadyAdded: _isPasskeyAlreadyAdded,
          onAddSigner: widget.onAddSigner,
          availableExistingPasskeys: widget.availableExistingPasskeys,
        );
    }
  }

  bool _isPasskeyAlreadyAdded(OZExternalSigner passkey) {
    final entries = widget.editEntries;
    if (entries != null) {
      for (final e in entries) {
        if (e.signer is OZExternalSigner && signersEqual(e.signer, passkey)) {
          return true;
        }
      }
      return false;
    }
    for (final s in widget.signers) {
      if (s.signer is OZExternalSigner && signersEqual(s.signer, passkey)) {
        return true;
      }
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _SignersHeaderCard extends StatelessWidget {
  const _SignersHeaderCard({
    required this.colorScheme,
    required this.textTheme,
    required this.maxSigners,
    required this.fieldError,
    this.isEditMode = false,
  });

  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final int maxSigners;
  final String? fieldError;
  final bool isEditMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Signers',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Add signers who can authorize operations matching this context. '
            'At least one signer is required. Maximum $maxSigners.',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (isEditMode) ...[
            const SizedBox(height: 6),
            Text(
              'Each signer change requires a separate passkey authentication.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
              ),
            ),
          ],
          FieldErrorText(error: fieldError),
        ],
      ),
    );
  }
}

class _SignersList extends StatelessWidget {
  const _SignersList({
    required this.signers,
    required this.colorScheme,
    required this.textTheme,
    required this.isSubmitting,
    required this.onRemove,
  });

  final List<StagedSigner> signers;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isSubmitting;
  final void Function(StagedSigner signer) onRemove;

  @override
  Widget build(BuildContext context) {
    if (signers.isEmpty) {
      return Container(
        width: double.infinity,
        padding: kCardPadding,
        decoration: BoxDecoration(
          color: colorScheme.cardBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Text(
          'No signers added yet. Add at least one signer below.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final s in signers) ...[
          _StagedSignerRow(
            signer: s,
            isSubmitting: isSubmitting,
            onRemove: () => onRemove(s),
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _StagedSignerRow extends StatelessWidget {
  const _StagedSignerRow({
    required this.signer,
    required this.isSubmitting,
    required this.onRemove,
  });

  final StagedSigner signer;
  final bool isSubmitting;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typeLabel = _typeLabelFor(signer.type);
    final chipColor = signerTypeColor(_signerTypeKeyFor(signer.type));

    // Combined chip + identifier description forms a single semantic node;
    // the remove button sits outside the chip so it stays independently
    // focusable.
    return Row(
      children: [
        Expanded(
          child: SignerIdentityChip(
            typeLabel: typeLabel,
            displayValue: signer.identifier,
            chipColor: chipColor,
          ),
        ),
        IconButton(
          tooltip: 'Remove signer',
          onPressed: isSubmitting ? null : onRemove,
          iconSize: 18,
          icon: Icon(Icons.close, color: colorScheme.error),
        ),
      ],
    );
  }

  String _typeLabelFor(StagedSignerType type) {
    switch (type) {
      case StagedSignerType.delegated:
        return 'Delegated';
      case StagedSignerType.ed25519:
        return SignerTypeLabel.ed25519;
      case StagedSignerType.passkey:
        return SignerTypeLabel.passkeyShort;
    }
  }

  String _signerTypeKeyFor(StagedSignerType type) {
    switch (type) {
      case StagedSignerType.delegated:
        return SignerTypeLabel.stellarAccount;
      case StagedSignerType.ed25519:
        return SignerTypeLabel.ed25519;
      case StagedSignerType.passkey:
        return SignerTypeLabel.passkeyLong;
    }
  }
}

class _AddSignerCard extends StatelessWidget {
  const _AddSignerCard({
    required this.colorScheme,
    required this.textTheme,
    required this.mode,
    required this.atCap,
    required this.onModeChanged,
    required this.body,
  });

  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final SignerAddMode mode;
  final bool atCap;
  final ValueChanged<SignerAddMode> onModeChanged;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.cardBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Add Signer',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<SignerAddMode>(
            initialValue: mode,
            itemHeight: null,
            decoration: const InputDecoration(
              labelText: 'Signer Type',
              border: OutlineInputBorder(),
            ),
            selectedItemBuilder: (_) => [
              for (final m in SignerAddMode.values)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(m.displayName),
                ),
            ],
            items: [
              for (final m in SignerAddMode.values)
                DropdownMenuItem<SignerAddMode>(
                  value: m,
                  child: Semantics(
                    label: '${m.displayName}. ${m.description}',
                    excludeSemantics: true,
                    child: RichDropdownItem(
                      title: m.displayName,
                      subtitle: m.description,
                    ),
                  ),
                ),
            ],
            onChanged: atCap
                ? null
                : (m) {
                    if (m != null) onModeChanged(m);
                  },
          ),
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _EditSignersList
// ---------------------------------------------------------------------------

class _EditSignersList extends StatelessWidget {
  const _EditSignersList({
    required this.entries,
    required this.connectedCredentialId,
    required this.colorScheme,
    required this.textTheme,
    required this.isSubmitting,
    required this.onRemove,
  });

  final List<EditSignerEntry> entries;
  final String? connectedCredentialId;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isSubmitting;
  final void Function(EditSignerEntry entry) onRemove;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        width: double.infinity,
        padding: kCardPadding,
        decoration: BoxDecoration(
          color: colorScheme.cardBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Text(
          'No signers added yet. Add at least one signer below.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final entry in entries) ...[
          _EditSignerRow(
            entry: entry,
            connectedCredentialId: connectedCredentialId,
            isSubmitting: isSubmitting,
            onRemove: () => onRemove(entry),
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _EditSignerRow extends StatelessWidget {
  const _EditSignerRow({
    required this.entry,
    required this.connectedCredentialId,
    required this.isSubmitting,
    required this.onRemove,
  });

  final EditSignerEntry entry;
  final String? connectedCredentialId;
  final bool isSubmitting;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final signer = entry.signer;
    final info = formatSignerForDisplay(signer);
    final chipColor = signerTypeColor(_signerKey(signer));

    final credentialId = signer is OZExternalSigner
        ? getCredentialIdStringFromSigner(signer)
        : null;
    final isConnected = credentialId != null &&
        connectedCredentialId != null &&
        credentialId == connectedCredentialId;

    // Build optional suffix parts for the semantics label.
    final semanticsSuffix = '${entry.isOriginal ? ', on-chain' : ''}'
        '${isConnected ? ', you' : ''}';

    // "(on-chain)" badge rendered inline with the identifier via Wrap.
    final Widget? inlineTrailing = entry.isOriginal
        ? Text(
            '(on-chain)',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onChainBadgeForeground,
              fontWeight: FontWeight.w600,
            ),
          )
        : null;

    // The chip and the trailing action (You label or remove button) are Row
    // siblings; the chip is independently focusable via its Semantics node.
    return Row(
      children: [
        Expanded(
          child: SignerIdentityChip(
            typeLabel: info.typeLabel,
            displayValue: info.displayValue,
            chipColor: chipColor,
            semanticsSuffix: semanticsSuffix.isNotEmpty ? semanticsSuffix : null,
            inlineTrailing: inlineTrailing,
          ),
        ),
        if (isConnected)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Semantics(
              label: 'You. Cannot remove your own connected passkey.',
              excludeSemantics: true,
              child: Text(
                'You',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          )
        else
          IconButton(
            tooltip: 'Remove signer',
            onPressed: isSubmitting ? null : onRemove,
            iconSize: 18,
            icon: Icon(Icons.close, color: colorScheme.error),
          ),
      ],
    );
  }

  String _signerKey(OZSmartAccountSigner signer) {
    if (signer is OZDelegatedSigner) return SignerTypeLabel.stellarAccount;
    if (signer is OZExternalSigner) {
      final credId = getCredentialIdStringFromSigner(signer);
      if (credId != null) return SignerTypeLabel.passkeyLong;
      return SignerTypeLabel.ed25519;
    }
    return 'Unknown';
  }
}
