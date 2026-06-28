/// Delegate-to-agent screen (step 2 of the agent-signer flow).
///
/// Grants an autonomous agent a scoped, spend-capped, time-bounded authority
/// on the connected smart account by composing ONE `addContextRule` call:
/// `CallContract(token)` scope + an Ed25519 external signer (the agent's
/// pasted public key) + a spending-limit policy + a `validUntil` bound. The
/// agent owns the matching secret; only its public key is entered here.
///
/// Screens-never-call-SDK rule:
/// This screen must not reference SDK kit classes or manager accessors
/// directly. Only [DelegateToAgentFlow] (via [ContextRuleFlow]) calls the SDK.
///
/// State machine:
/// - Not Connected: "No wallet connected" card.
/// - Editing:       Form (agent key, token, cap, expiry) + submit.
/// - Submitting:    Disable form, spinner inside the primary CTA.
/// - Success:       Confirmation card summarising the authorised rule.
/// - Failure:       Error card; the form remains for retry.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/demo_config.dart' as config;
import '../flows/context_rule_flow.dart' show ledgersPerDay, ledgersPerHour;
import '../flows/delegate_to_agent_flow.dart';
import '../navigation/routes.dart';
import '../state/delegate_to_agent_flow_provider.dart';
import '../state/demo_state.dart';
import '../state/demo_token_service_provider.dart';
import '../theme/spacing.dart';
import '../util/clipboard.dart';
import '../util/error_utils.dart' show classifyError;
import '../util/format_utils.dart' show truncateAddress;
import '../widgets/error_card.dart';
import '../widgets/key_value_row.dart';
import '../widgets/loading_button.dart';
import '../widgets/rich_dropdown_item.dart';
import '../widgets/section_description_card.dart';

// ---------------------------------------------------------------------------
// Form option enums
// ---------------------------------------------------------------------------

/// Spending-limit rolling-window presets, in ledgers.
///
/// One ledger is approximately five seconds on Stellar testnet.
enum _PeriodOption {
  oneHour('Per hour', ledgersPerHour),
  oneDay('Per day', ledgersPerDay),
  sevenDays('Per 7 days', ledgersPerDay * 7),
  thirtyDays('Per 30 days', ledgersPerDay * 30);

  const _PeriodOption(this.label, this.ledgers);

  final String label;
  final int ledgers;
}

/// Rule-expiry (`validUntil`) presets, expressed as a ledger offset from the
/// current ledger.
enum _ExpiryOption {
  oneDay('1 day (~24h)', ledgersPerDay),
  threeDays('3 days', ledgersPerDay * 3),
  sevenDays('7 days', ledgersPerDay * 7),
  thirtyDays('30 days', ledgersPerDay * 30);

  const _ExpiryOption(this.label, this.offset);

  final String label;
  final int offset;
}

// ---------------------------------------------------------------------------
// DelegateToAgentScreen
// ---------------------------------------------------------------------------

/// Delegate-to-agent screen.
///
/// [flow] is an optional injected [DelegateToAgentFlow] for testing. When null
/// (production), the screen resolves the flow from
/// [delegateToAgentFlowProvider].
class DelegateToAgentScreen extends ConsumerStatefulWidget {
  /// Creates a [DelegateToAgentScreen].
  const DelegateToAgentScreen({this.flow, super.key});

  /// Optional injected [DelegateToAgentFlow] for testing.
  final DelegateToAgentFlow? flow;

  @override
  ConsumerState<DelegateToAgentScreen> createState() =>
      _DelegateToAgentScreenState();
}

class _DelegateToAgentScreenState
    extends ConsumerState<DelegateToAgentScreen> {
  // ---- Flow ----

  DelegateToAgentFlow? _flow;

  // ---- Form controllers ----

  final TextEditingController _agentKeyController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();

  // ---- Validation state ----

  String? _agentKeyError;
  String? _amountError;

  // ---- Form selection ----

  _PeriodOption _period = _PeriodOption.oneDay;
  _ExpiryOption _expiry = _ExpiryOption.oneDay;

  // ---- Token decimals resolution ----

  int _tokenDecimals = config.demoTokenDecimals;

  /// Monotonic token guarding against a stale late decimals response
  /// overwriting a newer resolution.
  int _decimalsRequestToken = 0;

  // ---- Submission / result state ----

  bool _isSubmitting = false;
  String? _errorMessage;
  DelegationResult? _result;
  _PeriodOption? _resultPeriod;
  _ExpiryOption? _resultExpiry;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _flow = widget.flow ?? ref.read(delegateToAgentFlowProvider);

    // Default the token field to the demo token address (its deployed id when
    // known, otherwise the deterministic derived address) so it is pre-filled.
    _tokenController.text = ref.read(demoTokenAddressProvider);

    _agentKeyController.addListener(_onAgentKeyChanged);
    _tokenController.addListener(_onTokenChanged);
    _amountController.addListener(_onAmountChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_resolveTokenDecimals());
    });
  }

  @override
  void dispose() {
    // Bump the decimals nonce so any in-flight resolution ignores its result.
    _decimalsRequestToken++;
    _agentKeyController
      ..removeListener(_onAgentKeyChanged)
      ..dispose();
    _tokenController
      ..removeListener(_onTokenChanged)
      ..dispose();
    _amountController
      ..removeListener(_onAmountChanged)
      ..dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Field change handlers
  // -------------------------------------------------------------------------

  void _onAgentKeyChanged() {
    final flow = _flow;
    final error = flow?.validateAgentPublicKey(_agentKeyController.text);
    setState(() {
      _agentKeyError = _agentKeyController.text.isNotEmpty ? error : null;
      _errorMessage = null;
    });
  }

  void _onTokenChanged() {
    // The token comes from a fixed dropdown of known-valid contracts, so there
    // is no address to validate; clear any prior submit error and re-resolve
    // the selected token's decimal scale for the cap conversion.
    setState(() {
      _errorMessage = null;
    });
    unawaited(_resolveTokenDecimals());
  }

  void _onAmountChanged() {
    final error = DelegateToAgentFlow.validateAmount(_amountController.text);
    setState(() {
      _amountError = _amountController.text.isNotEmpty ? error : null;
      _errorMessage = null;
    });
  }

  /// Resolves the guarded token's decimal scale for the cap conversion.
  ///
  /// The native token and invalid addresses resolve without a network call; a
  /// custom token's `decimals()` is fetched on-chain. A monotonic token guards
  /// against a stale late response overwriting a newer resolution. A failure
  /// leaves the previously resolved value in place (defaulting to the demo
  /// token scale) rather than blocking the form.
  Future<void> _resolveTokenDecimals() async {
    final flow = _flow;
    if (flow == null) return;
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;
    final requestToken = ++_decimalsRequestToken;
    try {
      final resolved = await flow.resolveTokenDecimals(token);
      if (!mounted || requestToken != _decimalsRequestToken) return;
      setState(() => _tokenDecimals = resolved);
    } catch (_) {
      // Non-fatal: keep the current scale; the submit path surfaces any real
      // conversion error from the SDK with the resolved precision.
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(demoStateProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Delegate to Agent'),
        centerTitle: false,
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
            if (!state.isConnected || _flow == null)
              ..._buildNotConnectedBranch()
            else
              ..._buildConnectedBranch(colorScheme, textTheme),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Not-connected branch
  // -------------------------------------------------------------------------

  List<Widget> _buildNotConnectedBranch() {
    return [
      const SectionDescriptionCard(
        title: 'Delegate to an Agent',
        message:
            'Authorise an autonomous agent to act within a scoped, spend-capped, '
            'time-bounded rule on this smart account.',
        tint: SectionDescriptionTint.primary,
      ),
      const SizedBox(height: 16),
      const Card(
        elevation: 0,
        child: Padding(
          padding: kCardPadding,
          child: Text(
            'No wallet connected. Connect a wallet to delegate to an agent.',
          ),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: () => popOrGoMain(context),
          child: const Text('Go Back'),
        ),
      ),
    ];
  }

  // -------------------------------------------------------------------------
  // Connected branch
  // -------------------------------------------------------------------------

  List<Widget> _buildConnectedBranch(
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    if (_result != null) {
      return [_buildResultCard(colorScheme, textTheme)];
    }

    return [
      const SectionDescriptionCard(
        title: 'Delegate to an Agent',
        message:
            'Register an agent as an Ed25519 external signer in one context '
            'rule: scoped to a single token contract, capped by a spending '
            'limit, and expiring after a set time. The agent holds its own '
            'secret; paste only its public key (64-char hex).',
        tint: SectionDescriptionTint.primary,
      ),
      const SizedBox(height: 16),
      _buildAgentKeyField(),
      const SizedBox(height: 12),
      _buildTokenField(),
      const SizedBox(height: 12),
      _buildAmountField(),
      const SizedBox(height: 12),
      _buildPeriodDropdown(),
      const SizedBox(height: 12),
      _buildExpiryDropdown(),
      const SizedBox(height: 16),
      if (_errorMessage != null) ...[
        ErrorCard(message: _errorMessage!),
        const SizedBox(height: 12),
      ],
      _buildSubmitButton(),
    ];
  }

  // -------------------------------------------------------------------------
  // Form fields
  // -------------------------------------------------------------------------

  Widget _buildAgentKeyField() {
    final hasError =
        _agentKeyController.text.isNotEmpty && _agentKeyError != null;
    return _FieldColumn(
      error: hasError ? _agentKeyError : null,
      child: TextField(
        controller: _agentKeyController,
        enabled: !_isSubmitting,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: 'Agent Ed25519 Public Key (hex)',
          hintText: '64 hex characters',
          border: const OutlineInputBorder(),
          helperText: hasError
              ? null
              : "The agent's Ed25519 public key in hex (printed on its startup line)",
          errorStyle: const TextStyle(height: 0, fontSize: 0),
          errorText: hasError ? ' ' : null,
        ),
      ),
    );
  }

  Widget _buildTokenField() {
    final demoTokenAddress = ref.watch(demoTokenAddressProvider);
    final options = <_TokenOption>[
      _TokenOption('Demo Token Contract', demoTokenAddress),
      const _TokenOption('XLM Native Contract', config.nativeTokenContract),
    ];
    final current = _tokenController.text.trim();
    final dropdownValue =
        options.any((o) => o.address == current) ? current : null;

    return DropdownButtonFormField<String>(
      initialValue: dropdownValue,
      decoration: const InputDecoration(
        labelText: 'Token Contract',
        border: OutlineInputBorder(),
        helperText:
            'The only token the agent may call (defaults to the demo token)',
      ),
      selectedItemBuilder: (_) => [
        for (final o in options)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(o.label),
          ),
      ],
      items: [
        for (final o in options)
          DropdownMenuItem<String>(
            value: o.address,
            child: Semantics(
              label: '${o.label}. Contract address ${o.address}',
              excludeSemantics: true,
              child: RichDropdownItem(
                title: o.label,
                subtitle: truncateAddress(o.address, chars: 8),
              ),
            ),
          ),
      ],
      onChanged: _isSubmitting
          ? null
          : (v) {
              if (v != null) _tokenController.text = v;
            },
    );
  }

  Widget _buildAmountField() {
    final hasError =
        _amountController.text.isNotEmpty && _amountError != null;
    return _FieldColumn(
      error: hasError ? _amountError : null,
      child: TextField(
        controller: _amountController,
        enabled: !_isSubmitting,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Spending Limit',
          hintText: 'e.g. 100.0',
          border: const OutlineInputBorder(),
          helperText:
              hasError ? null : 'Maximum the agent may spend per period',
          errorStyle: const TextStyle(height: 0, fontSize: 0),
          errorText: hasError ? ' ' : null,
        ),
      ),
    );
  }

  Widget _buildPeriodDropdown() {
    return DropdownButtonFormField<_PeriodOption>(
      initialValue: _period,
      decoration: const InputDecoration(
        labelText: 'Spending Limit Period',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final option in _PeriodOption.values)
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
              setState(() => _period = value);
            },
    );
  }

  Widget _buildExpiryDropdown() {
    return DropdownButtonFormField<_ExpiryOption>(
      initialValue: _expiry,
      decoration: const InputDecoration(
        labelText: 'Rule Expires In',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final option in _ExpiryOption.values)
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
              setState(() => _expiry = value);
            },
    );
  }

  Widget _buildSubmitButton() {
    final enabled = _isFormValid() && !_isSubmitting;
    return LoadingButton(
      label: 'Delegate to Agent',
      loadingLabel: 'Submitting (requires authorization)...',
      enabled: enabled,
      isLoading: _isSubmitting,
      disabledHint: enabled
          ? null
          : 'Enter the agent public key, token contract, and spending limit.',
      action: _handleSubmit,
    );
  }

  // -------------------------------------------------------------------------
  // Result card
  // -------------------------------------------------------------------------

  Widget _buildResultCard(ColorScheme colorScheme, TextTheme textTheme) {
    final summary = _result?.summary;
    final hash = _result?.hash ?? '';
    final period = _resultPeriod ?? _period;
    final expiry = _resultExpiry ?? _expiry;

    return Card(
      elevation: 0,
      color: colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Agent Authorised',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'The agent can now sign calls to the scoped token, up to the '
                'spending cap, until the rule expires.',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 12),
              if (summary != null) ...[
                KeyValueRow.text(
                  label: 'Agent Key',
                  value: summary.agentPublicKey,
                  monospace: true,
                ),
                const KeyValueRow.text(
                  label: 'Scope',
                  value: 'CallContract',
                ),
                KeyValueRow(
                  label: 'Token Contract',
                  value: _ValueWithCopy(
                    value: summary.tokenContract,
                    tooltip: 'Copy token contract address',
                    snackbarMessage: 'Token contract address copied',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Start the reference agent with this token contract '
                    '(AGENT_TOKEN_CONTRACT).',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                KeyValueRow.text(
                  label: 'Cap',
                  value: '${summary.amount} ${period.label.toLowerCase()}',
                  emphasised: true,
                ),
                KeyValueRow.text(
                  label: 'Expires',
                  value: summary.validUntilLedger == null
                      ? 'Never'
                      : 'Ledger ${summary.validUntilLedger} (${expiry.label})',
                ),
                KeyValueRow.text(
                  label: 'Verifier',
                  value: truncateAddress(summary.verifierAddress),
                  monospace: true,
                ),
                KeyValueRow.text(
                  label: 'Policy',
                  value: truncateAddress(summary.spendingLimitPolicyAddress),
                  monospace: true,
                ),
              ],
              const SizedBox(height: 8),
              KeyValueRow(
                label: 'Tx Hash',
                value: _ValueWithCopy(
                  value: hash,
                  tooltip: 'Copy transaction hash',
                  snackbarMessage: 'Transaction hash copied',
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => popOrGoMain(context),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Validation + submit
  // -------------------------------------------------------------------------

  bool _isFormValid() {
    if (_flow == null) return false;
    if (_agentKeyController.text.trim().isEmpty) return false;
    if (_agentKeyError != null) return false;
    if (_tokenController.text.trim().isEmpty) return false;
    if (_amountController.text.trim().isEmpty) return false;
    if (_amountError != null) return false;
    return true;
  }

  Future<void> _handleSubmit() async {
    final flow = _flow;
    if (flow == null) {
      setState(() => _errorMessage = 'No wallet connected.');
      return;
    }

    // Re-validate every field before submitting. The token comes from a fixed
    // dropdown of known-valid contracts, so only the agent key and amount need
    // re-validation.
    final agentKeyError = flow.validateAgentPublicKey(_agentKeyController.text);
    final amountError =
        DelegateToAgentFlow.validateAmount(_amountController.text);
    final token = _tokenController.text.trim();
    if (agentKeyError != null || amountError != null) {
      setState(() {
        _agentKeyError = agentKeyError;
        _amountError = amountError;
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final result = await flow.delegateToAgent(
        agentPublicKey: _agentKeyController.text,
        tokenContract: token,
        amount: _amountController.text.trim(),
        periodLedgers: _period.ledgers,
        validUntilOffsetLedgers: _expiry.offset,
        tokenDecimals: _tokenDecimals,
      );
      if (!mounted) return;
      if (!result.success) {
        setState(() {
          _errorMessage = result.error ?? 'Delegation failed.';
          _isSubmitting = false;
        });
        return;
      }
      setState(() {
        _result = result;
        _resultPeriod = _period;
        _resultExpiry = _expiry;
        _isSubmitting = false;
      });
      unawaited(SemanticsService.announce(
        'Agent authorised',
        Directionality.of(context),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            classifyError(e, context: 'Delegation failed').message;
        _isSubmitting = false;
      });
    }
  }
}

// ---------------------------------------------------------------------------
// _FieldColumn
// ---------------------------------------------------------------------------

/// A form field with an inline, screen-reader-announced error row below it.
class _FieldColumn extends StatelessWidget {
  const _FieldColumn({required this.child, this.error});

  final Widget child;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error!,
                style: TextStyle(color: colorScheme.error, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TokenOption
// ---------------------------------------------------------------------------

/// A selectable token-contract option (label plus contract address) for the
/// Token Contract dropdown.
class _TokenOption {
  const _TokenOption(this.label, this.address);

  final String label;
  final String address;
}

// ---------------------------------------------------------------------------
// _ValueWithCopy
// ---------------------------------------------------------------------------

/// A monospace value paired with a copy-to-clipboard affordance, styled for
/// the `primaryContainer` result card.
class _ValueWithCopy extends StatelessWidget {
  const _ValueWithCopy({
    required this.value,
    required this.tooltip,
    required this.snackbarMessage,
  });

  /// The full value shown in the row and written to the clipboard on copy.
  final String value;

  /// Tooltip and accessibility label for the copy button.
  final String tooltip;

  /// Snackbar message shown after a successful copy.
  final String snackbarMessage;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              value,
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
            tooltip: tooltip,
            onPressed: () => unawaited(
              copyAndToast(
                context,
                value,
                message: snackbarMessage,
                announce: true,
              ),
            ),
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.copy_outlined,
              size: 18,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
