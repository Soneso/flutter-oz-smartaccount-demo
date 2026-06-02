/// Token transfer screen.
///
/// Guides the user through selecting a token, entering a recipient address
/// and amount, and submitting a token transfer from the connected smart
/// account.
///
/// Screens-never-call-SDK rule:
/// This screen must not reference SDK kit classes or manager accessors
/// directly. Only [TransferFlow] calls into the SDK.
///
/// State machine:
/// - Not Connected guard: if no wallet is connected, show error card and
///   [Go Back] button.
/// - Form: token dropdown, recipient address, amount.
/// - Transfer button: single-signer path when availableSigners.length <= 1,
///   multi-signer path (signer picker) when > 1.
/// - Success: [TransferResultCard] with [New Transfer] and [Go to Main Screen].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../flows/transfer_flow.dart';
import '../navigation/routes.dart';
import '../state/demo_state.dart';
import '../state/transfer_flow_provider.dart';
import '../theme/spacing.dart';
import '../util/semantic_colors.dart';
import '../widgets/error_card.dart';
import '../widgets/loading_button.dart';
import '../widgets/signer_picker_sheet.dart';
import '../widgets/transfer_result_card.dart';

// ---------------------------------------------------------------------------
// TransferScreen
// ---------------------------------------------------------------------------

/// Token transfer screen.
///
/// Dependencies are injected via the constructor so widget tests can
/// substitute mocks. In production the flow is resolved from the kit via
/// [transferFlowProvider].
class TransferScreen extends ConsumerStatefulWidget {
  /// Creates a [TransferScreen].
  ///
  /// [flow] is the optional injected [TransferFlow] for testing. When null
  /// (production), the screen resolves a flow from the provider at action time.
  const TransferScreen({this.flow, super.key});

  /// Optional injected [TransferFlow] for testing.
  final TransferFlow? flow;

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  // ---- Cached flow (resolved once in initState) ----

  TransferFlow? _flow;

  // ---- Token selection ----

  String _selectedToken = TransferFlow.tokenKeyXlm;

  // ---- Form controllers ----

  final _recipientController = TextEditingController();
  final _amountController = TextEditingController();

  // ---- Validation state ----

  String? _recipientError;
  String? _amountError;

  // ---- Loading / result state ----

  bool _isLoading = false;
  String? _errorMessage;
  TransferResult? _result;

  // ---- Multi-signer state ----

  List<SignerInfo> _availableSigners = const <SignerInfo>[];
  bool _signersLoaded = false;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    // Cache the flow once — preserves the in-flight guard across handler calls.
    _flow = widget.flow ?? ref.read(transferFlowProvider);
    _recipientController.addListener(_onRecipientChanged);
    _amountController.addListener(_onAmountChanged);
    // Load available signers once the frame is rendered.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_loadSigners()),
    );
  }

  @override
  void dispose() {
    _recipientController
      ..removeListener(_onRecipientChanged)
      ..dispose();
    _amountController
      ..removeListener(_onAmountChanged)
      ..dispose();
    super.dispose();
  }

  void _onRecipientChanged() {
    final error = _flow?.validateRecipient(_recipientController.text);
    setState(() {
      _recipientError =
          _recipientController.text.isNotEmpty ? error : null;
      _errorMessage = null;
    });
  }

  void _onAmountChanged() {
    final error = TransferFlow.validateAmount(_amountController.text);
    setState(() {
      _amountError =
          _amountController.text.isNotEmpty ? error : null;
      _errorMessage = null;
    });
  }

  // -------------------------------------------------------------------------
  // Signer loading
  // -------------------------------------------------------------------------

  Future<void> _loadSigners() async {
    if (_flow == null) return;
    final signers = await _flow!.loadAvailableSigners();
    if (mounted) {
      setState(() {
        _availableSigners = signers;
        _signersLoaded = true;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(demoStateProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => popOrGoMain(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: kCardPadding,
          children: [
            if (!connectionState.isConnected)
              ..._buildNotConnectedBranch(context, colorScheme)
            else
              ..._buildConnectedBranch(context, connectionState, colorScheme),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Not-connected branch
  // -------------------------------------------------------------------------

  List<Widget> _buildNotConnectedBranch(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    return [
      Card(
        elevation: 0,
        color: colorScheme.errorContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.errorBorder),
        ),
        child: Padding(
          padding: kCardPadding,
          child: Text(
            'No wallet connected. Please connect a wallet first.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onErrorContainer,
                ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => context.go(AppRoutes.main),
          child: const Text('Go Back'),
        ),
      ),
    ];
  }

  // -------------------------------------------------------------------------
  // Connected branch
  // -------------------------------------------------------------------------

  List<Widget> _buildConnectedBranch(
    BuildContext context,
    WalletConnectionState state,
    ColorScheme colorScheme,
  ) {
    final textTheme = Theme.of(context).textTheme;

    return [
      // Info card
      _buildInfoCard(context, colorScheme, textTheme),
      const SizedBox(height: 12),

      // Balance card
      _buildBalanceCard(context, state, colorScheme, textTheme),
      const SizedBox(height: 12),

      // Token dropdown (hidden after success)
      if (_result == null) ...[
        _buildTokenDropdown(context, colorScheme, textTheme),
        const SizedBox(height: 12),

        // Recipient address field
        _buildRecipientField(context, colorScheme, textTheme),
        const SizedBox(height: 12),

        // Amount field
        _buildAmountField(context, colorScheme, textTheme),
        const SizedBox(height: 12),

        // Inline error
        if (_errorMessage != null) ...[
          ErrorCard(message: _errorMessage!),
          const SizedBox(height: 12),
        ],

        // Transfer button
        _buildTransferButton(context, state),
      ],

      // Result card
      if (_result != null)
        TransferResultCard(
          result: _result!,
          xlmBalance: state.xlmBalance,
          demoTokenBalance: state.demoTokenBalance,
          onNewTransfer: _onNewTransfer,
          onGoToMainScreen: () => context.go(AppRoutes.main),
        ),
    ];
  }

  // -------------------------------------------------------------------------
  // Sub-widgets
  // -------------------------------------------------------------------------

  Widget _buildInfoCard(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Token Transfer',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Send tokens from your smart account to another Stellar address. '
              'This requires passkey authentication to sign the transaction.',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard(
    BuildContext context,
    WalletConnectionState state,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Card(
      elevation: 0,
      color: colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Balance',
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              children: [
                Text(
                  '${state.xlmBalance ?? "0.0"} XLM',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                if (state.demoTokenBalance != null)
                  Text(
                    '${state.demoTokenBalance} DEMO',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTokenDropdown(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final state = ref.read(demoStateProvider);
    final demoAvailable = state.demoTokenContractId != null;

    return DropdownButtonFormField<String>(
      value: _selectedToken,
      decoration: const InputDecoration(
        labelText: 'Token',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(
          value: TransferFlow.tokenKeyXlm,
          child: Text('XLM (Native)'),
        ),
        DropdownMenuItem(
          value: TransferFlow.tokenKeyDemo,
          enabled: demoAvailable,
          child: Text(
            'Demo Token (DEMO)',
            style: TextStyle(
              color: demoAvailable ? null : colorScheme.onSurface.withAlpha(90),
            ),
          ),
        ),
      ],
      onChanged: _isLoading
          ? null
          : (value) {
              if (value == null) return;
              setState(() {
                _selectedToken = value;
                // Reset error message on token selection change.
                _errorMessage = null;
              });
            },
    );
  }

  Widget _buildRecipientField(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final hasError =
        _recipientController.text.isNotEmpty && _recipientError != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _recipientController,
          enabled: !_isLoading,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Recipient Address',
            hintText: 'G... or C... address',
            border: const OutlineInputBorder(),
            errorText: hasError ? _recipientError : null,
            helperText: hasError ? null : 'Stellar account (G...) or contract (C...) address',
          ),
        ),
        if (hasError)
          Semantics(
            liveRegion: true,
            enabled: true,
            child: const SizedBox.shrink(),
          ),
      ],
    );
  }

  Widget _buildAmountField(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final hasError =
        _amountController.text.isNotEmpty && _amountError != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _amountController,
          enabled: !_isLoading,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Amount',
            hintText: 'e.g. 10.0',
            border: const OutlineInputBorder(),
            errorText: hasError ? _amountError : null,
            helperText: hasError ? null : 'Amount to transfer',
          ),
        ),
        if (hasError)
          Semantics(
            liveRegion: true,
            enabled: true,
            child: const SizedBox.shrink(),
          ),
      ],
    );
  }

  Widget _buildTransferButton(
    BuildContext context,
    WalletConnectionState state,
  ) {
    final isFormValid = _isFormValid();
    final kitPresent = _flow != null;
    final isEnabled = isFormValid && kitPresent && !_isLoading;

    return LoadingButton(
      label: 'Transfer',
      loadingLabel: 'Transferring...',
      enabled: isEnabled,
      isLoading: _isLoading,
      disabledHint: isFormValid
          ? null
          : 'Form is incomplete. Enter a recipient address and amount.',
      action: () => _handleTransfer(state),
    );
  }

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  bool _isFormValid() {
    final recipient = _recipientController.text;
    final amount = _amountController.text;

    if (recipient.isEmpty || amount.isEmpty) return false;
    if (_recipientError != null) return false;
    if (_amountError != null) return false;

    // For DEMO token, require the contract to be deployed.
    if (_selectedToken == TransferFlow.tokenKeyDemo) {
      final demoStateVal = ref.read(demoStateProvider);
      if (demoStateVal.demoTokenContractId == null) return false;
    }
    return true;
  }

  /// True when no signers have loaded yet, no context-rule signers exist, or
  /// the only available signer is the connected passkey. A single delegated or
  /// Ed25519 signer must use the picker so the user can pair the wallet or
  /// enter the secret key.
  bool get _shouldUseSingleSignerFastPath {
    if (!_signersLoaded || _availableSigners.isEmpty) return true;
    if (_availableSigners.length == 1) {
      final s = _availableSigners.first;
      return s.kind == SignerKind.passkey && s.isConnectedCredential;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Handlers
  // -------------------------------------------------------------------------

  Future<void> _handleTransfer(WalletConnectionState state) async {
    final flow = _flow;
    if (flow == null) {
      setState(() {
        _errorMessage = 'No wallet connected. Please connect a wallet first.';
      });
      return;
    }

    // Re-validate before proceeding.
    final recipientErr = flow.validateRecipient(_recipientController.text);
    final amountErr = TransferFlow.validateAmount(_amountController.text);
    if (recipientErr != null || amountErr != null) {
      setState(() {
        _recipientError = recipientErr;
        _amountError = amountErr;
      });
      return;
    }

    final tokenContract = flow.resolveTokenContract(_selectedToken);
    if (tokenContract == null || tokenContract.isEmpty) {
      setState(() {
        _errorMessage =
            'Demo token contract not yet deployed. '
            'Please create a wallet first.';
      });
      return;
    }

    final recipient = _recipientController.text.trim();
    final amount = _amountController.text.trim();
    final tokenLabel =
        _selectedToken == TransferFlow.tokenKeyXlm ? 'XLM' : 'DEMO';

    // Fast path is only safe when the SDK can resolve the signer without user
    // interaction (see _shouldUseSingleSignerFastPath).
    if (_shouldUseSingleSignerFastPath) {
      await _executeSingleSignerTransfer(
        flow: flow,
        tokenContract: tokenContract,
        recipient: recipient,
        amount: amount,
        tokenLabel: tokenLabel,
      );
    } else {
      // Multi-signer path: show picker.
      await _showSignerPicker(
        context: context,
        flow: flow,
        tokenContract: tokenContract,
        recipient: recipient,
        amount: amount,
        tokenLabel: tokenLabel,
        state: state,
      );
    }
  }

  Future<void> _executeSingleSignerTransfer({
    required TransferFlow flow,
    required String tokenContract,
    required String recipient,
    required String amount,
    required String tokenLabel,
  }) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final result = await flow.transfer(
        tokenContract: tokenContract,
        recipient: recipient,
        amount: amount,
        tokenLabel: tokenLabel,
      );
      if (mounted) {
        setState(() {
          _result = result;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = flow.classifyTransferError(e);
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _showSignerPicker({
    required BuildContext context,
    required TransferFlow flow,
    required String tokenContract,
    required String recipient,
    required String amount,
    required String tokenLabel,
    required WalletConnectionState state,
  }) async {
    await SignerPickerSheet.show(
      context: context,
      availableSigners: _availableSigners,
      connectedCredentialId: state.credentialId,
      validateDelegatedSecret: flow.validateDelegatedSecret,
      validateEd25519Secret: TransferFlow.validateEd25519Secret,
      walletConnector: ref.read(demoStateProvider.notifier).walletConnectorForUi,
      ed25519SigningEnabled: true,
      onConfirm: (selectedSigners, delegatedKeyPairs, ed25519Secrets) async {
        if (!mounted) return;
        setState(() {
          _isLoading = true;
          _errorMessage = null;
        });

        final builtSigners =
            await flow.buildSelectedSigners(selectedSigners);
        if (flow.isSinglePasskeyTransfer(builtSigners)) {
          // Only the connected passkey — use the fast single-signer path.
          try {
            final result = await flow.transfer(
              tokenContract: tokenContract,
              recipient: recipient,
              amount: amount,
              tokenLabel: tokenLabel,
            );
            if (mounted) {
              setState(() {
                _result = result;
                _isLoading = false;
              });
            }
          } catch (e) {
            if (mounted) {
              setState(() {
                _errorMessage = flow.classifyTransferError(e);
                _isLoading = false;
              });
            }
          }
          return;
        }

        // Multi-signer path: the flow registers both delegated and Ed25519
        // material inside a guarded region, runs the transfer, then clears all
        // registered material on every path (success, failure, cancellation).
        try {
          final result = await flow.withMultiSignerRegistration(
            delegatedKeyPairs: delegatedKeyPairs,
            ed25519Secrets: ed25519Secrets,
            body: () => flow.multiSignerTransfer(
              tokenContract: tokenContract,
              recipient: recipient,
              amount: amount,
              tokenLabel: tokenLabel,
              selectedSigners: builtSigners,
            ),
          );
          if (mounted) {
            setState(() {
              _result = result;
              _isLoading = false;
            });
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _errorMessage = flow.classifyTransferError(e);
              _isLoading = false;
            });
          }
        }
      },
    );
  }

  void _onNewTransfer() {
    setState(() {
      _result = null;
      _errorMessage = null;
      _recipientError = null;
      _amountError = null;
      _selectedToken = TransferFlow.tokenKeyXlm;
      _recipientController.clear();
      _amountController.clear();
    });
  }

}
