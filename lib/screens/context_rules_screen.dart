/// Context-rules screen.
///
/// Displays all on-chain context rules for the connected smart account.
/// Allows the user to expand each rule to view signers and policies, and
/// to remove a rule (with last-rule safety check and optional multi-signer
/// authorization).
///
/// Screens-never-call-SDK rule:
/// This screen must not reference SDK kit classes or manager accessors
/// directly. Only [ContextRuleFlow] calls into the SDK.
///
/// State machine:
/// - Not Connected: "No wallet connected" card.
/// - Loading: spinner with "Loading context rules..." label.
/// - Removing: spinner with progress label.
/// - Error: error card with Refresh button to retry.
/// - Empty: "No context rules found" card.
/// - Loaded: scrollable list of [ContextRuleCard] widgets.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../flows/context_rule_builder_types.dart'
    show OZParsedContextRule, OZSelectedSigner;

import '../flows/context_rule_flow.dart';
import '../flows/signer_info.dart' show Ed25519SignerIdentity, SignerInfo;
import '../navigation/routes.dart';
import '../state/context_rule_flow_provider.dart';
import '../state/demo_state.dart';
import '../theme/spacing.dart';
import '../util/error_utils.dart';
import '../widgets/context_rule_card.dart';
import '../widgets/empty_state_card.dart';
import '../widgets/error_card.dart';
import '../widgets/loading_button.dart';
import '../widgets/loading_label.dart';
import '../widgets/remove_context_rule_dialog.dart';
import '../widgets/section_description_card.dart';
import '../widgets/signer_picker_sheet.dart';

// ---------------------------------------------------------------------------
// ContextRulesScreen
// ---------------------------------------------------------------------------

/// Context-rules screen.
///
/// [flow] is an optional injected [ContextRuleFlow] for testing. When null
/// (production), the screen resolves a flow from [contextRuleFlowProvider].
class ContextRulesScreen extends ConsumerStatefulWidget {
  /// Creates a [ContextRulesScreen].
  const ContextRulesScreen({this.flow, super.key});

  /// Optional injected [ContextRuleFlow] for testing.
  final ContextRuleFlow? flow;

  @override
  ConsumerState<ContextRulesScreen> createState() => _ContextRulesScreenState();
}

class _ContextRulesScreenState extends ConsumerState<ContextRulesScreen> {
  // ---- Flow (cached once in initState) ----

  ContextRuleFlow? _flow;

  // ---- Rule list state ----

  List<OZParsedContextRule> _rules = const <OZParsedContextRule>[];
  bool _isLoading = false;
  String? _errorMessage;

  // ---- Expand state ----

  int? _expandedRuleId;

  // ---- Removal state ----

  bool _isRemoving = false;
  int? _removingRuleId;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _flow = widget.flow ?? ref.read(contextRuleFlowProvider);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_loadRules()),
    );
  }

  // -------------------------------------------------------------------------
  // Load rules
  // -------------------------------------------------------------------------

  Future<void> _loadRules() async {
    final flow = _flow;
    if (flow == null) {
      // The screen falls back to the not-connected branch when the flow is
      // unavailable (e.g. the user reached this route before completing
      // wallet connection). No additional error text is needed; the
      // [_NotConnectedCard] branch renders the standard prompt.
      setState(() {
        _errorMessage = null;
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final rules = await flow.listContextRules();
      if (mounted) {
        setState(() {
          _rules = rules;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = classifyError(e).message;
          _isLoading = false;
        });
      }
    }
  }

  // -------------------------------------------------------------------------
  // Edit rule
  // -------------------------------------------------------------------------

  Future<void> _onEditTap(OZParsedContextRule rule) async {
    final result = await context.push<bool>(
      '${AppRoutes.contextRuleBuilder}'
      '?${AppRoutes.editRuleIdParam}=${rule.id}',
    );
    if (!mounted) return;
    // Refresh when the builder explicitly signals a completed edit
    // (`maybePop(true)`). When the user backs out without applying changes
    // (`null` return) the cached list is still accurate and a refresh
    // would only generate redundant network traffic.
    if (result == true) {
      await _loadRules();
    }
  }

  // -------------------------------------------------------------------------
  // Remove rule
  // -------------------------------------------------------------------------

  Future<void> _onRemoveTap(OZParsedContextRule rule) async {
    final flow = _flow;
    if (flow == null || _isRemoving) return;

    final canRemove = _rules.length > 1;

    final confirmed = await RemoveContextRuleDialog.show(
      context: context,
      rule: rule,
      canRemove: canRemove,
    );

    if (!confirmed || !mounted) return;

    // Load signers for multi-signer check. A failure to load means we cannot
    // safely route through the single-signer fast path, so surface the
    // error and abort.
    final result = await flow.loadAvailableSigners();
    if (!mounted) return;

    if (!result.isSuccess) {
      setState(() {
        _errorMessage = result.error?.message ??
            'Could not load signers for this account.';
      });
      return;
    }

    final availableSigners = result.signers;

    // If there is only the connected passkey (single-signer path), remove
    // directly without the picker.
    if (availableSigners.length <= 1) {
      await _executeRemoval(rule.id, const <OZSelectedSigner>[]);
      return;
    }

    // Multi-signer path — show the signer picker.
    await SignerPickerSheet.show(
      context: context,
      availableSigners: availableSigners,
      connectedCredentialId: ref.read(demoStateProvider).credentialId,
      validateDelegatedSecret: flow.validateDelegatedSecret,
      validateEd25519Secret: ContextRuleFlow.validateEd25519Secret,
      walletConnector: ref.read(demoStateProvider.notifier).walletConnectorForUi,
      ed25519SigningEnabled: true,
      title: 'Select Signers',
      description: 'Choose which signers co-authorize removing this context '
          'rule. For Stellar account signers, enter the secret key to enable '
          'signing.',
      onConfirm: (selectedSigners, delegatedKeyPairs, ed25519Secrets) {
        unawaited(_onSignerPickerConfirm(
          rule: rule,
          selectedSigners: selectedSigners,
          delegatedKeyPairs: delegatedKeyPairs,
          ed25519Secrets: ed25519Secrets,
          flow: flow,
        ));
      },
    );
  }

  /// Picker-confirm handler.
  ///
  /// Invariant: this method must always perform the operations in the order
  /// `register delegated keys → register Ed25519 keys → execute removal →
  /// clear delegated keys`, and must always reach the cleanup
  /// `clearDelegatedKeypairs` call regardless of whether the screen is still
  /// mounted by the time the removal resolves.
  /// [ContextRuleFlow.withMultiSignerRegistration] owns that order: it
  /// registers both key sets inside a guarded region and guarantees the cleanup
  /// runs even when registration or removal throws, or when the picker sheet
  /// has dismissed (and the parent screen torn down) between registration and
  /// the completion of `_executeRemoval`, so key material never lingers in
  /// memory.
  Future<void> _onSignerPickerConfirm({
    required OZParsedContextRule rule,
    required List<SignerInfo> selectedSigners,
    required Map<String, String> delegatedKeyPairs,
    required Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
    required ContextRuleFlow flow,
  }) async {
    try {
      await flow.withMultiSignerRegistration(
        delegatedKeyPairs: delegatedKeyPairs,
        ed25519Secrets: ed25519Secrets,
        body: () async {
          final selected = await flow.buildSelectedSigners(selectedSigners);
          if (flow.isSinglePasskeyRemoval(selected)) {
            await _executeRemoval(rule.id, const <OZSelectedSigner>[]);
          } else {
            await _executeRemoval(rule.id, selected);
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = classifyError(e).message;
        });
      }
    }
  }

  Future<void> _executeRemoval(
    int ruleId,
    List<OZSelectedSigner> selectedSigners,
  ) async {
    final flow = _flow;
    if (flow == null) return;

    setState(() {
      _isRemoving = true;
      _removingRuleId = ruleId;
      _errorMessage = null;
    });

    try {
      await flow.removeContextRule(
        ruleId: ruleId,
        selectedSigners: selectedSigners,
        currentRuleCount: _rules.length,
      );
      if (mounted) {
        setState(() {
          _isRemoving = false;
          _removingRuleId = null;
          _expandedRuleId = null;
        });
        await _loadRules();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRemoving = false;
          _removingRuleId = null;
          _errorMessage = flow.classifyRemovalError(e);
        });
      }
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(demoStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Context Rules'),
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => popOrGoMain(context),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _loadRules,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: kCardPadding,
              sliver: SliverList(
                delegate: SliverChildListDelegate(
                  _buildBody(context, connectionState),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBody(
    BuildContext context,
    WalletConnectionState state,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    // Description card — always shown.
    const descriptionCard = SectionDescriptionCard(
      title: 'On-Chain Authorization Rules',
      message:
          'Context rules define who can authorize what operations on this '
          'smart account. Each rule specifies signers and policies that '
          'control access for a given context type.',
      tint: SectionDescriptionTint.primary,
    );

    if (!state.isConnected || _flow == null) {
      return [
        descriptionCard,
        const SizedBox(height: 16),
        const EmptyStateCard(
          icon: Icons.account_balance_wallet_outlined,
          title: 'No wallet connected',
          message: 'Connect a wallet to view context rules.',
        ),
        const SizedBox(height: 40),
      ];
    }

    return [
      descriptionCard,
      const SizedBox(height: 16),

      // Refresh / Add Rule action row.
      _ActionRow(
        isLoading: _isLoading,
        onRefresh: _loadRules,
        onAddRule: () async {
          final result =
              await context.push<bool>(AppRoutes.contextRuleBuilder);
          if (!mounted) return;
          // Refresh on return so a newly created rule appears immediately.
          if (result == true || result == null) {
            await _loadRules();
          }
        },
      ),
      const SizedBox(height: 8),

      // Delegate to agent — composes one scoped, spend-capped, time-bounded
      // context rule that registers an autonomous agent as an Ed25519 external
      // signer. Lives alongside "Add Rule" as a guided shortcut.
      _DelegateToAgentButton(
        enabled: !_isLoading,
        onPressed: () async {
          await context.push<void>(AppRoutes.delegateToAgent);
          if (!mounted) return;
          // Refresh on return so a newly delegated rule appears immediately.
          await _loadRules();
        },
      ),
      const SizedBox(height: 12),

      // Error card.
      if (_errorMessage != null) ...[
        ErrorCard(message: _errorMessage!),
        const SizedBox(height: 12),
      ],

      // Removing progress.
      if (_isRemoving) ...[
        Semantics(
          liveRegion: true,
          label: 'Removing context rule (requires authorization)...',
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Removing context rule (requires authorization)...',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],

      // Loading spinner (only when loading and no cached rules).
      if (_isLoading && _rules.isEmpty) ...[
        Semantics(
          liveRegion: true,
          label: 'Loading context rules',
          child: LoadingLabel(
            label: 'Loading context rules...',
            color: colorScheme.primary,
            size: 18,
            gap: 10,
            textStyle: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],

      // Empty state — suppressed during in-flight removal so the empty card
      // does not flash between "successful removal" and "list reloaded".
      if (!_isLoading &&
          !_isRemoving &&
          _errorMessage == null &&
          _rules.isEmpty) ...[
        const EmptyStateCard(
          icon: Icons.shield_outlined,
          title: 'No context rules found',
          message:
              'This wallet may use a default configuration, or rules may '
              'not have been created yet.',
        ),
        const SizedBox(height: 12),
      ],

      // Rule count summary.
      if (_rules.isNotEmpty) ...[
        Text(
          '${_rules.length} context rule(s) loaded',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),

        // Rule list.
        for (final OZParsedContextRule rule in _rules) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContextRuleCard(
              rule: rule,
              isExpanded: _expandedRuleId == rule.id,
              onToggleExpanded: () {
                setState(() {
                  _expandedRuleId =
                      _expandedRuleId == rule.id ? null : rule.id;
                });
              },
              canRemove: _rules.length > 1,
              isRemoving: _isRemoving && _removingRuleId == rule.id,
              onRemove: _isRemoving ? null : () => unawaited(_onRemoveTap(rule)),
              onEdit: _isRemoving
                  ? null
                  : () => unawaited(_onEditTap(rule)),
            ),
          ),
        ],
      ],

      const SizedBox(height: 40),
    ];
  }
}

// ---------------------------------------------------------------------------
// Private sub-widgets
// ---------------------------------------------------------------------------

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.isLoading,
    required this.onRefresh,
    required this.onAddRule,
  });

  final bool isLoading;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onAddRule;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: LoadingButton(
            label: 'Refresh',
            loadingLabel: 'Loading...',
            style: LoadingButtonStyle.outlined,
            action: onRefresh,
            enabled: !isLoading,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LoadingButton(
            label: '+ Add Rule',
            action: onAddRule,
            enabled: !isLoading,
            disabledHint: isLoading
                ? 'Loading context rules. Try again once the list is ready.'
                : null,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _DelegateToAgentButton
// ---------------------------------------------------------------------------

class _DelegateToAgentButton extends StatelessWidget {
  const _DelegateToAgentButton({
    required this.enabled,
    required this.onPressed,
  });

  final bool enabled;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled ? () => unawaited(onPressed()) : null,
        icon: const Icon(Icons.smart_toy_outlined, size: 18),
        label: const Text('Delegate to Agent'),
      ),
    );
  }
}

