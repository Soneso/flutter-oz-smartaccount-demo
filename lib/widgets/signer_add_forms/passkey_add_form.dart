/// Add-form for the passkey (WebAuthn) external signer kind.
///
/// Owns its own name controller, load / register progress flags, info
/// banner, and the locally cached list of existing passkey signers loaded
/// via [loadPasskeySigners]. Reports successful adds via [onAddSigner].
/// The "already added" predicate is supplied by the parent so this widget
/// stays decoupled from the staged-signer list.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../flows/context_rule_builder_types.dart';
import '../../util/context_rule_format.dart';
import '../../util/error_utils.dart';
import '../../util/signer_colors.dart';
import '../../util/signer_type_label.dart';
import '../loading_label.dart';

/// Stateful form that surfaces both passkey-signer reuse and
/// passkey-signer registration, and submits the resulting signer as a
/// [StagedSigner] of [StagedSignerType.passkey].
class PasskeyAddForm extends StatefulWidget {
  /// Creates a passkey-signer add form.
  const PasskeyAddForm({
    required this.isSubmitting,
    required this.loadPasskeySigners,
    required this.registerPasskeySigner,
    required this.isAlreadyAdded,
    required this.onAddSigner,
    this.availableExistingPasskeys,
    super.key,
  });

  /// True while the parent form is submitting; disables the inputs.
  final bool isSubmitting;

  /// Called when the user taps "Reuse Signer". The returned future
  /// resolves to the list of available passkey signers excluding the
  /// connected wallet's own credential.
  final Future<List<OZExternalSigner>> Function() loadPasskeySigners;

  /// Called when the user taps "Register New". The returned future
  /// resolves to a constructed WebAuthn [OZSmartAccountSigner] ready for
  /// staging.
  final Future<OZSmartAccountSigner> Function(String name)
      registerPasskeySigner;

  /// Returns true when the supplied passkey is already part of the parent
  /// signer list (either as a staged signer or an edit-mode entry).
  final bool Function(OZExternalSigner passkey) isAlreadyAdded;

  /// Called when the user successfully adds a new signer.
  ///
  /// Returns null on success or an error string when the signer cannot be
  /// added (e.g. duplicate / cap exceeded).
  final String? Function(StagedSigner signer) onAddSigner;

  /// Pre-loaded existing-rule passkey signers shown in edit-mode's reuse
  /// section. When non-null, the reuse buttons render immediately on
  /// first build (no separate "Reuse Signer" trigger required).
  final List<OZExternalSigner>? availableExistingPasskeys;

  @override
  State<PasskeyAddForm> createState() => _PasskeyAddFormState();
}

class _PasskeyAddFormState extends State<PasskeyAddForm> {
  final TextEditingController _nameController = TextEditingController();
  String? _info;
  bool _isLoadingPasskeys = false;
  bool _isRegistering = false;
  bool _passkeysLoaded = false;
  List<OZExternalSigner> _availablePasskeys = const <OZExternalSigner>[];

  @override
  void initState() {
    super.initState();
    final pre = widget.availableExistingPasskeys;
    if (pre != null) {
      _availablePasskeys = pre;
      _passkeysLoaded = true;
    }
  }

  @override
  void didUpdateWidget(covariant PasskeyAddForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt the parent's pre-loaded list on the first frame that supplies
    // one (typical in edit-mode where the screen loads the list async and
    // then rebuilds with the result).
    final pre = widget.availableExistingPasskeys;
    if (pre != null && !_passkeysLoaded) {
      _availablePasskeys = pre;
      _passkeysLoaded = true;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Announces a successful passkey-signer add to assistive technology so
  /// VoiceOver / TalkBack users get audible feedback.
  void _announceAdded() {
    SemanticsService.announce(
      'Added ${SignerTypeLabel.passkeyShort} signer',
      Directionality.of(context),
    );
  }

  Future<void> _onLoadPasskeys() async {
    if (_isLoadingPasskeys) return;
    setState(() {
      _isLoadingPasskeys = true;
      _info = null;
    });
    try {
      final loaded = await widget.loadPasskeySigners();
      if (!mounted) return;
      setState(() {
        _availablePasskeys = loaded;
        _passkeysLoaded = true;
        _isLoadingPasskeys = false;
        if (loaded.isEmpty) {
          _info = 'No existing passkey signers found on this account.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      final classified = classifyError(e, context: 'Failed to load passkeys');
      setState(() {
        _isLoadingPasskeys = false;
        _info = classified.message;
      });
    }
  }

  void _onAddPasskeyFromList(OZExternalSigner passkey) {
    final info = formatSignerForDisplay(passkey);
    final staged = StagedSigner(
      type: StagedSignerType.passkey,
      identifier: info.displayValue,
      signer: passkey,
    );
    final addError = widget.onAddSigner(staged);
    if (addError != null) {
      setState(() => _info = addError);
      return;
    }
    setState(() => _info = null);
    _announceAdded();
  }

  Future<void> _onRegisterPasskey() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _isRegistering) return;
    setState(() {
      _isRegistering = true;
      _info = null;
    });
    try {
      final signer = await widget.registerPasskeySigner(name);
      if (!mounted) return;

      final info = formatSignerForDisplay(signer);
      final staged = StagedSigner(
        type: StagedSignerType.passkey,
        identifier: info.displayValue,
        signer: signer,
      );
      final addError = widget.onAddSigner(staged);
      var announce = false;
      setState(() {
        _isRegistering = false;
        if (addError != null) {
          _info = addError;
        } else {
          _nameController.clear();
          _passkeysLoaded = true;
          if (signer is OZExternalSigner && !widget.isAlreadyAdded(signer)) {
            _availablePasskeys = [..._availablePasskeys, signer];
          }
          announce = true;
        }
      });
      if (announce) {
        _announceAdded();
      }
    } on WebAuthnCancelled {
      if (!mounted) return;
      setState(() {
        _isRegistering = false;
        _info = 'Passkey registration cancelled';
      });
    } catch (e) {
      if (!mounted) return;
      final classified =
          classifyError(e, context: 'Failed to register passkey');
      setState(() {
        _isRegistering = false;
        _info = classified.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Purple-tinted card to highlight the passkey sub-section.
    final accent = signerTypeColor(SignerTypeLabel.passkeyLong);
    return Card(
      elevation: 0,
      color: accent.withAlpha(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: accent.withAlpha(70)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Semantics(
          container: true,
          label: 'Passkey signer add form',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Passkey (WebAuthn) Signer',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'You can reuse an account signer that is already stored in an '
                'existing context rule, or register a new passkey signer for '
                'this context rule.',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _isLoadingPasskeys ||
                          widget.isSubmitting ||
                          _passkeysLoaded
                      ? null
                      : _onLoadPasskeys,
                  child: _isLoadingPasskeys
                      ? LoadingLabel(
                          label: 'Loading...',
                          color: colorScheme.primary,
                        )
                      : const Text('Reuse Signer'),
                ),
              ),
              if (_passkeysLoaded && _availablePasskeys.isNotEmpty) ...[
                const SizedBox(height: 8),
                Semantics(
                  header: true,
                  child: Text(
                    'Available signers from existing context rules:',
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Semantics(
                  container: true,
                  label:
                      'Existing passkey signers, ${_availablePasskeys.length} available',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final passkey in _availablePasskeys) ...[
                        _AvailablePasskeyButton(
                          passkey: passkey,
                          isAlreadyAdded: widget.isAlreadyAdded(passkey),
                          isDisabled: widget.isSubmitting,
                          onAdd: () => _onAddPasskeyFromList(passkey),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ],
                  ),
                ),
              ],
              if (_info != null) ...[
                const SizedBox(height: 6),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _info!,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Divider(color: colorScheme.outlineVariant),
              const SizedBox(height: 8),
              Text(
                'Register a new passkey signer for this context rule:',
                style: textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _nameController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Passkey Name',
                  hintText: 'e.g., Recovery Key',
                  border: OutlineInputBorder(),
                ),
                enabled: !widget.isSubmitting && !_isRegistering,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isRegistering ||
                          widget.isSubmitting ||
                          _nameController.text.trim().isEmpty
                      ? null
                      : _onRegisterPasskey,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: _isRegistering
                      ? const LoadingLabel(
                          label: 'Registering...',
                          color: Colors.white,
                        )
                      : const Text('Register New'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Single existing-passkey row inside the reuse section.
class _AvailablePasskeyButton extends StatelessWidget {
  const _AvailablePasskeyButton({
    required this.passkey,
    required this.isAlreadyAdded,
    required this.isDisabled,
    required this.onAdd,
  });

  final OZExternalSigner passkey;
  final bool isAlreadyAdded;
  final bool isDisabled;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final info = formatSignerForDisplay(passkey);
    final label = isAlreadyAdded
        ? '${info.displayValue} (already added)'
        : 'Add: ${info.displayValue}';
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: (isDisabled || isAlreadyAdded) ? null : onAdd,
        child: Text(label),
      ),
    );
  }
}
