/// Wallet creation screen.
///
/// Guides the user through registering a passkey and deploying a smart account
/// contract. All SDK interaction is delegated to [WalletCreationFlow]; this
/// widget only manages form state and the UI response to flow outcomes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../flows/main_screen_flow.dart';
import '../flows/wallet_creation_flow.dart';
import '../navigation/routes.dart';
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../state/demo_token_service_provider.dart';
import '../state/main_screen_flow_provider.dart';
import '../theme/spacing.dart';
import '../util/error_utils.dart';
import '../util/semantic_colors.dart';
import '../widgets/deployed_result_card.dart';
import '../widgets/loading_button.dart';
import '../widgets/progress_card.dart';
import '../widgets/styled_text_field.dart';
import '../widgets/undeployed_result_card.dart';

// ---------------------------------------------------------------------------
// WalletCreationScreen
// ---------------------------------------------------------------------------

/// Screen for creating a new smart account wallet.
///
/// The screen drives [WalletCreationFlow], which owns all SDK interactions.
/// This widget reads from [DemoStateNotifier] and [ActivityLogNotifier] via
/// Riverpod and never calls the SDK directly.
///
/// Flow:
/// 1. User enters a passkey name.
/// 2. User adjusts the auto-deploy toggle.
/// 3. User taps "Create Wallet".
/// 4. A [ProgressCard] is shown while the passkey ceremony and any deploy or
///    mint operations run.
/// 5. On success, a [DeployedResultCard] or [UndeployedResultCard] is shown
///    in-place. The user taps "Go to Main Screen" to pop the route.
/// 6. On error, an inline error banner appears below the form with the
///    actionable message. The button re-enables after the error is set.
///
/// Dependencies:
/// [MainScreenFlow] and [WalletCreationFlow] are injected via the constructor
/// so widget tests can substitute mocks. In production [MainScreenFlow] is
/// sourced from [mainScreenFlowProvider] so both this screen and [MainScreen]
/// share one instance.
///
/// Screens-never-call-SDK rule:
/// This file must not reference SDK kit classes or manager accessors directly.
/// The architecture guard test in [test/flows/main_screen_flow_test.dart]
/// enforces this at CI time.
class WalletCreationScreen extends ConsumerStatefulWidget {
  /// Creates a [WalletCreationScreen].
  ///
  /// [mainScreenFlow] is the shared main-screen flow. When null, the screen
  /// reads [mainScreenFlowProvider] from Riverpod — this is the production
  /// path. Tests inject a mock to avoid needing a live kit.
  const WalletCreationScreen({
    this.mainScreenFlow,
    this.walletCreationFlow,
    super.key,
  });

  /// Optional injected [MainScreenFlow] for balance refresh after creation.
  final MainScreenFlow? mainScreenFlow;

  /// Optional injected [WalletCreationFlow] for testing.
  final WalletCreationFlow? walletCreationFlow;

  @override
  ConsumerState<WalletCreationScreen> createState() =>
      _WalletCreationScreenState();
}

class _WalletCreationScreenState
    extends ConsumerState<WalletCreationScreen> {
  // ---- Form state ----
  final _usernameController = TextEditingController();

  /// When true, the SDK submits the deploy transaction immediately after passkey
  /// creation. When false, deployment is deferred and the user can deploy later.
  bool _autoSubmit = true;

  // ---- UI state ----

  /// True while the creation flow is executing.
  bool _isCreating = false;

  /// Progress message emitted by the flow during long-running steps.
  ///
  /// When non-null, the Create Wallet button shows this text next to the
  /// spinner instead of its default loading label. Reset to null before each
  /// new attempt and in the finally block so that consecutive calls start
  /// fresh.
  String? _creationProgress;

  /// Inline error message shown below the form. Cleared when the user edits
  /// the username or re-taps Create.
  String? _errorMessage;

  /// Guidance message appended below error banners when a passkey may have
  /// been registered before the failure.
  String? _errorGuidance;

  /// Friendly inline status shown for user-cancellation events (not an error).
  String? _cancelledMessage;

  /// Non-null after a successful creation. Drives the result-card branch.
  WalletCreationResult? _createResult;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_clearBannersIfNeeded);
  }

  @override
  void dispose() {
    _usernameController.removeListener(_clearBannersIfNeeded);
    _usernameController.dispose();
    super.dispose();
  }

  /// Clears error and cancellation banners when the user edits the username.
  ///
  /// Avoids a spurious [setState] when there is nothing to clear (e.g. on the
  /// first keystroke after the field starts empty with no active banner).
  void _clearBannersIfNeeded() {
    if (_errorMessage != null || _cancelledMessage != null || _errorGuidance != null) {
      setState(() {
        _errorMessage = null;
        _errorGuidance = null;
        _cancelledMessage = null;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Wallet'),
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
            _buildInfoCard(context),
            const SizedBox(height: 16),
            if (_createResult == null) ...[
              _buildFormCard(context),
              const SizedBox(height: 12),
              if (_errorMessage != null) ...[
                _buildErrorBanner(_errorMessage!, _errorGuidance),
                const SizedBox(height: 12),
              ],
              if (_cancelledMessage != null) ...[
                _buildCancelledBanner(_cancelledMessage!),
                const SizedBox(height: 12),
              ],
              if (_isCreating) ...[
                ProgressCard(status: _creationProgress ?? 'Creating...'),
                const SizedBox(height: 12),
              ],
              if (!_isCreating) _buildCreateButton(),
            ] else ...[
              _buildResultCard(context, _createResult!),
            ],
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Sub-widgets
  // -------------------------------------------------------------------------

  Widget _buildInfoCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
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
              'Wallet Creation',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurface,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Creating a wallet will register a passkey with your device '
              'and deploy a smart account contract to the Stellar network. '
              'The passkey is used to authenticate and sign transactions.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StyledTextField(
              controller: _usernameController,
              label: 'Passkey Name',
              validator: (v) =>
                  v.trim().isEmpty ? 'Username must not be empty.' : null,
              onSubmitted: (_) {},
            ),
            const SizedBox(height: 4),
            const Divider(height: 24),
            _buildToggle(
              context: context,
              title: 'Auto-deploy after passkey registration',
              description:
                  'Submit the deployment transaction immediately after passkey '
                  'creation. Disable to deploy later from the Connect Wallet '
                  'screen.',
              semanticsLabel: 'Auto-deploy after passkey registration',
              semanticsHint: _autoSubmit
                  ? 'On. The contract will be deployed immediately after passkey '
                      'creation.'
                  : 'Off. The deploy transaction will be prepared but not '
                      'submitted.',
              value: _autoSubmit,
              onChanged: (v) => setState(() => _autoSubmit = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToggle({
    required BuildContext context,
    required String title,
    required String description,
    required String semanticsLabel,
    required String semanticsHint,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Semantics(
      label: semanticsLabel,
      hint: semanticsHint,
      toggled: value,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message, String? guidance) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Error: $message',
      container: true,
      liveRegion: true,
      enabled: _errorMessage != null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.errorBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: colorScheme.onErrorContainer,
              size: 20,
              semanticLabel: '',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onErrorContainer,
                    ),
                  ),
                  if (guidance != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      guidance,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onErrorContainer.withAlpha(200),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCancelledBanner(String message) {
    return Semantics(
      label: 'Notice: $message',
      container: true,
      liveRegion: true,
      enabled: _cancelledMessage != null,
      child: Builder(
        builder: (context) => Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withAlpha(51),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 20,
                semanticLabel: '',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCreateButton() {
    return Semantics(
      hint: 'Starts the passkey registration and smart account deployment.',
      child: LoadingButton(
        label: 'Create Wallet',
        loadingProgress: _creationProgress,
        action: _handleCreateWallet,
      ),
    );
  }

  Widget _buildResultCard(BuildContext context, WalletCreationResult result) {
    if (result.isDeployed) {
      return DeployedResultCard(
        result: result,
        onGoToMainScreen: () => context.go(AppRoutes.main),
      );
    }
    final MainScreenFlow mainFlow =
        widget.mainScreenFlow ?? ref.read(mainScreenFlowProvider);
    return UndeployedResultCard(
      result: result,
      onDeployNow: () => mainFlow.deployPendingAndProvision(
        credentialId: result.credentialId,
      ),
      onGoToMainScreen: () => context.go(AppRoutes.main),
      onDeploySucceeded: () {
        final state = ref.read(demoStateProvider);
        final updated = WalletCreationResult(
          contractAddress: result.contractAddress,
          credentialId: result.credentialId,
          isDeployed: true,
          xlmBalance: state.xlmBalance,
          demoTokenBalance: state.demoTokenBalance,
          transactionHash: result.transactionHash,
        );
        setState(() => _createResult = updated);
      },
    );
  }

  // -------------------------------------------------------------------------
  // Action
  // -------------------------------------------------------------------------

  /// Resolves the flow and calls [WalletCreationFlow.createWallet].
  ///
  /// On success, shows the appropriate result card in-place. On error,
  /// [_handleCreationError] receives the typed [WalletCreationError] from
  /// [LoadingButton.onError].
  Future<void> _handleCreateWallet() async {
    setState(() {
      _errorMessage = null;
      _errorGuidance = null;
      _cancelledMessage = null;
      _creationProgress = null;
      _isCreating = true;
    });

    try {
      final flow = _resolveFlow();
      if (flow == null) {
        setState(() {
          _errorMessage =
              'Kit not initialised. Return to the main screen and try again.';
          _isCreating = false;
        });
        return;
      }

      final result = await flow.createWallet(
        username: _usernameController.text,
        autoSubmit: _autoSubmit,
        onProgress: (msg) {
          if (mounted) setState(() => _creationProgress = msg);
        },
      );

      if (mounted) {
        setState(() {
          _createResult = result;
          _creationProgress = null;
          _isCreating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _creationProgress = null;
          _isCreating = false;
        });
        _handleCreationError(e);
      }
    }
  }

  /// Handles errors thrown during wallet creation.
  ///
  /// Dispatches on [WalletCreationError] subtypes to set the appropriate
  /// banner message. All UI updates run synchronously on the widget's event
  /// loop.
  void _handleCreationError(Object error) {
    if (error is WalletCreationError) {
      if (error.isUserCanceled) {
        setState(() {
          _cancelledMessage = 'Passkey registration cancelled by user';
          _errorMessage = null;
          _errorGuidance = null;
        });
      } else if (error.isInvalidUsername) {
        setState(() {
          _errorMessage = error.reason;
          _errorGuidance = null;
          _cancelledMessage = null;
        });
      } else {
        setState(() {
          _errorMessage = 'Failed to create wallet: ${error.actionableMessage}';
          _errorGuidance =
              'If a passkey was registered before the failure, go to Connect '
              'Wallet and check Pending Deployments to retry the deployment.';
          _cancelledMessage = null;
        });
      }
    } else {
      final classified = classifyError(error);
      setState(() {
        _errorMessage = 'Failed to create wallet: ${classified.message}';
        _errorGuidance =
            'If a passkey was registered before the failure, go to Connect '
            'Wallet and check Pending Deployments to retry the deployment.';
        _cancelledMessage = null;
      });
    }
  }

  /// Resolves the active [WalletCreationFlow], or returns null when the kit
  /// is not yet initialised.
  ///
  /// Uses the injected [widget.walletCreationFlow] when present (test path).
  /// Otherwise constructs a production flow using [mainScreenFlowProvider] so
  /// this screen and [MainScreen] share one [MainScreenFlow] instance.
  WalletCreationFlow? _resolveFlow() {
    if (widget.walletCreationFlow != null) return widget.walletCreationFlow;

    final demoState = ref.read(demoStateProvider.notifier);
    final activityLog = ref.read(activityLogProvider.notifier);

    final MainScreenFlow mainFlow =
        widget.mainScreenFlow ?? ref.read(mainScreenFlowProvider);
    final ops = mainFlow.buildWalletOperations();
    if (ops == null) return null;

    // Read the shared DEMO token service from the provider so the auto-deploy
    // path and the main-screen Deploy Now path operate on the same instance.
    // Mint is attempted internally when autoSubmit is true; mint failure is
    // non-fatal and does not surface to the screen as an error.
    final tokenService = ref.read(demoTokenServiceProvider);

    return WalletCreationFlow(
      demoState: demoState,
      activityLog: activityLog,
      walletOperations: ops,
      demoTokenService: tokenService,
      mainScreenFlow: mainFlow,
    );
  }
}
