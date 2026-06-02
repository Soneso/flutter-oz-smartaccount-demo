/// Token allowance approval screen.
///
/// Lets the user grant a token spending allowance for another address on
/// the DEMO token contract. The smart account is the `from` party; the
/// allowance is consumed by [spenderAddress] up to [amount] until
/// [expirationLedgerOffset] ledgers in the future.
///
/// Screens-never-call-SDK rule:
/// This screen must not reference SDK kit classes or manager accessors
/// directly. Only [ApproveFlow] and [TransferFlow] call into the SDK.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flows/approve_flow.dart';
import '../flows/transfer_flow.dart'
    show Ed25519SignerIdentity, SignerInfo, SignerKind, TransferFlow;
import '../navigation/routes.dart';
import '../state/approve_flow_provider.dart';
import '../state/demo_state.dart';
import '../state/transfer_flow_provider.dart';
import '../theme/app_theme.dart' show snackBarDefaultDuration;
import '../theme/spacing.dart';
import '../util/clipboard.dart';
import '../util/error_utils.dart';
import '../util/semantic_colors.dart';
import '../widgets/error_card.dart';
import '../widgets/loading_button.dart';
import '../widgets/section_description_card.dart';
import '../widgets/signer_picker_sheet.dart';

// ---------------------------------------------------------------------------
// _ExpirationOption
// ---------------------------------------------------------------------------

/// Pre-defined ledger-offset durations for the expiration dropdown.
///
/// One ledger is approximately five seconds on Stellar testnet.
enum _ExpirationOption {
  oneDay('1 day', 17280),
  tenDays('10 days', 172800),
  thirtyDays('30 days', 518400);

  const _ExpirationOption(this.label, this.offset);

  final String label;
  final int offset;
}

// ---------------------------------------------------------------------------
// ApproveScreen
// ---------------------------------------------------------------------------

/// Dependencies are injected via the constructor so widget tests can
/// substitute mocks. In production the flows are resolved from the kit via
/// providers.
class ApproveScreen extends ConsumerStatefulWidget {
  /// Creates an [ApproveScreen].
  ///
  /// [approveFlow] and [transferFlow] are optional overrides for tests.
  /// When null (production), each flow is resolved from its Riverpod
  /// provider at action time.
  const ApproveScreen({
    this.approveFlow,
    this.transferFlow,
    super.key,
  });

  /// Optional injected [ApproveFlow] for testing.
  final ApproveFlow? approveFlow;

  /// Optional injected [TransferFlow] for testing (used for signer discovery,
  /// delegated-keypair registration, and post-submission cleanup; the screen
  /// never invokes its transfer methods).
  final TransferFlow? transferFlow;

  @override
  ConsumerState<ApproveScreen> createState() => _ApproveScreenState();
}

class _ApproveScreenState extends ConsumerState<ApproveScreen> {
  // ---- Form controllers ----

  final _spenderController = TextEditingController();
  final _amountController = TextEditingController();

  // ---- Validation state ----

  String? _spenderError;
  String? _amountError;

  // ---- Loading / submission state ----

  bool _isSubmitting = false;
  String? _errorMessage;

  // ---- Result state ----

  ApproveResult? _result;
  String? _resultAmount;
  String? _resultSpender;
  String? _currentAllowance;
  bool _allowanceLoading = false;
  bool _allowanceLoaded = false;

  /// Monotonically-increasing nonce identifying the most recently-started
  /// allowance fetch. Each call to [_initAllowanceFetch] increments the
  /// nonce and passes the new value to [_fetchAllowance]; the fetch
  /// completion handler ignores its result when the nonce has since changed
  /// (a newer fetch was started, or the screen was disposed).
  int _allowanceFetchNonce = 0;

  // ---- Multi-signer state ----

  List<SignerInfo> _availableSigners = const <SignerInfo>[];
  bool _signersLoaded = false;

  // ---- Form selection ----

  _ExpirationOption _expiration = _ExpirationOption.oneDay;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _spenderController.addListener(_onSpenderChanged);
    _amountController.addListener(_onAmountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadSigners());
    });
  }

  @override
  void dispose() {
    // Bump the nonce so any in-flight fetch noticing the change ignores its
    // own result on completion.
    _allowanceFetchNonce++;
    _spenderController
      ..removeListener(_onSpenderChanged)
      ..dispose();
    _amountController
      ..removeListener(_onAmountChanged)
      ..dispose();
    super.dispose();
  }

  /// Resolves the approve flow at action time so a kit that becomes
  /// available after this screen mounts is picked up on the next call.
  /// Tests inject the flow via [widget.approveFlow] and bypass the provider.
  ApproveFlow? _resolveApproveFlow() {
    return widget.approveFlow ?? ref.read(approveFlowProvider);
  }

  /// Resolves the transfer flow at action time (used for signer discovery
  /// and delegated keypair registration).
  TransferFlow? _resolveTransferFlow() {
    return widget.transferFlow ?? ref.read(transferFlowProvider);
  }

  void _onSpenderChanged() {
    final flow = _resolveApproveFlow();
    if (flow == null) return;
    final error = flow.validateSpender(_spenderController.text);
    setState(() {
      _spenderError = _spenderController.text.isNotEmpty ? error : null;
      _errorMessage = null;
    });
  }

  void _onAmountChanged() {
    final error = ApproveFlow.validateAmount(_amountController.text);
    setState(() {
      _amountError = _amountController.text.isNotEmpty ? error : null;
      _errorMessage = null;
    });
  }

  Future<void> _loadSigners() async {
    final flow = _resolveTransferFlow();
    if (flow == null) return;
    final signers = await flow.loadAvailableSigners();
    if (!mounted) return;
    setState(() {
      _availableSigners = signers;
      _signersLoaded = true;
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(demoStateProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Approve'),
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
            if (!state.isConnected)
              ..._buildNotConnectedBranch(context, colorScheme)
            else
              ..._buildConnectedBranch(context, state, colorScheme),
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
      Semantics(
        liveRegion: true,
        child: Card(
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
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
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
      const SectionDescriptionCard(
        title: 'Token Allowance',
        message: 'Approve a token spending allowance for another address. '
            'The spender can transfer up to the approved amount from your '
            'smart account until the allowance expires.',
      ),
      const SizedBox(height: 12),
      _buildDemoBalanceCard(context, state, colorScheme, textTheme),
      const SizedBox(height: 12),
      _buildTokenContractCard(context, state, colorScheme, textTheme),
      const SizedBox(height: 12),
      if (_result == null) ...[
        _buildSpenderField(context),
        const SizedBox(height: 12),
        _buildAmountField(context),
        const SizedBox(height: 12),
        _buildExpirationDropdown(context),
        const SizedBox(height: 12),
        if (_errorMessage != null) ...[
          ErrorCard(message: _errorMessage!),
          const SizedBox(height: 12),
        ],
        _buildApproveButton(context, state),
      ] else ...[
        _buildResultCard(context, colorScheme, textTheme),
      ],
    ];
  }

  // -------------------------------------------------------------------------
  // Sub-widgets
  // -------------------------------------------------------------------------

  Widget _buildDemoBalanceCard(
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
              'DEMO Balance',
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${state.demoTokenBalance ?? "0.0"} DEMO',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTokenContractCard(
    BuildContext context,
    WalletConnectionState state,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final contractId = state.demoTokenContractId;
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
            Text(
              'Token Contract',
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              contractId == null
                  ? 'DEMO token not deployed'
                  : 'DEMO ($contractId)',
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurface,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpenderField(BuildContext context) {
    final hasError =
        _spenderController.text.isNotEmpty && _spenderError != null;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _spenderController,
          enabled: !_isSubmitting,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Spender Address',
            hintText: 'G... or C...',
            border: const OutlineInputBorder(),
            // Surface the validation through an explicit live region below
            // the field; Material's errorText alone is not announced
            // consistently across assistive technologies.
            helperText: hasError ? null : 'Address to grant the allowance to',
            errorStyle: const TextStyle(height: 0, fontSize: 0),
            errorText: hasError ? ' ' : null,
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _spenderError!,
                style: TextStyle(
                  color: colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAmountField(BuildContext context) {
    final hasError =
        _amountController.text.isNotEmpty && _amountError != null;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _amountController,
          enabled: !_isSubmitting,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Amount',
            hintText: 'e.g. 10.0',
            border: const OutlineInputBorder(),
            errorStyle: const TextStyle(height: 0, fontSize: 0),
            errorText: hasError ? ' ' : null,
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _amountError!,
                style: TextStyle(
                  color: colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildExpirationDropdown(BuildContext context) {
    return DropdownButtonFormField<_ExpirationOption>(
      initialValue: _expiration,
      decoration: const InputDecoration(
        labelText: 'Expiration',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final option in _ExpirationOption.values)
          DropdownMenuItem(
            value: option,
            child: Semantics(
              label: option.label,
              excludeSemantics: true,
              child: Text(option.label),
            ),
          ),
      ],
      onChanged: _isSubmitting
          ? null
          : (value) {
              if (value == null) return;
              setState(() => _expiration = value);
            },
    );
  }

  Widget _buildApproveButton(
    BuildContext context,
    WalletConnectionState state,
  ) {
    final isFormValid = _isFormValid();
    final kitPresent = _resolveApproveFlow() != null;
    final tokenDeployed = state.demoTokenContractId != null;
    final enabled = isFormValid && kitPresent && !_isSubmitting;

    final String? disabledHint;
    if (enabled) {
      disabledHint = null;
    } else if (!kitPresent) {
      disabledHint = 'No wallet connected.';
    } else if (!tokenDeployed) {
      disabledHint = 'DEMO token not deployed.';
    } else {
      disabledHint =
          'Form is incomplete. Enter a spender address and amount.';
    }

    return LoadingButton(
      label: 'Approve',
      loadingLabel: 'Approving...',
      enabled: enabled,
      isLoading: _isSubmitting,
      disabledHint: disabledHint,
      action: () => _handleApprove(state),
    );
  }

  // -------------------------------------------------------------------------
  // Result card
  // -------------------------------------------------------------------------

  Widget _buildResultCard(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final hash = _result?.hash ?? '';
    final amount = _resultAmount ?? '';
    final spender = _resultSpender ?? '';

    return Card(
      elevation: 0,
      color: colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: kCardPadding,
        // Live region so the result title + rows are announced as soon as
        // the card appears after a successful approve. The inner allowance
        // row keeps its own live-region wrap so the deferred fetch update
        // is announced on its own when it resolves.
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Approve Successful',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _ResultRow(
                label: 'Transaction Hash',
                labelColor: colorScheme.onPrimaryContainer,
                child: _HashWithCopy(hash: hash),
              ),
              const SizedBox(height: 8),
              _ResultRow(
                label: 'Amount Approved',
                labelColor: colorScheme.onPrimaryContainer,
                child: Text(
                  '$amount DEMO',
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _ResultRow(
                label: 'Spender',
                labelColor: colorScheme.onPrimaryContainer,
                child: Text(
                  spender,
                  style: textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onPrimaryContainer,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 8),
              _ResultRow(
                label: 'Current Allowance',
                labelColor: colorScheme.onPrimaryContainer,
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _allowanceDisplay(),
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _onNewApprove,
                  child: const Text('New Approve'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Go to Main Screen'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _allowanceDisplay() {
    if (_allowanceLoading) return 'Loading...';
    if (!_allowanceLoaded) return 'Loading...';
    final value = _currentAllowance;
    if (value == null) return 'Unable to fetch';
    return '$value DEMO';
  }

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  bool _isFormValid() {
    if (_spenderController.text.isEmpty) return false;
    if (_amountController.text.isEmpty) return false;
    if (_spenderError != null) return false;
    if (_amountError != null) return false;
    // DEMO token must be deployed before we can approve against it.
    final state = ref.read(demoStateProvider);
    if (state.demoTokenContractId == null) return false;
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

  Future<void> _handleApprove(WalletConnectionState state) async {
    final approveFlow = _resolveApproveFlow();
    if (approveFlow == null) {
      setState(() {
        _errorMessage = 'No wallet connected. Please connect a wallet first.';
      });
      return;
    }

    // Re-validate before proceeding.
    final spenderErr = approveFlow.validateSpender(_spenderController.text);
    final amountErr = ApproveFlow.validateAmount(_amountController.text);
    if (spenderErr != null || amountErr != null) {
      setState(() {
        _spenderError = spenderErr;
        _amountError = amountErr;
      });
      return;
    }

    final tokenContract = state.demoTokenContractId;
    if (tokenContract == null) {
      setState(() {
        _errorMessage =
            'Demo token contract not yet deployed. '
            'Please create a wallet first.';
      });
      return;
    }

    final spender = _spenderController.text.trim();
    final amount = _amountController.text.trim();

    if (_shouldUseSingleSignerFastPath) {
      await _executeSingleSigner(
        flow: approveFlow,
        tokenContract: tokenContract,
        spender: spender,
        amount: amount,
      );
    } else {
      // Validation, token-deployed, and single-signer checks above include
      // `setState`/`async` work; bail out if the screen was dismissed before
      // we open the picker so we do not push a sheet onto a defunct context.
      if (!mounted) return;
      await _showSignerPicker(
        context: context,
        approveFlow: approveFlow,
        tokenContract: tokenContract,
        spender: spender,
        amount: amount,
      );
    }
  }

  Future<void> _executeSingleSigner({
    required ApproveFlow flow,
    required String tokenContract,
    required String spender,
    required String amount,
  }) async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final result = await flow.approveAllowance(
        tokenContract: tokenContract,
        spenderAddress: spender,
        amount: amount,
        expirationLedgerOffset: _expiration.offset,
      );
      if (!mounted) return;
      if (!result.success) {
        setState(() {
          _errorMessage = result.error ?? 'Approve failed.';
          _isSubmitting = false;
        });
        return;
      }
      _onApproveSuccess(
        flow: flow,
        result: result,
        amount: amount,
        spender: spender,
        tokenContract: tokenContract,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = classifyError(e, context: 'Approve failed').message;
        _isSubmitting = false;
      });
    }
  }

  Future<void> _showSignerPicker({
    required BuildContext context,
    required ApproveFlow approveFlow,
    required String tokenContract,
    required String spender,
    required String amount,
  }) async {
    final transferFlow = _resolveTransferFlow();
    if (transferFlow == null) {
      setState(() {
        _errorMessage = 'No wallet connected. Please connect a wallet first.';
      });
      return;
    }

    final notifier = ref.read(demoStateProvider.notifier);

    await SignerPickerSheet.show(
      context: context,
      availableSigners: _availableSigners,
      connectedCredentialId: ref.read(demoStateProvider).credentialId,
      validateDelegatedSecret: transferFlow.validateDelegatedSecret,
      validateEd25519Secret: TransferFlow.validateEd25519Secret,
      walletConnector: notifier.walletConnectorForUi,
      ed25519SigningEnabled: true,
      description:
          'Choose which signers co-authorize this approval. '
          'For Stellar account signers, enter the secret key to enable signing.',
      confirmLabel: 'Approve',
      onConfirm: (selectedSigners, delegatedKeyPairs, ed25519Secrets) async {
        await _onPickerConfirm(
          approveFlow: approveFlow,
          transferFlow: transferFlow,
          tokenContract: tokenContract,
          spender: spender,
          amount: amount,
          selectedSigners: selectedSigners,
          delegatedKeyPairs: delegatedKeyPairs,
          ed25519Secrets: ed25519Secrets,
        );
      },
    );
  }

  Future<void> _onPickerConfirm({
    required ApproveFlow approveFlow,
    required TransferFlow transferFlow,
    required String tokenContract,
    required String spender,
    required String amount,
    required List<SignerInfo> selectedSigners,
    required Map<String, String> delegatedKeyPairs,
    required Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
  }) async {
    // Mark submitting BEFORE any awaits so a rapid tap from elsewhere in the
    // UI cannot kick off a second confirm-cycle.
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final builtSigners =
        await transferFlow.buildSelectedSigners(selectedSigners);

    if (transferFlow.isSinglePasskeyTransfer(builtSigners)) {
      // Only the connected passkey was selected — use the fast path.
      await _executeSingleSigner(
        flow: approveFlow,
        tokenContract: tokenContract,
        spender: spender,
        amount: amount,
      );
      return;
    }

    // Multi-signer path: the flow registers both delegated and Ed25519 material
    // inside a guarded region, runs the approve, then clears all registered
    // material on every path (success, failure, cancellation).
    try {
      final result = await approveFlow.withMultiSignerRegistration(
        delegatedKeyPairs: delegatedKeyPairs,
        ed25519Secrets: ed25519Secrets,
        body: () => approveFlow.multiSignerApproveAllowance(
          tokenContract: tokenContract,
          spenderAddress: spender,
          amount: amount,
          expirationLedgerOffset: _expiration.offset,
          selectedSigners: builtSigners,
        ),
      );
      if (!mounted) return;
      if (!result.success) {
        setState(() {
          _errorMessage = result.error ?? 'Approve failed.';
          _isSubmitting = false;
        });
        return;
      }
      _onApproveSuccess(
        flow: approveFlow,
        result: result,
        amount: amount,
        spender: spender,
        tokenContract: tokenContract,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = classifyError(e, context: 'Approve failed').message;
        _isSubmitting = false;
      });
    }
  }

  void _onApproveSuccess({
    required ApproveFlow flow,
    required ApproveResult result,
    required String amount,
    required String spender,
    required String tokenContract,
  }) {
    setState(() {
      _result = result;
      _resultAmount = amount;
      _resultSpender = spender;
      _isSubmitting = false;
      _allowanceLoading = true;
      _allowanceLoaded = false;
      _currentAllowance = null;
    });

    // Bump the nonce before launching _fetchAllowance so the in-flight fetch
    // sees the current value when it does its post-await staleness check.
    final myNonce = ++_allowanceFetchNonce;
    unawaited(_fetchAllowance(
      flow: flow,
      tokenContract: tokenContract,
      spender: spender,
      nonce: myNonce,
    ));
  }

  Future<void> _fetchAllowance({
    required ApproveFlow flow,
    required String tokenContract,
    required String spender,
    required int nonce,
  }) async {
    try {
      final result = await flow.fetchAllowance(
        tokenContract: tokenContract,
        spenderAddress: spender,
      );
      if (!mounted || nonce != _allowanceFetchNonce) return;
      setState(() {
        _currentAllowance = result;
        _allowanceLoading = false;
        _allowanceLoaded = true;
      });
    } catch (_) {
      if (!mounted || nonce != _allowanceFetchNonce) return;
      setState(() {
        _currentAllowance = null;
        _allowanceLoading = false;
        _allowanceLoaded = true;
      });
    }
  }

  void _onNewApprove() {
    // Bump the nonce so any in-flight allowance fetch's completion handler
    // observes a different value and skips its setState — preventing the
    // freshly-reset form from being mutated by a stale fetch.
    _allowanceFetchNonce++;
    setState(() {
      _result = null;
      _resultAmount = null;
      _resultSpender = null;
      _currentAllowance = null;
      _allowanceLoading = false;
      _allowanceLoaded = false;
      _errorMessage = null;
      _spenderError = null;
      _amountError = null;
      _spenderController.clear();
      _amountController.clear();
      _expiration = _ExpirationOption.oneDay;
    });
  }
}

// ---------------------------------------------------------------------------
// _ResultRow
// ---------------------------------------------------------------------------

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.label,
    required this.child,
    required this.labelColor,
  });

  final String label;
  final Widget child;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.labelSmall?.copyWith(
            color: labelColor.withAlpha(200),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _HashWithCopy
// ---------------------------------------------------------------------------

class _HashWithCopy extends StatelessWidget {
  const _HashWithCopy({required this.hash});

  final String hash;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            hash,
            style: textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: colorScheme.onPrimaryContainer,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Copy transaction hash',
          onPressed: () => unawaited(_handleCopy(context)),
          visualDensity: VisualDensity.compact,
          icon: Icon(
            Icons.copy_outlined,
            size: 18,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ],
    );
  }

  Future<void> _handleCopy(BuildContext context) async {
    await copyTxHash(hash);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Transaction hash copied'),
        duration: snackBarDefaultDuration,
      ),
    );
    await SemanticsService.announce(
      'Transaction hash copied',
      Directionality.of(context),
    );
  }
}
