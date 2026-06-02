/// Widget tests for [WalletConnectionScreen].
///
/// Strategy:
/// - Section A–C always visible; Section D conditional on pending list.
/// - Auto Connect: success → pop, no-result → inline error.
/// - Connect via Indexer: no-result → inline error.
/// - Connect with Address: valid address → proceeds to flow.
/// - Section D: delete removes card; retry shows Deploying state.
/// - Cancellation: no error shown.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_account_demo/flows/main_screen_flow.dart';
import 'package:smart_account_demo/flows/wallet_connection_flow.dart';
import 'package:smart_account_demo/navigation/routes.dart';
import 'package:smart_account_demo/screens/wallet_connection_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/state/main_screen_flow_provider.dart';

import '../flows/wallet_connection_test_support.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Marker text rendered by the test router's main route. After the screen
/// calls `context.go(AppRoutes.main)`, the marker should be visible.
const String _mainMarker = 'main-marker';

/// Builds a [GoRouter] with the [WalletConnectionScreen] as the initial
/// location and a marker placeholder at [AppRoutes.main]. Used in tests
/// that need to verify the screen navigates back to main on success.
GoRouter _buildTestRouter(WalletConnectionFlow flow) {
  return GoRouter(
    initialLocation: AppRoutes.walletConnection,
    routes: [
      GoRoute(
        path: AppRoutes.main,
        builder: (context, state) => const Scaffold(body: Text(_mainMarker)),
      ),
      GoRoute(
        path: AppRoutes.walletConnection,
        builder: (context, state) => WalletConnectionScreen(flow: flow),
      ),
    ],
  );
}

/// Builds a [WalletConnectionFlow] from mocks for screen injection.
///
/// Uses a [ProviderContainer] so notifiers are properly initialised.
WalletConnectionFlow _buildFlow({
  MockWalletConnectionOperations? walletOps,
  MockCredentialOperations? credentialOps,
}) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final ds = container.read(demoStateProvider.notifier);
  final al = container.read(activityLogProvider.notifier);
  return WalletConnectionFlow(
    demoState: ds,
    activityLog: al,
    walletOperations: walletOps ?? MockWalletConnectionOperations(),
    credentialOperations: credentialOps ?? MockCredentialOperations(),
  );
}

/// A stub [MainScreenFlow] that suppresses kit usage in screen tests.
class _NoOpMainScreenFlow extends MainScreenFlow {
  _NoOpMainScreenFlow()
      : super(
          demoState: ProviderContainer().read(demoStateProvider.notifier),
          activityLog: ProviderContainer().read(activityLogProvider.notifier),
        );

  @override
  Future<void> refreshBalances() async {}
}

/// Wraps [WalletConnectionScreen] with an injected flow in a testable navigator.
Widget _wrapWithFlow(WalletConnectionFlow flow) {
  return ProviderScope(
    overrides: [
      demoStateProvider.overrideWith(DemoStateNotifier.new),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
      mainScreenFlowProvider.overrideWith((_) => _NoOpMainScreenFlow()),
    ],
    child: MaterialApp(
      home: WalletConnectionScreen(flow: flow),
    ),
  );
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WalletConnectionScreen — layout', () {
    testWidgets('AppBar title is "Connect Wallet"', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      expect(find.text('Connect Wallet'), findsOneWidget);
    });

    testWidgets('shows Section A title "Auto Connect"', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      // Title appears at least once (may also appear as button label).
      expect(find.text('Auto Connect'), findsAtLeastNWidgets(1));
    });

    testWidgets('shows Section B title "Connect via Indexer"', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      expect(find.text('Connect via Indexer'), findsAtLeastNWidgets(1));
    });

    testWidgets('shows Section C title "Connect with Address"', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      expect(find.text('Connect with Address'), findsOneWidget);
    });

    testWidgets('Section D hidden when pending list is empty', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pending Deployments'), findsNothing);
    });

    testWidgets('Section A description text is present', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      expect(
        find.textContaining('Restores the last connected session'),
        findsOneWidget,
      );
    });

    testWidgets('Section B description text is present', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      expect(
        find.textContaining('indexer service to look up'),
        findsOneWidget,
      );
    });

    testWidgets('Section C description text is present', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      expect(
        find.textContaining('reconnect with a recovery signer'),
        findsOneWidget,
      );
    });

    testWidgets('Section C shows "Contract Address" input', (tester) async {
      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));
      expect(find.text('Contract Address'), findsOneWidget);
    });
  });

  group('WalletConnectionScreen — Section A (Auto Connect)', () {
    testWidgets('auto connect success navigates back to main', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final walletOps = MockWalletConnectionOperations()
        ..connectResult = WalletConnectionFixtures.connectedResult();
      final credentialOps = MockCredentialOperations()
        ..isDeployedResult = true;
      final flow = _buildFlow(
        walletOps: walletOps,
        credentialOps: credentialOps,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            demoStateProvider.overrideWith(DemoStateNotifier.new),
            activityLogProvider.overrideWith(ActivityLogNotifier.new),
            mainScreenFlowProvider.overrideWith((_) => _NoOpMainScreenFlow()),
          ],
          child: MaterialApp.router(
            routerConfig: _buildTestRouter(flow),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the FilledButton labelled "Auto Connect" (not the card title).
      await tester.tap(find.widgetWithText(FilledButton, 'Auto Connect'));
      await tester.pumpAndSettle();

      // The screen must navigate back to the main route.
      expect(find.text(_mainMarker), findsOneWidget);
    });

    testWidgets('auto connect no-result shows inline error', (tester) async {
      final walletOps = MockWalletConnectionOperations()..connectResult = null;
      final flow = _buildFlow(walletOps: walletOps);

      await tester.pumpWidget(_wrapWithFlow(flow));

      await tester.tap(find.widgetWithText(FilledButton, 'Auto Connect'));
      await tester.pumpAndSettle();

      expect(find.text('No wallet found for this passkey'), findsOneWidget);
    });

    testWidgets('cancellation does not show error', (tester) async {
      final walletOps = MockWalletConnectionOperations()
        ..connectError = makeCancelledError();
      final flow = _buildFlow(walletOps: walletOps);

      await tester.pumpWidget(_wrapWithFlow(flow));

      await tester.tap(find.widgetWithText(FilledButton, 'Auto Connect'));
      await tester.pumpAndSettle();

      expect(find.text('No wallet found for this passkey'), findsNothing);
    });
  });

  group('WalletConnectionScreen — Section B (Connect via Indexer)', () {
    testWidgets('no indexer result shows inline error', (tester) async {
      final walletOps = MockWalletConnectionOperations()
        ..authenticateResult = WalletConnectionFixtures.authenticateResult()
        ..connectResult = null;
      final flow = _buildFlow(walletOps: walletOps);

      await tester.pumpWidget(_wrapWithFlow(flow));

      await tester.tap(
        find.widgetWithText(FilledButton, 'Connect via Indexer'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('No contract found for this credential'),
        findsOneWidget,
      );
    });

    testWidgets('cancellation does not show error', (tester) async {
      final walletOps = MockWalletConnectionOperations()
        ..authenticateError = makeCancelledError();
      final flow = _buildFlow(walletOps: walletOps);

      await tester.pumpWidget(_wrapWithFlow(flow));

      await tester.tap(
        find.widgetWithText(FilledButton, 'Connect via Indexer'),
      );
      await tester.pumpAndSettle();

      expect(find.text('No contract found for this credential'), findsNothing);
    });
  });

  group('WalletConnectionScreen — Section C (Connect with Address)', () {
    testWidgets('Connect button disabled when address field is empty',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));

      // Address field is empty by default; Connect button must be disabled.
      final connectButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Connect'),
      );
      expect(connectButton.onPressed, isNull);
    });

    testWidgets('Connect button disabled when address field has invalid value',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final flow = _buildFlow();
      await tester.pumpWidget(_wrapWithFlow(flow));

      await tester.enterText(find.byType(TextField), 'NOT_A_VALID_ADDRESS');
      await tester.pump();

      final connectButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Connect'),
      );
      expect(connectButton.onPressed, isNull);
    });

    testWidgets('connect with valid address that returns null shows error',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final walletOps = MockWalletConnectionOperations()
        ..authenticateResult = WalletConnectionFixtures.authenticateResult()
        ..connectResult = null;
      final flow = _buildFlow(walletOps: walletOps);

      await tester.pumpWidget(_wrapWithFlow(flow));

      await tester.enterText(
        find.byType(TextField),
        WalletConnectionFixtures.defaultContractId,
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not connect to the provided contract address'),
        findsOneWidget,
      );
    });

    testWidgets('cancellation does not show error', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final walletOps = MockWalletConnectionOperations()
        ..authenticateError = makeCancelledError();
      final flow = _buildFlow(walletOps: walletOps);

      await tester.pumpWidget(_wrapWithFlow(flow));

      await tester.enterText(
        find.byType(TextField),
        WalletConnectionFixtures.defaultContractId,
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not connect to the provided contract address'),
        findsNothing,
      );
    });
  });

  group('WalletConnectionScreen — Section D (Pending)', () {
    testWidgets('shows Section D when pending list is non-empty', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final credentialOps = MockCredentialOperations()
        ..pendingCredentials = [WalletConnectionFixtures.storedCredential()];
      final flow = _buildFlow(credentialOps: credentialOps);

      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Pending Deployments'), findsOneWidget);
    });

    testWidgets('delete success removes card from list', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final credentialOps = MockCredentialOperations()
        ..pendingCredentials = [WalletConnectionFixtures.storedCredential()];
      final flow = _buildFlow(credentialOps: credentialOps);

      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Pending Deployments'), findsOneWidget);

      // After delete: mock returns empty list on next load.
      credentialOps.pendingCredentials = const [];

      // Tap Delete to open the confirmation dialog.
      await tester.tap(find.text('Delete'));
      await tester.pump(); // start dialog animation
      await tester.pump(const Duration(milliseconds: 300)); // complete animation

      // Confirm the deletion in the AlertDialog.
      expect(find.text('Delete pending credential?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Pending Deployments'), findsNothing);
    });

    testWidgets('retry deploy success navigates back to main', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final credentialOps = MockCredentialOperations()
        ..pendingCredentials = [WalletConnectionFixtures.storedCredential()]
        ..isDeployedResult = true;
      final walletOps = MockWalletConnectionOperations()
        ..deployResult = WalletConnectionFixtures.deployPendingResult();
      final flow = _buildFlow(
        walletOps: walletOps,
        credentialOps: credentialOps,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            demoStateProvider.overrideWith(DemoStateNotifier.new),
            activityLogProvider.overrideWith(ActivityLogNotifier.new),
            mainScreenFlowProvider.overrideWith((_) => _NoOpMainScreenFlow()),
          ],
          child: MaterialApp.router(
            routerConfig: _buildTestRouter(flow),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Allow pending list to load.
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Retry Deploy'));
      await tester.pumpAndSettle();

      expect(find.text(_mainMarker), findsOneWidget);
    });
  });
}
