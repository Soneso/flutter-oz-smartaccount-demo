/// Wallet connection screen.
///
/// Guides the user through connecting to an existing smart account wallet via
/// one of four strategies. All SDK interaction is delegated to
/// [WalletConnectionFlow]; this widget only manages form state and the UI
/// response to flow outcomes.
///
/// Screens-never-call-SDK rule:
/// This file must not reference SDK kit classes or manager accessors directly.
/// Only [WalletConnectionFlow] calls into the SDK.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../flows/context_rule_builder_types.dart'
    show StoredCredential, WebAuthnCancelled;
import '../flows/wallet_connection_flow.dart';
import '../navigation/routes.dart';
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../state/main_screen_flow_provider.dart';
import '../theme/spacing.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import '../util/semantic_colors.dart';
import '../widgets/contract_picker_sheet.dart';
import '../widgets/inline_error_banner.dart';
import '../widgets/loading_button.dart';
import '../widgets/pending_credential_card.dart';
import '../widgets/styled_text_field.dart';

// ---------------------------------------------------------------------------
// WalletConnectionScreen
// ---------------------------------------------------------------------------

/// Screen for connecting to an existing smart account wallet.
///
/// The screen drives [WalletConnectionFlow], which owns all SDK interactions.
/// This widget reads from [DemoStateNotifier] and [ActivityLogNotifier] via
/// Riverpod and never calls the SDK directly.
///
/// Four always-visible sections (stacked):
/// - Section A: Auto Connect (session restore with WebAuthn fallback).
/// - Section B: Connect via Indexer (WebAuthn then indexer lookup).
/// - Section C: Connect with Address (WebAuthn then direct contract address).
/// - Section D: Pending Deployments (conditional — shown when list is non-empty).
///
/// State:
/// - [_activeSection] tracks which section is in-flight (only one at a time).
/// - When a section is in-flight, all other section buttons are disabled.
/// - All buttons are disabled when no kit is present.
///
/// Dependencies:
/// [WalletConnectionFlow] is injected via the constructor so widget tests can
/// substitute mocks. In production the flow is resolved from the active kit.
class WalletConnectionScreen extends ConsumerStatefulWidget {
  /// Creates a [WalletConnectionScreen].
  ///
  /// [flow] is the optional injected flow. When null (production), the screen
  /// resolves a flow from the active kit at action time.
  const WalletConnectionScreen({
    this.flow,
    super.key,
  });

  /// Optional injected [WalletConnectionFlow] for testing.
  final WalletConnectionFlow? flow;

  @override
  ConsumerState<WalletConnectionScreen> createState() =>
      _WalletConnectionScreenState();
}

class _WalletConnectionScreenState
    extends ConsumerState<WalletConnectionScreen> {
  // ---- Form state (Section C) ----

  final _addressController = TextEditingController();
  String? _addressFieldError;

  // ---- Connection section state ----

  ConnectionSection? _activeSection;

  // ---- Per-section inline errors ----

  String? _autoError;
  String? _indexerError;
  String? _addressError;

  // ---- Pending credentials ----

  List<StoredCredential> _pendingCredentials = const [];

  /// Per-credential deployment error keyed by credentialId.
  final Map<String, String> _pendingErrors = {};

  /// credentialId currently being deployed (for per-card spinner).
  String? _deployingCredentialId;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _addressController.addListener(_onAddressChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPendingCredentials());
  }

  @override
  void dispose() {
    _addressController.removeListener(_onAddressChanged);
    _addressController.dispose();
    super.dispose();
  }

  void _onAddressChanged() {
    final v = _addressController.text;
    final err = v.isNotEmpty && !isValidContractAddress(v)
        ? 'Must be a valid Stellar contract address (C...)'
        : null;
    // Always rebuild so that the Section C Connect button's enabled state
    // (which reads _addressController.text directly) reflects the current value.
    setState(() => _addressFieldError = err);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // When a flow is injected (test mode), treat the kit as present so all
    // buttons are interactive regardless of DemoState.kit.
    // Watch isConnected so the UI rebuilds when the connection state changes.
    // Kit presence is checked via the notifier (kit is a plain field, not
    // part of the observable WalletConnectionState slice).
    final isConnected = ref.watch(demoStateProvider.select((s) => s.isConnected));
    final kitPresent =
        widget.flow != null ||
        isConnected ||
        ref.read(demoStateProvider.notifier).hasKit;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Wallet'),
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
            _buildSectionA(context, kitPresent: kitPresent),
            const SizedBox(height: 16),
            _buildSectionB(context, kitPresent: kitPresent),
            const SizedBox(height: 16),
            _buildSectionC(context, kitPresent: kitPresent),
            if (_pendingCredentials.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildSectionD(context, kitPresent: kitPresent),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Section A: Auto Connect
  // -------------------------------------------------------------------------

  Widget _buildSectionA(BuildContext context, {required bool kitPresent}) {
    final disabled = _activeSection != null || !kitPresent;
    return _buildCard(
      context,
      title: 'Auto Connect',
      description:
          'Restores the last connected session if available. If no session '
          'exists, triggers passkey authentication and tries to resolve the '
          'contract address automatically via indexer.',
      children: [
        const SizedBox(height: 12),
        Semantics(
          enabled: !disabled,
          hint: disabled && _activeSection != null
              ? 'Disabled, another connection in progress.'
              : null,
          child: LoadingButton(
            label: 'Auto Connect',
            loadingLabel: 'Connecting...',
            enabled: !disabled,
            action: _handleAutoConnect,
          ),
        ),
        if (_autoError != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            enabled: _autoError != null,
            child: InlineErrorBanner(message: _autoError!),
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Section B: Connect via Indexer
  // -------------------------------------------------------------------------

  Widget _buildSectionB(BuildContext context, {required bool kitPresent}) {
    final disabled = _activeSection != null || !kitPresent;
    return _buildCard(
      context,
      title: 'Connect via Indexer',
      description:
          'Authenticates with a passkey, then uses the indexer service to '
          'look up the smart account contract associated with that credential.',
      children: [
        const SizedBox(height: 12),
        Semantics(
          enabled: !disabled,
          hint: disabled && _activeSection != null
              ? 'Disabled, another connection in progress.'
              : null,
          child: LoadingButton(
            label: 'Connect via Indexer',
            loadingLabel: 'Connecting...',
            enabled: !disabled,
            action: _handleConnectViaIndexer,
          ),
        ),
        if (_indexerError != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            enabled: _indexerError != null,
            child: InlineErrorBanner(message: _indexerError!),
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Section C: Connect with Address
  // -------------------------------------------------------------------------

  Widget _buildSectionC(BuildContext context, {required bool kitPresent}) {
    final disabled = _activeSection != null || !kitPresent;
    final addressText = _addressController.text;
    final connectDisabled =
        disabled || _addressFieldError != null || addressText.isEmpty;
    return _buildCard(
      context,
      title: 'Connect with Address',
      description:
          'Connect to a smart account using a known contract address. '
          'Authenticates with a passkey that is registered as a signer on '
          'the contract. Use this to reconnect with a recovery signer.',
      children: [
        const SizedBox(height: 12),
        StyledTextField(
          controller: _addressController,
          label: 'Contract Address',
          hint: 'C...',
          enabled: !disabled,
          validator: (v) => v.isNotEmpty && !isValidContractAddress(v)
              ? 'Must be a valid Stellar contract address (C...)'
              : null,
        ),
        const SizedBox(height: 12),
        Semantics(
          enabled: !connectDisabled,
          hint: connectDisabled && _activeSection != null
              ? 'Disabled, another connection in progress.'
              : null,
          child: LoadingButton(
            label: 'Connect',
            loadingLabel: 'Connecting...',
            enabled: !connectDisabled,
            action: _handleConnectWithAddress,
          ),
        ),
        if (_addressError != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            enabled: _addressError != null,
            child: InlineErrorBanner(message: _addressError!),
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Section D: Pending Deployments
  // -------------------------------------------------------------------------

  Widget _buildSectionD(BuildContext context, {required bool kitPresent}) {
    final count = _pendingCredentials.length;
    return _buildCard(
      context,
      title: 'Pending Deployments ($count)',
      description:
          'These credentials were registered but contract deployment may not '
          'have completed. Retry the deployment or delete the credential.',
      children: [
        for (final credential in _pendingCredentials)
          PendingCredentialCard(
            credentialId: credential.credentialId,
            contractId: credential.contractId,
            nickname: credential.nickname,
            enabled: _activeSection == null && kitPresent,
            isDeploying: _deployingCredentialId == credential.credentialId,
            errorMessage: _pendingErrors[credential.credentialId],
            onRetryDeploy: () => _handleRetryDeploy(credential.credentialId),
            onDelete: () => _handleDeletePending(credential.credentialId),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Card builder
  // -------------------------------------------------------------------------

  Widget _buildCard(
    BuildContext context, {
    required String title,
    required String description,
    required List<Widget> children,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colorScheme.cardBackground,
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
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Handlers
  // -------------------------------------------------------------------------

  Future<void> _handleAutoConnect() async {
    setState(() {
      _activeSection = ConnectionSection.auto;
      _autoError = null;
    });
    try {
      final flow = _resolveFlow();
      if (flow == null) {
        setState(() {
          _autoError = 'No wallet found for this passkey';
          _activeSection = null;
        });
        return;
      }
      final result = await flow.autoConnect();
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _autoError = 'No wallet found for this passkey';
          _activeSection = null;
        });
        return;
      }
      await _handleResult(result, originatingSection: ConnectionSection.auto);
    } on WebAuthnCancelled {
      if (mounted) setState(() => _activeSection = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _autoError = classifyError(e).message;
          _activeSection = null;
        });
      }
    }
  }

  Future<void> _handleConnectViaIndexer() async {
    setState(() {
      _activeSection = ConnectionSection.indexer;
      _indexerError = null;
    });
    try {
      final flow = _resolveFlow();
      if (flow == null) {
        setState(() {
          _indexerError = 'No contract found for this credential';
          _activeSection = null;
        });
        return;
      }
      final result = await flow.connectViaIndexer();
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _indexerError = 'No contract found for this credential';
          _activeSection = null;
        });
        return;
      }
      await _handleResult(result, originatingSection: ConnectionSection.indexer);
    } on WebAuthnCancelled {
      if (mounted) setState(() => _activeSection = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _indexerError = classifyError(e).message;
          _activeSection = null;
        });
      }
    }
  }

  Future<void> _handleConnectWithAddress() async {
    final address = _addressController.text.trim();
    if (!isValidContractAddress(address)) {
      setState(() {
        _addressFieldError = 'Must be a valid Stellar contract address (C...)';
      });
      return;
    }
    setState(() {
      _activeSection = ConnectionSection.address;
      _addressError = null;
    });
    try {
      final flow = _resolveFlow();
      if (flow == null) {
        setState(() {
          _addressError = 'Could not connect to the provided contract address';
          _activeSection = null;
        });
        return;
      }
      final result = await flow.connectWithAddress(address);
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _addressError = 'Could not connect to the provided contract address';
          _activeSection = null;
        });
        return;
      }
      _popToMain();
    } on WebAuthnCancelled {
      if (mounted) setState(() => _activeSection = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _addressError = classifyError(e).message;
          _activeSection = null;
        });
      }
    }
  }

  Future<void> _handleRetryDeploy(String credentialId) async {
    setState(() {
      _activeSection = ConnectionSection.pending;
      _deployingCredentialId = credentialId;
      _pendingErrors.remove(credentialId);
    });
    try {
      final flow = _resolveFlow();
      if (flow == null) {
        setState(() {
          _activeSection = null;
          _deployingCredentialId = null;
        });
        return;
      }
      await flow.retryPendingDeploy(credentialId: credentialId);
      if (!mounted) return;
      _popToMain();
    } catch (e) {
      if (mounted) {
        final classified = classifyError(e);
        setState(() {
          _pendingErrors[credentialId] = classified.message;
          _activeSection = null;
          _deployingCredentialId = null;
        });
      }
    }
  }

  Future<void> _handleDeletePending(String credentialId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete pending credential?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _activeSection = ConnectionSection.pending;
      _pendingErrors.remove(credentialId);
    });
    try {
      final flow = _resolveFlow();
      if (flow == null) {
        setState(() => _activeSection = null);
        return;
      }
      final deleted = await flow.deletePendingCredential(
        credentialId: credentialId,
      );
      if (!mounted) return;
      setState(() => _activeSection = null);
      if (deleted) {
        await _loadPendingCredentials();
      }
    } catch (e) {
      if (mounted) setState(() => _activeSection = null);
    }
  }

  // -------------------------------------------------------------------------
  // Picker / disambiguation
  // -------------------------------------------------------------------------

  /// Handles a [ConnectionResult] from any path.
  ///
  /// Connected → pop. Ambiguous → show picker.
  Future<void> _handleResult(
    ConnectionResult result, {
    required ConnectionSection originatingSection,
  }) async {
    if (result is ConnectionResultConnected) {
      _popToMain();
      return;
    }
    if (result is ConnectionResultAmbiguous) {
      setState(() => _activeSection = null);
      if (!mounted) return;
      final chosen = await ContractPickerSheet.show(
        context: context,
        candidates: result.candidates,
      );
      if (!mounted) return;
      if (chosen == null) return;
      await _finalizePicker(
        credentialId: result.credentialId,
        contractAddress: chosen,
        originatingSection: originatingSection,
      );
    }
  }

  Future<void> _finalizePicker({
    required String credentialId,
    required String contractAddress,
    required ConnectionSection originatingSection,
  }) async {
    setState(() {
      _activeSection = originatingSection;
      _indexerError = null;
      _autoError = null;
    });
    try {
      final flow = _resolveFlow();
      if (flow == null) {
        setState(() => _activeSection = null);
        return;
      }
      final result = await flow.finalizeAmbiguous(
        credentialId: credentialId,
        contractAddress: contractAddress,
      );
      if (!mounted) return;
      if (result != null) {
        _popToMain();
      } else {
        setState(() {
          if (originatingSection == ConnectionSection.auto) {
            _autoError = 'No wallet found for this passkey';
          } else {
            _indexerError = 'No contract found for this credential';
          }
          _activeSection = null;
        });
      }
    } catch (e) {
      if (mounted) {
        final msg = classifyError(e).message;
        setState(() {
          if (originatingSection == ConnectionSection.auto) {
            _autoError = msg;
          } else {
            _indexerError = msg;
          }
          _activeSection = null;
        });
      }
    }
  }

  // -------------------------------------------------------------------------
  // Pending credentials
  // -------------------------------------------------------------------------

  Future<void> _loadPendingCredentials() async {
    final flow = _resolveFlow();
    if (flow == null) return;
    final pending = await flow.loadPendingCredentials();
    if (mounted) {
      setState(() => _pendingCredentials = pending);
    }
  }

  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------

  void _popToMain() {
    if (!mounted) return;
    // Flow-completion exit: reset the stack to a clean main screen rather
    // than popping into the prior screen's state. Use the back button
    // (`popOrGoMain`) for user-initiated reverse navigation.
    context.go(AppRoutes.main);
  }

  // -------------------------------------------------------------------------
  // Flow resolver
  // -------------------------------------------------------------------------

  /// Resolves the active [WalletConnectionFlow], or returns null when the kit
  /// is not yet initialised.
  ///
  /// Uses the injected [widget.flow] when present (test path). Otherwise
  /// constructs a production flow from the active kit.
  WalletConnectionFlow? _resolveFlow() {
    if (widget.flow != null) return widget.flow;
    final demoState = ref.read(demoStateProvider.notifier);
    final activityLog = ref.read(activityLogProvider.notifier);
    final mainFlow = ref.read(mainScreenFlowProvider);
    return buildWalletConnectionFlow(
      demoState: demoState,
      activityLog: activityLog,
      mainScreenFlow: mainFlow,
    );
  }
}
