/// Add-form for the Ed25519 external signer kind.
///
/// Owns its own hex-key controller, validation error, and verifier
/// helper-text rendering. Reports successful adds via [onAddSigner] and
/// never constructs SDK signer instances directly — Ed25519 signer
/// construction is routed through [buildEd25519Signer].
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../flows/context_rule_builder_types.dart';
import '../../util/error_utils.dart';
import '../../util/format_utils.dart';
import '../../util/signer_type_label.dart';

/// Stateful form that gathers a 32-byte Ed25519 public key from the user
/// and submits it as a [StagedSigner] of [StagedSignerType.ed25519].
class Ed25519AddForm extends StatefulWidget {
  /// Creates an Ed25519-signer add form.
  const Ed25519AddForm({
    required this.isSubmitting,
    required this.ed25519VerifierAddress,
    required this.buildEd25519Signer,
    required this.onAddSigner,
    super.key,
  });

  /// True while the parent form is submitting; disables the inputs.
  final bool isSubmitting;

  /// Ed25519 verifier C-address; truncated and shown as helper text. When
  /// null, the submit handler short-circuits with an inline error and the
  /// helper text reads "Uses verifier: not configured".
  final String? ed25519VerifierAddress;

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

  @override
  State<Ed25519AddForm> createState() => _Ed25519AddFormState();
}

class _Ed25519AddFormState extends State<Ed25519AddForm> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onAdd() {
    final raw = _controller.text.trim().toLowerCase();
    String? error;
    if (raw.isEmpty) {
      error = 'Public key is required';
    } else if (raw.length != 64) {
      error = 'Must be 64 hex characters (32 bytes), got ${raw.length}';
    } else if (!isValidHex(raw)) {
      error = 'Invalid hex characters';
    }

    if (error != null) {
      setState(() => _error = error);
      return;
    }

    final verifier = widget.ed25519VerifierAddress;
    if (verifier == null) {
      setState(() =>
          _error = 'Ed25519 verifier is not configured for this account.');
      return;
    }

    final StagedSigner staged;
    try {
      final bytes = Uint8List.fromList(hexToBytes(raw));
      staged = StagedSigner(
        type: StagedSignerType.ed25519,
        identifier: 'key:${raw.substring(0, 8)}...',
        signer: widget.buildEd25519Signer(bytes),
      );
    } catch (e) {
      final classified = classifyError(e, context: 'Invalid key');
      setState(() => _error = classified.message);
      return;
    }

    final addError = widget.onAddSigner(staged);
    if (addError != null) {
      setState(() => _error = addError);
      return;
    }
    _controller.clear();
    setState(() => _error = null);
    SemanticsService.announce(
      'Added ${SignerTypeLabel.ed25519} signer',
      Directionality.of(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final verifier = widget.ed25519VerifierAddress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          onChanged: (_) {
            setState(() {
              if (_error != null) _error = null;
            });
          },
          decoration: const InputDecoration(
            labelText: 'Ed25519 Public Key (hex)',
            hintText: '64 hex characters',
            border: OutlineInputBorder(),
          ),
          enabled: !widget.isSubmitting,
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'\s')),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          verifier != null
              ? 'Uses verifier: ${truncateAddress(verifier, chars: 6)}'
              : 'Uses verifier: not configured',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed:
                widget.isSubmitting || _controller.text.trim().isEmpty
                    ? null
                    : _onAdd,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('Add Ed25519 Signer'),
          ),
        ),
      ],
    );
  }
}
