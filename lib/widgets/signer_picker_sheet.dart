/// Bottom sheet for selecting signers in a multi-signer operation.
///
/// Displays the list of available signers grouped by kind (passkey, Stellar
/// account, Ed25519), lets the user toggle each signer on or off, and
/// authorizes delegated (Stellar account) signers either by entering a secret
/// key directly or by connecting an external wallet via the optional
/// [walletConnector]. Ed25519 signers are authorized by entering a matching
/// secret key; the raw seed bytes are collected locally and passed to
/// [onConfirm] for the caller to register before submission.
///
/// Accessibility:
/// - Section headers use [Semantics(header: true)].
/// - Inline errors use [Semantics(liveRegion: true, enabled: ...)].
/// - Secret key fields use the password obscure toggle.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../flows/signer_info.dart' show Ed25519SignerIdentity, SignerInfo, SignerKind;
import '../util/selected_signer_builder.dart' show SelectedSignerBuilder;
import '../util/semantic_colors.dart';
import '../util/signer_type_label.dart';
import '../wallet/wallet_connector.dart';
import 'button_label.dart';
import 'inline_error_banner.dart';
import 'loading_label.dart';
import 'pill.dart';
import 'sheet_header.dart';

// ---------------------------------------------------------------------------
// defaultWalletConnectLabel
// ---------------------------------------------------------------------------

/// Wallet-connect button label appropriate for the current platform.
///
/// Web targets a single browser extension (Freighter) so the label can be
/// concrete. Native targets a wide set of WalletConnect-compatible wallets
/// chosen at deep-link time, so the label stays generic.
const String defaultWalletConnectLabel =
    kIsWeb ? 'Connect Freighter' : 'Connect Wallet';

/// Strips the leading "Connect " verb from [walletConnectLabel] so the
/// remaining noun can be used as a chip / status label. Falls back to
/// "Wallet" when the label does not follow the "Connect X" convention.
String _walletShortLabel(String walletConnectLabel) {
  const prefix = 'Connect ';
  if (walletConnectLabel.startsWith(prefix)) {
    return walletConnectLabel.substring(prefix.length);
  }
  return 'Wallet';
}

// ---------------------------------------------------------------------------
// Delegated signer auth state
// ---------------------------------------------------------------------------

/// Authorization state for a single delegated signer row.
enum _DelegatedAuthStatus {
  /// No authorization yet. Row toggle disabled. Buttons visible to either
  /// enter a secret key or connect an external wallet.
  none,

  /// Inline secret-key form is currently visible.
  enteringKey,

  /// A secret key has been entered and validated against the row address.
  /// Row toggle enabled. A "Clear key" affordance reverts to [none].
  keypairVerified,

  /// The user requested a wallet connection and we are awaiting the wallet
  /// handshake. Other rows' Connect buttons are disabled while in this state
  /// (single-wallet invariant).
  walletConnecting,

  /// The external wallet successfully connected and matches this row's
  /// address. Row toggle enabled. A "Disconnect" affordance reverts to
  /// [none].
  walletConnected,

  /// A previous wallet-connect attempt failed. The row renders as [none]
  /// with the error caption visible underneath.
  walletError,
}

/// Mutable per-row state for a single delegated signer row.
///
/// One instance per delegated signer is owned by the corresponding
/// [_DelegatedSignerRow] state. The parent [SignerPickerSheet] never reaches
/// into these fields; it only learns about row transitions via the callbacks
/// the row widget invokes.
class _DelegatedRowState {
  /// Current authorization status driving which controls and badges the row
  /// renders.
  _DelegatedAuthStatus status = _DelegatedAuthStatus.none;

  /// Last wallet-connect error string. Only consulted while [status] is
  /// [_DelegatedAuthStatus.walletError].
  String? error;

  /// Verified secret seed entered via the inline form. Populated only while
  /// [status] is [_DelegatedAuthStatus.keypairVerified] and cleared otherwise.
  String? verifiedSecret;

  /// Whether the secret-key form is rendering the input as obscured text.
  bool obscured = true;

  /// Validation error text rendered inside the secret-key form.
  String? secretError;

  /// Whether a verify request is in-flight. Disables the form's controls
  /// while true.
  bool validating = false;

  /// Controller backing the secret-key [TextField]. Owned by the row state
  /// and disposed in [dispose].
  final TextEditingController controller = TextEditingController();

  /// Releases the [controller]. Must be invoked exactly once when the
  /// owning widget is torn down.
  void dispose() => controller.dispose();
}

// ---------------------------------------------------------------------------
// Ed25519 signer auth state
// ---------------------------------------------------------------------------

/// Authorization state for a single Ed25519 signer row.
enum _Ed25519AuthStatus {
  /// No secret verified yet. Row toggle disabled. "Enter Key" button visible.
  none,

  /// The inline secret-key form is currently visible.
  enteringKey,

  /// A secret key has been entered and verified against the signer's public
  /// key. The raw seed is held in the picker's local cache. Row toggle
  /// enabled. A "Clear key" affordance reverts to [none].
  verified,
}

/// Mutable per-row state for a single Ed25519 signer row.
///
/// One instance per Ed25519 signer is owned by the corresponding
/// [_Ed25519SignerRow] state. The parent [SignerPickerSheet] learns about row
/// transitions via the callbacks the row widget invokes.
class _Ed25519RowState {
  _Ed25519AuthStatus status = _Ed25519AuthStatus.none;

  /// Validation error rendered inside the secret-key form.
  String? secretError;

  /// Whether the secret-key form is rendering the input as obscured text.
  bool obscured = true;

  /// Whether a verify request is in-flight.
  bool validating = false;

  /// Controller backing the secret-key [TextField]. Owned by the row state
  /// and disposed in [dispose].
  final TextEditingController controller = TextEditingController();

  /// Releases the [controller]. Must be invoked exactly once when the owning
  /// widget is torn down.
  void dispose() => controller.dispose();
}

// ---------------------------------------------------------------------------
// SignerPickerSheet
// ---------------------------------------------------------------------------

/// Modal bottom sheet that lets the user pick which signers will co-authorize
/// an operation. Delegated signers may be authorized either by entering a
/// secret key (held in memory only for this signing session) or by connecting
/// an external wallet via the optional [walletConnector]. Ed25519 signers are
/// authorized by entering a matching secret key whose derived public key is
/// verified against the on-chain signer; the raw seed bytes are held in a
/// picker-local cache until the user confirms.
///
/// [availableSigners] is the list of signers returned by
/// [TransferFlow.loadAvailableSigners]. The sheet begins with only the
/// active passkey selected (if present); all other rows start unchecked.
///
/// [onConfirm] is called with the list of selected [SignerInfo] entries,
/// a map of address-to-secret-seed-string for selected delegated signers
/// authorized via secret key, and a map of [Ed25519SignerIdentity]-to-raw-seed
/// for selected Ed25519 signers whose secret was entered in this session.
/// Wallet-authorized delegated signers are represented in [selectedSigners]
/// but never appear in [delegatedKeyPairs]. Ed25519 registration is the
/// caller's responsibility (see [onConfirm]).
///
/// [onCancel] is called when the user taps "Cancel", the close icon, or
/// otherwise dismisses the sheet without confirming. When dismissed without
/// a successful confirm the sheet best-effort calls
/// [WalletConnector.disconnect] on [walletConnector] to release any open
/// session.
class SignerPickerSheet extends StatefulWidget {
  /// Creates a [SignerPickerSheet].
  const SignerPickerSheet({
    required this.availableSigners,
    required this.connectedCredentialId,
    required this.onConfirm,
    required this.onCancel,
    required this.validateDelegatedSecret,
    required this.validateEd25519Secret,
    this.walletConnector,
    this.walletConnectLabel = defaultWalletConnectLabel,
    this.ed25519SigningEnabled = false,
    this.title = 'Select Signers',
    this.description =
        'Choose which signers co-authorize this operation. '
        'For Stellar account signers, enter the secret key to enable signing.',
    this.confirmLabel = 'Confirm',
    super.key,
  });

  /// The signers available for selection, from context-rule discovery.
  final List<SignerInfo> availableSigners;

  /// The credential ID of the connected passkey. The matching passkey row is
  /// preselected and shown with an "Active" badge. May be null when no
  /// passkey is currently connected.
  final String? connectedCredentialId;

  /// Called when the user confirms their selection.
  ///
  /// [selectedSigners] is the subset of [availableSigners] the user selected.
  /// [delegatedKeyPairs] maps G-address to secret seed string for each
  /// selected delegated signer that was authorized via secret-key entry.
  /// Wallet-authorized delegated signers are absent from this map; the
  /// kit's external wallet adapter routes their signing automatically when
  /// the transaction submits.
  /// [ed25519Secrets] maps [Ed25519SignerIdentity] to raw 32-byte seed bytes
  /// for each selected Ed25519 signer that was verified in this picker session.
  /// The caller must register these via [TransferFlow.registerEd25519Keypairs]
  /// (or the equivalent) before the multi-signer submission.
  final void Function(
    List<SignerInfo> selectedSigners,
    Map<String, String> delegatedKeyPairs,
    Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
  ) onConfirm;

  /// Called when the user dismisses the sheet without confirming (Cancel,
  /// close icon, outside-tap, route pop).
  final VoidCallback onCancel;

  /// Validates a delegated signer secret seed against its on-chain address.
  ///
  /// Returns null when the seed is valid and matches [address], or an error
  /// string describing the failure. Delegated to the calling flow so the
  /// widget does not import the Stellar SDK directly.
  final String? Function(String address, String seed) validateDelegatedSecret;

  /// Validates a hex-encoded Ed25519 secret seed against [expectedPublicKey].
  ///
  /// Delegated to the calling flow so the widget does not import the Stellar
  /// SDK directly. Returns a record with [rawSeed] on success and [error] on
  /// failure.
  final Ed25519SecretValidator validateEd25519Secret;

  /// Optional wallet connector used for external-wallet authorization of
  /// delegated signers. When null the "Connect" button is hidden on every
  /// delegated row and rows can only be authorized via secret-key entry.
  final WalletConnector? walletConnector;

  /// Label displayed on the wallet-connect button. Defaults to
  /// "Connect Freighter"; callers may pass a different label per platform
  /// (e.g. "Connect Wallet").
  final String walletConnectLabel;

  /// Whether Ed25519 signing is enabled for this picker session.
  ///
  /// When true, Ed25519 rows display an "Enter Key" button and the picker
  /// collects verified raw seeds for [onConfirm]. When false, Ed25519 rows
  /// are rendered as a plain selectable row without key entry.
  final bool ed25519SigningEnabled;

  /// Header title shown at the top of the sheet.
  ///
  /// Defaults to "Select Signers".
  final String title;

  /// Descriptive text shown below the title.
  ///
  /// Callers may override to match the operation context, e.g. removal vs
  /// transfer.
  final String description;

  /// Verb prefix shown on the confirm button. The final button label is
  /// `"$confirmLabel ($selectedCount selected)"` and the button is disabled
  /// when no signers are selected.
  ///
  /// Defaults to "Confirm".
  final String confirmLabel;

  /// Shows the [SignerPickerSheet] as a modal bottom sheet.
  ///
  /// Returns when the sheet is dismissed (either by confirmation or
  /// cancellation). Callers may override [title], [description], and
  /// [confirmLabel] to match the operation context.
  ///
  /// [ed25519SigningEnabled] controls whether Ed25519 rows display an "Enter
  /// Key" button and collect verified secrets for [onConfirm].
  static Future<void> show({
    required BuildContext context,
    required List<SignerInfo> availableSigners,
    required String? connectedCredentialId,
    required String? Function(String address, String seed) validateDelegatedSecret,
    required Ed25519SecretValidator validateEd25519Secret,
    required void Function(
      List<SignerInfo> selectedSigners,
      Map<String, String> delegatedKeyPairs,
      Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
    ) onConfirm,
    WalletConnector? walletConnector,
    String walletConnectLabel = defaultWalletConnectLabel,
    bool ed25519SigningEnabled = false,
    String title = 'Select Signers',
    String description =
        'Choose which signers co-authorize this operation. '
        'For Stellar account signers, enter the secret key to enable signing.',
    String confirmLabel = 'Confirm',
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SignerPickerSheet(
        availableSigners: availableSigners,
        connectedCredentialId: connectedCredentialId,
        onConfirm: onConfirm,
        onCancel: () => Navigator.of(context).pop(),
        validateDelegatedSecret: validateDelegatedSecret,
        validateEd25519Secret: validateEd25519Secret,
        walletConnector: walletConnector,
        walletConnectLabel: walletConnectLabel,
        ed25519SigningEnabled: ed25519SigningEnabled,
        title: title,
        description: description,
        confirmLabel: confirmLabel,
      ),
    );
  }

  @override
  State<SignerPickerSheet> createState() => _SignerPickerSheetState();
}

class _SignerPickerSheetState extends State<SignerPickerSheet> {
  /// Per-index selection flag for every signer. Indices align with
  /// [SignerPickerSheet.availableSigners].
  late final List<bool> _selected;

  /// Verified secret seeds keyed by delegated signer address. Populated as
  /// rows report a successful secret-key verification via the row's
  /// `onChanged` callback. Used at confirm time to assemble the
  /// `delegatedKeyPairs` map passed to the caller.
  final Map<String, String> _verifiedSecrets = {};

  /// Verified raw seed bytes keyed by Ed25519 signer identity. Populated as
  /// Ed25519 rows report a successful secret-key verification. Used at confirm
  /// time to assemble the `ed25519Secrets` map passed to [onConfirm]; the
  /// caller registers them (see [onConfirm]).
  final Map<Ed25519SignerIdentity, Uint8List> _verifiedEd25519Secrets = {};

  /// Address of the delegated signer that currently holds (or is acquiring)
  /// the wallet session, or null when no wallet is active. Maintained by
  /// the delegated rows via [_onRowWalletActivityChanged] and consulted to
  /// enforce the single-wallet invariant.
  String? _activeWalletAddress;

  /// Validation error displayed above the confirm/cancel buttons.
  String? _validationError;

  /// True when [onConfirm] has fired and the sheet is closing as a success.
  /// Suppresses the dismiss-time wallet disconnect.
  bool _confirmed = false;

  @override
  void initState() {
    super.initState();
    _selected = List<bool>.filled(widget.availableSigners.length, false);

    final activeCredentialId = widget.connectedCredentialId;
    for (var i = 0; i < widget.availableSigners.length; i++) {
      final s = widget.availableSigners[i];
      // Preselect the active passkey, identified by a credential-id match
      // against the connected credential.
      if (s.kind == SignerKind.passkey &&
          activeCredentialId != null &&
          s.credentialId != null &&
          s.credentialId == activeCredentialId) {
        _selected[i] = true;
      }
    }
  }

  @override
  void dispose() {
    _verifiedSecrets.clear();
    _verifiedEd25519Secrets.clear();
    // Best-effort wallet cleanup when the route is being torn down without a
    // confirm (cancel, X, outside-tap, system back). When [_confirmed] is true
    // the caller's submission still needs the active wallet session, so we
    // skip the disconnect. No adapter interaction occurs here — the picker
    // never registered keypairs into the adapter.
    if (!_confirmed) {
      _bestEffortDisconnect();
    }
    super.dispose();
  }

  /// Fires a best-effort `disconnect()` on the injected connector and ignores
  /// any failure. Safe to call at any lifecycle point.
  void _bestEffortDisconnect() {
    final connector = widget.walletConnector;
    if (connector == null) return;
    if (_activeWalletAddress == null) return;
    // Fire-and-forget; route teardown does not await futures.
    connector.disconnect().catchError((_) {});
  }

  // -------------------------------------------------------------------------
  // Row callbacks
  // -------------------------------------------------------------------------

  /// Called by a delegated row whenever its selection or verified-secret
  /// material changes. The row is responsible for its own visual state; the
  /// parent only mirrors the selection bit and the verified seed (consumed
  /// at confirm time).
  void _onDelegatedRowChanged(
    int index,
    SignerInfo signer,
    bool selected,
    String? verifiedSecret,
  ) {
    setState(() {
      _selected[index] = selected;
      if (verifiedSecret != null) {
        _verifiedSecrets[signer.address] = verifiedSecret;
      } else {
        _verifiedSecrets.remove(signer.address);
      }
      _validationError = null;
    });
  }

  /// Called by a delegated row when it enters or leaves a state that holds
  /// the wallet session (connecting or connected). The sheet enforces a
  /// single-wallet invariant by tracking which row (if any) currently owns
  /// the session and refusing to start a connect on any other row while one
  /// is active.
  void _onRowWalletActivityChanged(SignerInfo signer, bool active) {
    setState(() {
      if (active) {
        _activeWalletAddress = signer.address;
      } else if (_activeWalletAddress == signer.address) {
        _activeWalletAddress = null;
      }
    });
  }

  /// Called by an Ed25519 row when its selection or verified-secret material
  /// changes. [selected] reflects the row's current checkbox state.
  /// [identity] and [rawSeed] are non-null when the row transitions into the
  /// verified state, and null when the verified secret is cleared.
  void _onEd25519RowChanged(
    int index,
    Ed25519SignerIdentity identity,
    Uint8List? rawSeed,
    bool selected,
  ) {
    setState(() {
      _selected[index] = selected;
      if (rawSeed != null) {
        _verifiedEd25519Secrets[identity] = rawSeed;
      } else {
        _verifiedEd25519Secrets.remove(identity);
      }
      _validationError = null;
    });
  }

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  bool _validateBeforeConfirm() {
    if (!_selected.any((v) => v)) {
      setState(() {
        _validationError = 'At least one signer must be selected.';
      });
      return false;
    }
    setState(() => _validationError = null);
    return true;
  }

  // -------------------------------------------------------------------------
  // Confirm / cancel
  // -------------------------------------------------------------------------

  void _onConfirm() {
    if (!_validateBeforeConfirm()) return;

    final selectedSigners = <SignerInfo>[];
    final delegatedKeyPairs = <String, String>{};
    final ed25519Secrets = <Ed25519SignerIdentity, Uint8List>{};

    for (var i = 0; i < widget.availableSigners.length; i++) {
      if (!_selected[i]) continue;
      final signer = widget.availableSigners[i];
      selectedSigners.add(signer);

      if (signer.kind == SignerKind.delegated) {
        final secret = _verifiedSecrets[signer.address];
        if (secret != null) {
          // Secret-key authorized — pass the seed through to the caller.
          delegatedKeyPairs[signer.address] = secret;
        }
        // Wallet-authorized rows intentionally omitted from the map; the
        // kit's wallet adapter routes their signing automatically when the
        // transaction submits.
      } else if (signer.kind == SignerKind.ed25519) {
        // Collect the verified raw seed for the caller to register.
        final publicKey = SelectedSignerBuilder.ed25519PublicKeyFor(signer.rawSigner);
        if (publicKey != null) {
          final identity = Ed25519SignerIdentity(
            verifierAddress: signer.address,
            publicKey: publicKey,
          );
          final rawSeed = _verifiedEd25519Secrets[identity];
          if (rawSeed != null) {
            ed25519Secrets[identity] = rawSeed;
          }
        }
      }
    }

    _confirmed = true;
    Navigator.of(context).pop();
    // Fire-and-forget: [onConfirm] is `void`; the caller owns error handling.
    widget.onConfirm(selectedSigners, delegatedKeyPairs, ed25519Secrets);
  }

  void _onCancelPressed() {
    Navigator.of(context).pop();
    widget.onCancel();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // Bucket signer indices by kind so each section can be rendered with its
    // own header in the canonical passkey -> delegated -> ed25519 order.
    final passkeyIndices = <int>[];
    final delegatedIndices = <int>[];
    final ed25519Indices = <int>[];
    for (var i = 0; i < widget.availableSigners.length; i++) {
      switch (widget.availableSigners[i].kind) {
        case SignerKind.passkey:
          passkeyIndices.add(i);
        case SignerKind.delegated:
          delegatedIndices.add(i);
        case SignerKind.ed25519:
          ed25519Indices.add(i);
      }
    }

    final selectedCount = _selected.where((v) => v).length;
    final confirmLabelText =
        '${widget.confirmLabel} ($selectedCount selected)';

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              title: widget.title,
              description: widget.description,
              onClose: _onCancelPressed,
            ),
            const SizedBox(height: 16),

            // Empty-state copy when there are no available signers.
            if (widget.availableSigners.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'No signers available for this context.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

            // Passkey Signers section
            if (passkeyIndices.isNotEmpty) ...[
              _buildSectionHeader('Passkey Signers', colorScheme, textTheme),
              const SizedBox(height: 8),
              ...passkeyIndices.map(
                (i) => _buildSignerEntry(context, i, colorScheme, textTheme),
              ),
              const SizedBox(height: 8),
            ],

            // Stellar Account Signers section
            if (delegatedIndices.isNotEmpty) ...[
              _buildSectionHeader(
                'Stellar Account Signers',
                colorScheme,
                textTheme,
              ),
              const SizedBox(height: 8),
              ...delegatedIndices.map(
                (i) => _buildSignerEntry(context, i, colorScheme, textTheme),
              ),
              const SizedBox(height: 8),
            ],

            // Ed25519 Signers section
            if (ed25519Indices.isNotEmpty) ...[
              _buildSectionHeader('Ed25519 Signers', colorScheme, textTheme),
              const SizedBox(height: 8),
              ...ed25519Indices.map(
                (i) => _buildSignerEntry(context, i, colorScheme, textTheme),
              ),
              const SizedBox(height: 8),
            ],

            // Validation error
            if (_validationError != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                enabled: _validationError != null,
                child: InlineErrorBanner(message: _validationError!),
              ),
            ],

            const SizedBox(height: 20),

            // Buttons. [ButtonLabel] shrinks long labels to a single line.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _onCancelPressed,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const ButtonLabel('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: selectedCount == 0 ? null : _onConfirm,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: ButtonLabel(
                      confirmLabelText,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    String label,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Semantics(
      header: true,
      child: Text(
        label,
        style: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildSignerEntry(
    BuildContext context,
    int index,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final signer = widget.availableSigners[index];

    if (signer.kind == SignerKind.delegated) {
      final activeAddr = _activeWalletAddress;
      final otherWalletBusy =
          activeAddr != null && activeAddr != signer.address;
      return _DelegatedSignerRow(
        // Key by address so the row state survives sibling rebuilds and is
        // recreated only when the underlying signer changes.
        key: ValueKey<String>('delegated-row-${signer.address}'),
        signer: signer,
        otherWalletBusy: otherWalletBusy,
        walletConnector: widget.walletConnector,
        walletConnectLabel: widget.walletConnectLabel,
        validateDelegatedSecret: widget.validateDelegatedSecret,
        onChanged: (selected, verifiedSecret) {
          _onDelegatedRowChanged(index, signer, selected, verifiedSecret);
        },
        onWalletActivityChanged: (active) {
          _onRowWalletActivityChanged(signer, active);
        },
      );
    }

    if (signer.kind == SignerKind.ed25519) {
      final publicKey = SelectedSignerBuilder.ed25519PublicKeyFor(signer.rawSigner);
      // Only render the interactive Ed25519 row when the adapter is present
      // and the public key can be extracted from the raw signer.
      if (publicKey != null && widget.ed25519SigningEnabled) {
        final identity = Ed25519SignerIdentity(
          verifierAddress: signer.address,
          publicKey: publicKey,
        );
        return _Ed25519SignerRow(
          key: ValueKey<String>('ed25519-row-${signer.address}'),
          signer: signer,
          publicKey: publicKey,
          validateEd25519Secret: widget.validateEd25519Secret,
          onChanged: (selected, rawSeed) {
            _onEd25519RowChanged(index, identity, rawSeed, selected);
          },
        );
      }
    }

    final isSelected = _selected[index];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          elevation: 0,
          color: colorScheme.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: isSelected
                  ? colorScheme.primary.withAlpha(120)
                  : colorScheme.outlineVariant,
            ),
          ),
          child: CheckboxListTile(
            value: isSelected,
            onChanged: (v) {
              setState(() {
                _selected[index] = v ?? false;
                _validationError = null;
              });
            },
            title: _buildSignerTitle(signer, colorScheme, textTheme),
            subtitle: _buildSignerSubtitle(signer, colorScheme, textTheme),
            secondary: _buildSignerBadge(signer, colorScheme, textTheme),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Passkey / Ed25519 row helpers
  // -------------------------------------------------------------------------

  /// Builds the title for non-delegated rows. For passkey signers the row
  /// carries an "Active" badge beside the label when this entry matches the
  /// connected credential.
  Widget _buildSignerTitle(
    SignerInfo signer,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final labelText = Text(
      signer.displayLabel,
      style: textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
    );

    if (signer.kind == SignerKind.passkey && signer.isConnectedCredential) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: labelText),
          const SizedBox(width: 8),
          Pill(
            label: 'Active',
            background: Colors.green.shade100,
            foreground: Colors.green.shade900,
          ),
        ],
      );
    }
    return labelText;
  }

  Widget? _buildSignerSubtitle(
    SignerInfo signer,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (signer.kind) {
      case SignerKind.passkey:
        return Text(
          SignerTypeLabel.passkeyLong,
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        );
      case SignerKind.delegated:
        // Delegated rows render their own subtitle inside the custom layout
        // — the CheckboxListTile path is not used.
        return null;
      case SignerKind.ed25519:
        return Text(
          'Ed25519 External Signer',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        );
    }
  }

  /// Renders the right-hand trailing chip on each non-delegated row.
  Widget? _buildSignerBadge(
    SignerInfo signer,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (signer.kind) {
      case SignerKind.passkey:
        return _buildKindChip('WebAuthn', colorScheme);
      case SignerKind.ed25519:
        return _buildKindChip(SignerTypeLabel.ed25519, colorScheme);
      case SignerKind.delegated:
        return null;
    }
  }

  Widget _buildKindChip(String label, ColorScheme colorScheme) {
    return Pill(
      label: label,
      background: colorScheme.secondary,
      foreground: colorScheme.onSecondary,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }
}

// ---------------------------------------------------------------------------
// _DelegatedSignerRow
// ---------------------------------------------------------------------------

/// Renders a single delegated (Stellar account) signer row inside the picker.
///
/// The row owns its own [_DelegatedRowState] and runs the connect-wallet /
/// enter-key state machine internally. The parent sheet learns about the row
/// via two callbacks:
///
/// - [onChanged] is invoked whenever the row's selection or verified secret
///   changes, letting the parent recompute the confirm count and assemble
///   the `delegatedKeyPairs` map at confirm time.
/// - [onWalletActivityChanged] is invoked when the row enters or leaves a
///   state that holds the external wallet session, so the parent can enforce
///   the single-wallet invariant across sibling rows via [otherWalletBusy].
class _DelegatedSignerRow extends StatefulWidget {
  const _DelegatedSignerRow({
    required this.signer,
    required this.otherWalletBusy,
    required this.walletConnector,
    required this.walletConnectLabel,
    required this.validateDelegatedSecret,
    required this.onChanged,
    required this.onWalletActivityChanged,
    super.key,
  });

  /// The delegated signer this row represents.
  final SignerInfo signer;

  /// True when a different row currently holds the external wallet session,
  /// in which case this row's Connect button must be disabled.
  final bool otherWalletBusy;

  /// External wallet connector. When null the Connect affordance is hidden
  /// and the row can only be authorized via secret-key entry.
  final WalletConnector? walletConnector;

  /// Label rendered on the Connect button.
  final String walletConnectLabel;

  /// Synchronous secret-seed validator delegated to the calling flow.
  final String? Function(String address, String seed) validateDelegatedSecret;

  /// Notifies the parent whenever the row's selection bit or verified-secret
  /// material changes. [verifiedSecret] is the seed string when the row is
  /// in the `keypairVerified` state, otherwise null.
  final void Function(bool selected, String? verifiedSecret) onChanged;

  /// Notifies the parent when the row transitions into or out of a state
  /// that owns the wallet session (`walletConnecting` or `walletConnected`).
  final ValueChanged<bool> onWalletActivityChanged;

  @override
  State<_DelegatedSignerRow> createState() => _DelegatedSignerRowState();
}

class _DelegatedSignerRowState extends State<_DelegatedSignerRow> {
  final _DelegatedRowState _row = _DelegatedRowState();

  /// Mirrors the row's selection bit so the checkbox renders correctly and
  /// the parent stays in sync via [widget.onChanged].
  bool _selected = false;

  @override
  void dispose() {
    _row.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // State transitions
  // -------------------------------------------------------------------------

  /// Reports the row's current selection + verified-secret state to the
  /// parent. Centralised so every transition routes through one place.
  void _emitChanged() {
    widget.onChanged(_selected, _row.verifiedSecret);
  }

  /// Reports the row's wallet-activity state to the parent. Active is true
  /// while the row is in `walletConnecting` or `walletConnected`.
  void _emitWalletActivity(bool active) {
    widget.onWalletActivityChanged(active);
  }

  // -------------------------------------------------------------------------
  // Enter Key flow
  // -------------------------------------------------------------------------

  void _onEnterKeyPressed() {
    setState(() {
      _row.status = _DelegatedAuthStatus.enteringKey;
      _row.error = null;
      _row.secretError = null;
      _row.obscured = true;
      _row.controller.clear();
    });
  }

  void _onCancelKeyEntry() {
    setState(() {
      _row.status = _DelegatedAuthStatus.none;
      _row.secretError = null;
      _row.controller.clear();
    });
  }

  Future<void> _onVerifySecret() async {
    final seed = _row.controller.text.trim();
    if (seed.isEmpty) {
      setState(() => _row.secretError = 'Secret key is required.');
      return;
    }

    setState(() {
      _row.validating = true;
      _row.secretError = null;
    });

    await _yieldToEventLoop();
    final error = widget.validateDelegatedSecret(widget.signer.address, seed);

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _row.validating = false;
        _row.secretError = error;
      });
      return;
    }

    // Success: store the verified seed, auto-select the row, hide the form,
    // and clear the controller so the typed material is not retained.
    setState(() {
      _selected = true;
      _row.status = _DelegatedAuthStatus.keypairVerified;
      _row.verifiedSecret = seed;
      _row.error = null;
      _row.validating = false;
      _row.secretError = null;
      _row.controller.clear();
    });
    _emitChanged();
  }

  void _onClearVerifiedKey() {
    setState(() {
      _selected = false;
      _row.status = _DelegatedAuthStatus.none;
      _row.verifiedSecret = null;
    });
    _emitChanged();
  }

  // -------------------------------------------------------------------------
  // Connect / disconnect wallet flow
  // -------------------------------------------------------------------------

  Future<void> _onConnectWallet() async {
    final connector = widget.walletConnector;
    if (connector == null) return;

    setState(() {
      _row.status = _DelegatedAuthStatus.walletConnecting;
      _row.error = null;
      _selected = false;
    });
    _emitChanged();
    _emitWalletActivity(true);

    try {
      final connected = await connector.connect();
      if (!mounted) return;

      if (connected == null) {
        // User cancelled the wallet UI — silently revert to [none].
        setState(() {
          _row.status = _DelegatedAuthStatus.none;
        });
        _emitWalletActivity(false);
        return;
      }

      if (connected != widget.signer.address) {
        // Wallet returned a different account than the one this row
        // represents. Disconnect best-effort and surface the mismatch.
        try {
          await connector.disconnect();
        } catch (_) {
          // ignored
        }
        if (!mounted) return;
        setState(() {
          _row.status = _DelegatedAuthStatus.walletError;
          _row.error =
              'Connected wallet address does not match this signer. '
              'Disconnected.';
          _selected = false;
        });
        _emitChanged();
        _emitWalletActivity(false);
        return;
      }

      setState(() {
        _row.status = _DelegatedAuthStatus.walletConnected;
        _row.error = null;
        _selected = true;
      });
      _emitChanged();
      // Still active (connected, not just connecting); leave invariant set.
    } on WalletNetworkMismatchException catch (e) {
      if (!mounted) return;
      setState(() {
        _row.status = _DelegatedAuthStatus.walletError;
        _row.error = e.toString();
        _selected = false;
      });
      _emitChanged();
      _emitWalletActivity(false);
    } on WalletConnectionException catch (e) {
      if (!mounted) return;
      setState(() {
        _row.status = _DelegatedAuthStatus.walletError;
        _row.error = e.message;
        _selected = false;
      });
      _emitChanged();
      _emitWalletActivity(false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _row.status = _DelegatedAuthStatus.walletError;
        _row.error = 'Connection failed: $e';
        _selected = false;
      });
      _emitChanged();
      _emitWalletActivity(false);
    }
  }

  Future<void> _onDisconnectWallet() async {
    final connector = widget.walletConnector;

    setState(() {
      _row.status = _DelegatedAuthStatus.none;
      _selected = false;
      _row.error = null;
    });
    _emitChanged();
    _emitWalletActivity(false);

    if (connector == null) return;
    try {
      await connector.disconnect();
    } catch (_) {
      // Best-effort; nothing we can usefully surface here.
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final status = _row.status;
    final isAuthorized = status == _DelegatedAuthStatus.keypairVerified ||
        status == _DelegatedAuthStatus.walletConnected;
    final isSelected = _selected && isAuthorized;
    final errorMsg = _row.error;

    final cardBorder = isSelected
        ? colorScheme.primary.withAlpha(120)
        : colorScheme.outlineVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          elevation: 0,
          color: colorScheme.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: cardBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title row: checkbox + label + status badge.
                Row(
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: isAuthorized
                          ? (v) {
                              setState(() {
                                _selected = v ?? false;
                              });
                              _emitChanged();
                            }
                          : null,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.signer.displayLabel,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          _buildSubtitle(status, colorScheme, textTheme),
                        ],
                      ),
                    ),
                    _buildStatusBadge(status),
                  ],
                ),

                // State-specific controls.
                _buildControls(status, colorScheme, textTheme),

                // Error caption (walletError state).
                if (errorMsg != null &&
                    status == _DelegatedAuthStatus.walletError) ...[
                  const SizedBox(height: 6),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      'Error: $errorMsg',
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Inline secret-key entry form.
        if (status == _DelegatedAuthStatus.enteringKey)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4, bottom: 4),
            child: _SecretKeyForm(
              controller: _row.controller,
              obscured: _row.obscured,
              validating: _row.validating,
              errorText: _row.secretError,
              hintText: 'S...',
              onCancel: _onCancelKeyEntry,
              onSubmit: _onVerifySecret,
              onObscuredToggle: () =>
                  setState(() => _row.obscured = !_row.obscured),
              onErrorCleared: () =>
                  setState(() => _row.secretError = null),
            ),
          ),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSubtitle(
    _DelegatedAuthStatus status,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (status) {
      case _DelegatedAuthStatus.keypairVerified:
        return Text(
          'Ready to sign',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.activityLogOk,
          ),
        );
      case _DelegatedAuthStatus.walletConnected:
        return Text(
          '${_walletShortLabel(widget.walletConnectLabel)} - Ready to sign',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.activityLogOk,
          ),
        );
      case _DelegatedAuthStatus.walletConnecting:
        return Text(
          'Connecting wallet...',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        );
      case _DelegatedAuthStatus.none:
      case _DelegatedAuthStatus.enteringKey:
      case _DelegatedAuthStatus.walletError:
        return Text(
          'Enter secret key or connect wallet to enable signing',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        );
    }
  }

  Widget _buildStatusBadge(_DelegatedAuthStatus status) {
    switch (status) {
      case _DelegatedAuthStatus.keypairVerified:
        return const Pill(
          label: 'Verified',
          background: verifiedBadgeBackground,
          foreground: Colors.white,
        );
      case _DelegatedAuthStatus.walletConnected:
        return Pill(
          label: _walletShortLabel(widget.walletConnectLabel),
          background: walletBadgeBackground,
          foreground: Colors.white,
        );
      case _DelegatedAuthStatus.none:
      case _DelegatedAuthStatus.enteringKey:
      case _DelegatedAuthStatus.walletConnecting:
      case _DelegatedAuthStatus.walletError:
        return const SizedBox.shrink();
    }
  }

  Widget _buildControls(
    _DelegatedAuthStatus status,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (status) {
      case _DelegatedAuthStatus.none:
      case _DelegatedAuthStatus.walletError:
        return Padding(
          padding: const EdgeInsets.only(top: 8, left: 8),
          child: _buildAuthButtonsRow(
            enabled: true,
            connecting: false,
            textTheme: textTheme,
          ),
        );
      case _DelegatedAuthStatus.walletConnecting:
        return Padding(
          padding: const EdgeInsets.only(top: 8, left: 8),
          child: _buildAuthButtonsRow(
            enabled: false,
            connecting: true,
            textTheme: textTheme,
          ),
        );
      case _DelegatedAuthStatus.keypairVerified:
        return Padding(
          padding: const EdgeInsets.only(top: 4, left: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _onClearVerifiedKey,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Clear key',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ),
          ),
        );
      case _DelegatedAuthStatus.walletConnected:
        return Padding(
          padding: const EdgeInsets.only(top: 4, left: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _onDisconnectWallet,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Disconnect',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.error,
                ),
              ),
            ),
          ),
        );
      case _DelegatedAuthStatus.enteringKey:
        return const SizedBox.shrink();
    }
  }

  Widget _buildAuthButtonsRow({
    required bool enabled,
    required bool connecting,
    required TextTheme textTheme,
  }) {
    final enterKeyButton = OutlinedButton.icon(
      onPressed: enabled ? _onEnterKeyPressed : null,
      icon: const Icon(Icons.vpn_key, size: 14),
      label: const Text('Enter Key'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: textTheme.labelSmall,
      ),
    );

    Widget connectButton;
    if (widget.walletConnector == null) {
      connectButton = const SizedBox.shrink();
    } else if (connecting) {
      connectButton = OutlinedButton(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          textStyle: textTheme.labelSmall,
        ),
        child: const LoadingLabel(label: 'Connecting...', size: 14),
      );
    } else {
      // Single-wallet invariant: the parent reports whether another row is
      // currently holding the wallet session and disables the Connect button
      // here.
      connectButton = OutlinedButton.icon(
        onPressed: enabled && !widget.otherWalletBusy ? _onConnectWallet : null,
        icon: const Icon(Icons.link, size: 14),
        label: Text(widget.walletConnectLabel),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          textStyle: textTheme.labelSmall,
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        enterKeyButton,
        if (widget.walletConnector != null) connectButton,
      ],
    );
  }

}


// ---------------------------------------------------------------------------
// _Ed25519SignerRow
// ---------------------------------------------------------------------------

/// Renders a single Ed25519 external signer row inside the picker.
///
/// The row owns its own [_Ed25519RowState] and runs the secret-key entry
/// state machine internally. On successful secret-key verification the row
/// transitions to [_Ed25519AuthStatus.verified] and reports the raw seed
/// bytes to the parent via [onChanged]; the parent stores them in a
/// picker-local cache and passes them to [SignerPickerSheet.onConfirm].
/// The row never registers keypairs into any manager or adapter directly.
///
/// Validates a hex-encoded Ed25519 secret seed against [expectedPublicKey].
///
/// [hexInput] is the lowercased hex string entered by the user.
/// Returns a record with [rawSeed] on success and [error] on failure; exactly
/// one of the two fields is non-null.
typedef Ed25519SecretValidator = ({Uint8List? rawSeed, String? error}) Function(
  Uint8List expectedPublicKey,
  String hexInput,
);

/// [onChanged] is invoked whenever the row's selection or verified-secret
/// state changes. [selected] is the new selection bit. [rawSeed] is the
/// 32-byte raw Ed25519 seed when the row transitions to the verified state,
/// and null when the verified secret is cleared.
class _Ed25519SignerRow extends StatefulWidget {
  const _Ed25519SignerRow({
    required this.signer,
    required this.publicKey,
    required this.validateEd25519Secret,
    required this.onChanged,
    super.key,
  });

  /// The Ed25519 signer this row represents.
  final SignerInfo signer;

  /// The 32-byte Ed25519 public key extracted from [signer.rawSigner].
  final Uint8List publicKey;

  /// Validates a hex-encoded Ed25519 secret seed against [publicKey].
  ///
  /// Delegated to the calling flow so the widget does not import the Stellar
  /// SDK directly.
  final Ed25519SecretValidator validateEd25519Secret;

  /// Notifies the parent when the row's selection bit or verified-secret
  /// material changes.
  final void Function(bool selected, Uint8List? rawSeed) onChanged;

  @override
  State<_Ed25519SignerRow> createState() => _Ed25519SignerRowState();
}

class _Ed25519SignerRowState extends State<_Ed25519SignerRow> {
  final _Ed25519RowState _row = _Ed25519RowState();

  /// Mirrors the row's selection bit.
  bool _selected = false;

  @override
  void dispose() {
    _row.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Enter Key flow
  // -------------------------------------------------------------------------

  void _onEnterKeyPressed() {
    setState(() {
      _row.status = _Ed25519AuthStatus.enteringKey;
      _row.secretError = null;
      _row.obscured = true;
      _row.controller.clear();
    });
  }

  void _onCancelKeyEntry() {
    setState(() {
      _row.status = _Ed25519AuthStatus.none;
      _row.secretError = null;
      _row.controller.clear();
    });
  }

  Future<void> _onVerifySecret() async {
    final input = _row.controller.text.trim();
    if (input.isEmpty) {
      setState(() => _row.secretError = 'Secret key is required.');
      return;
    }

    setState(() {
      _row.validating = true;
      _row.secretError = null;
    });

    await _yieldToEventLoop();

    if (!mounted) return;

    final hexInput = input.toLowerCase();

    // Delegate hex decode, keypair derivation, and public-key comparison to
    // the flow-layer validator so the widget carries no SDK dependency.
    final result = widget.validateEd25519Secret(widget.publicKey, hexInput);

    if (result.error != null) {
      setState(() {
        _row.validating = false;
        _row.secretError = result.error;
      });
      return;
    }

    if (!mounted) return;

    // Cache the raw seed in the parent's local store via the callback;
    // the caller passes it to the flow at confirm time. The adapter is not
    // touched here — registration happens immediately before submission.
    setState(() {
      _selected = true;
      _row.status = _Ed25519AuthStatus.verified;
      _row.validating = false;
      _row.secretError = null;
      _row.controller.clear();
    });
    widget.onChanged(true, result.rawSeed);
  }

  void _onClearVerifiedKey() {
    setState(() {
      _selected = false;
      _row.status = _Ed25519AuthStatus.none;
    });
    widget.onChanged(false, null);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final status = _row.status;
    final isVerified = status == _Ed25519AuthStatus.verified;
    final isSelected = _selected && isVerified;

    final cardBorder = isSelected
        ? colorScheme.primary.withAlpha(120)
        : colorScheme.outlineVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          elevation: 0,
          color: colorScheme.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: cardBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title row: checkbox + label + status badge.
                Row(
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: isVerified
                          ? (v) {
                              setState(() {
                                _selected = v ?? false;
                              });
                              widget.onChanged(_selected, null);
                            }
                          : null,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.signer.displayLabel,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          _buildSubtitle(status, colorScheme, textTheme),
                        ],
                      ),
                    ),
                    _buildStatusBadge(status, colorScheme),
                  ],
                ),

                // State-specific controls.
                _buildControls(status, colorScheme, textTheme),
              ],
            ),
          ),
        ),

        // Inline secret-key entry form — reuses the same form widget as the
        // delegated signer row; no duplication of form logic or layout.
        if (status == _Ed25519AuthStatus.enteringKey)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4, bottom: 4),
            child: _SecretKeyForm(
              controller: _row.controller,
              obscured: _row.obscured,
              validating: _row.validating,
              errorText: _row.secretError,
              hintText: '64 hex characters',
              onCancel: _onCancelKeyEntry,
              onSubmit: _onVerifySecret,
              onObscuredToggle: () =>
                  setState(() => _row.obscured = !_row.obscured),
              onErrorCleared: () =>
                  setState(() => _row.secretError = null),
            ),
          ),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSubtitle(
    _Ed25519AuthStatus status,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final text = switch (status) {
      _Ed25519AuthStatus.verified => 'Ready to sign',
      _Ed25519AuthStatus.none ||
      _Ed25519AuthStatus.enteringKey =>
        'Enter secret key to enable signing',
    };
    final color = status == _Ed25519AuthStatus.verified
        ? colorScheme.activityLogOk
        : colorScheme.onSurfaceVariant;
    return Text(
      text,
      style: textTheme.bodySmall?.copyWith(color: color),
    );
  }

  Widget _buildStatusBadge(_Ed25519AuthStatus status, ColorScheme colorScheme) {
    if (status == _Ed25519AuthStatus.verified) {
      return const Pill(
        label: 'Verified',
        background: verifiedBadgeBackground,
        foreground: Colors.white,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildControls(
    _Ed25519AuthStatus status,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (status) {
      case _Ed25519AuthStatus.none:
        return Padding(
          padding: const EdgeInsets.only(top: 8, left: 8),
          child: OutlinedButton.icon(
            onPressed: _onEnterKeyPressed,
            icon: const Icon(Icons.vpn_key, size: 14),
            label: const Text('Enter Key'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle: textTheme.labelSmall,
            ),
          ),
        );
      case _Ed25519AuthStatus.enteringKey:
        return const SizedBox.shrink();
      case _Ed25519AuthStatus.verified:
        return Padding(
          padding: const EdgeInsets.only(top: 4, left: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _onClearVerifiedKey,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Clear key',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ),
          ),
        );
    }
  }

}

// ---------------------------------------------------------------------------
// _SecretKeyForm
// ---------------------------------------------------------------------------

/// Shared secret-key entry form used by both delegated-signer and Ed25519
/// signer rows.
///
/// Both row types render the same Card / TextField / button chrome. The only
/// content difference is [hintText] (`'S...'` for Stellar secret keys,
/// `'64 hex characters'` for Ed25519 raw seeds). All state mutations are
/// delegated back to the owning row state via the callback parameters so this
/// widget remains stateless.
class _SecretKeyForm extends StatelessWidget {
  const _SecretKeyForm({
    required this.controller,
    required this.obscured,
    required this.validating,
    required this.hintText,
    required this.onCancel,
    required this.onSubmit,
    required this.onObscuredToggle,
    required this.onErrorCleared,
    this.errorText,
  });

  /// Backing controller for the secret-key [TextField].
  final TextEditingController controller;

  /// Whether the text field is currently rendering its contents as obscured.
  final bool obscured;

  /// Whether a verify request is in-flight. Disables all interactive controls.
  final bool validating;

  /// Hint text displayed inside the [TextField] when empty. Differs between
  /// delegated signers (`'S...'`) and Ed25519 signers (`'64 hex characters'`).
  final String hintText;

  /// Current validation error text, or null when no error is shown.
  final String? errorText;

  /// Called when the user taps the close icon or the Cancel button.
  final VoidCallback onCancel;

  /// Called when the user taps the Verify button.
  final VoidCallback onSubmit;

  /// Called when the user taps the visibility-toggle icon button. The owning
  /// state class is responsible for flipping the obscured flag and triggering
  /// a rebuild.
  final VoidCallback onObscuredToggle;

  /// Called when the user edits the text field while an error is showing. The
  /// owning state class is responsible for clearing the error and triggering a
  /// rebuild.
  final VoidCallback onErrorCleared;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Enter secret key',
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Cancel',
                  onPressed: validating ? null : onCancel,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              obscureText: obscured,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              enabled: !validating,
              contextMenuBuilder: (context, editableTextState) =>
                  AdaptiveTextSelectionToolbar.editableText(
                    editableTextState: editableTextState,
                  ),
              onChanged: (_) {
                if (errorText != null) {
                  onErrorCleared();
                }
              },
              decoration: InputDecoration(
                labelText: 'Secret Key',
                hintText: hintText,
                errorText: errorText,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    obscured ? Icons.visibility : Icons.visibility_off,
                    semanticLabel:
                        obscured ? 'Show secret key' : 'Hide secret key',
                  ),
                  onPressed: onObscuredToggle,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: validating ? null : onCancel,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: validating ? null : onSubmit,
                  child: validating
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Verify'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The secret key is held in memory for this signing session only.',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Event-loop yield helper
// ---------------------------------------------------------------------------

/// Yields to the event loop so the UI can repaint before a synchronous
/// validation call runs.
Future<void> _yieldToEventLoop() => Future.delayed(Duration.zero);
