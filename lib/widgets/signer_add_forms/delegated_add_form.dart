/// Add-form for the delegated (Stellar G-address) signer kind.
///
/// Owns its own text controller, validation error, and Freighter-import
/// progress flag. Reports successful adds via [onAddSigner] and never
/// constructs SDK signer instances directly — delegated signer construction
/// is routed through [buildDelegatedSigner].
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../flows/context_rule_builder_types.dart';
import '../../state/demo_state.dart';
import '../../util/error_utils.dart';
import '../../util/format_utils.dart';
import '../../wallet/wallet_connector.dart';
import '../field_error_text.dart';

/// Stateful form that gathers a G-address from the user and submits it as
/// a [StagedSigner] of [StagedSignerType.delegated].
class DelegatedAddForm extends ConsumerStatefulWidget {
  /// Creates a delegated-signer add form.
  const DelegatedAddForm({
    required this.isSubmitting,
    required this.buildDelegatedSigner,
    required this.onAddSigner,
    super.key,
  });

  /// True while the parent form is submitting; disables the inputs.
  final bool isSubmitting;

  /// Builds an [OZSmartAccountSigner] for a delegated (Stellar G-address)
  /// signer from a validated address string. Routed through the flow so
  /// the widget never constructs SDK signer instances directly.
  final OZSmartAccountSigner Function(String address) buildDelegatedSigner;

  /// Called when the user successfully adds a new signer.
  ///
  /// Returns null on success or an error string when the signer cannot be
  /// added (e.g. duplicate / cap exceeded).
  final String? Function(StagedSigner signer) onAddSigner;

  @override
  ConsumerState<DelegatedAddForm> createState() => _DelegatedAddFormState();
}

class _DelegatedAddFormState extends ConsumerState<DelegatedAddForm> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _isImportingFromWallet = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onAdd() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Address is required');
      return;
    }
    if (!isValidAccountAddress(raw)) {
      setState(() => _error = 'Must be a valid G-address (56 characters)');
      return;
    }

    final StagedSigner staged;
    try {
      staged = StagedSigner(
        type: StagedSignerType.delegated,
        identifier: truncateAddress(raw, chars: 6),
        signer: widget.buildDelegatedSigner(raw),
      );
    } catch (e) {
      final classified = classifyError(e, context: 'Invalid address');
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
      'Added Delegated signer',
      Directionality.of(context),
    );
  }

  Future<void> _onImportFromFreighter(WalletConnector connector) async {
    setState(() {
      _isImportingFromWallet = true;
      _error = null;
    });
    try {
      final address = await connector.connect();
      if (!mounted) return;
      if (address == null || address.isEmpty) {
        // User cancelled the popup — no error surface.
        setState(() => _isImportingFromWallet = false);
        return;
      }
      setState(() {
        _controller.text = address;
        _isImportingFromWallet = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isImportingFromWallet = false;
        _error = classifyError(
          e,
          context: 'Failed to import address from Freighter',
        ).message;
      });
    } finally {
      // Discard the ephemeral connection.
      try {
        await connector.disconnect();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Use the app-wide singleton connector (warmed up at app startup) so
    // the relay WebSocket is already open when the user taps Import. The
    // UI-effective getter returns null on the iOS Simulator and Android
    // emulators so the Import button hides on hosts where the underlying
    // deep link cannot reach a real wallet app.
    final importConnector =
        ref.read(demoStateProvider.notifier).walletConnectorForUi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          onChanged: (_) {
            // Always rebuild so the Add button enable-state tracks the
            // text field's contents and any prior error clears.
            setState(() {
              if (_error != null) _error = null;
            });
          },
          decoration: const InputDecoration(
            labelText: 'Stellar Address (G-address)',
            hintText: 'GABC...',
            border: OutlineInputBorder(),
          ),
          enabled: !widget.isSubmitting && !_isImportingFromWallet,
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'\s')),
          ],
        ),
        FieldErrorText(error: _error),
        if (importConnector != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.isSubmitting || _isImportingFromWallet
                  ? null
                  : () => _onImportFromFreighter(importConnector),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: _isImportingFromWallet
                  ? SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      ),
                    )
                  : const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: Text(
                _isImportingFromWallet
                    ? 'Connecting to Freighter...'
                    : 'Import from Freighter',
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: widget.isSubmitting ||
                    _isImportingFromWallet ||
                    _controller.text.trim().isEmpty
                ? null
                : _onAdd,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('Add Delegated Signer'),
          ),
        ),
      ],
    );
  }
}
