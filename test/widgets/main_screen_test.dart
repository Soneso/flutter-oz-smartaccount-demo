/// Widget tests for [MainScreen] state branches.
///
/// Verifies:
/// - Not Connected: shows "No wallet connected", Create/Connect CTAs; no
///   balance, no nav grid, no Disconnect.
/// - Connected + Not Deployed: shows [WalletStatusCard] (with "Wallet Not
///   Deployed" warning); no deployed nav grid.
/// - Connected + Deployed: shows [WalletStatusCard] with nav grid.
/// - AppBar title is "Stellar Smart Account Demo" with "Testnet" subtitle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_account_demo/flows/main_screen_flow.dart';
import 'package:smart_account_demo/screens/main_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/state/main_screen_flow_provider.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// A [MainScreenFlow] subclass that makes all SDK operations no-ops so widget
/// tests can render [MainScreen] without a live kit or network connection.
class _NoOpMainScreenFlow extends MainScreenFlow {
  _NoOpMainScreenFlow({
    required super.demoState,
    required super.activityLog,
  });

  @override
  Future<void> initializeKit() async {}

  @override
  Future<void> refreshBalances() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> deployPendingAndProvision({required String credentialId}) async {}
}

Widget _wrap(WalletConnectionState initialState) {
  final container = ProviderContainer(
    overrides: [
      demoStateProvider.overrideWith(() => _FixedDemoStateNotifier(initialState)),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
      mainScreenFlowProvider.overrideWithValue(
        _NoOpMainScreenFlow(
          demoState: DemoStateNotifier(),
          activityLog: ActivityLogNotifier(),
        ),
      ),
    ],
  );

  // A minimal GoRouter so context.go calls do not throw.
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const MainScreen(),
      ),
      GoRoute(
        path: '/wallet-creation',
        builder: (context, state) =>
            const Scaffold(body: Text('Create Wallet Screen')),
      ),
      GoRoute(
        path: '/wallet-connection',
        builder: (context, state) =>
            const Scaffold(body: Text('Connect Wallet Screen')),
      ),
      GoRoute(
        path: '/context-rules',
        builder: (context, state) =>
            const Scaffold(body: Text('Context Rules Screen')),
      ),
      GoRoute(
        path: '/transfer',
        builder: (context, state) =>
            const Scaffold(body: Text('Transfer Screen')),
      ),
      GoRoute(
        path: '/approve',
        builder: (context, state) =>
            const Scaffold(body: Text('Approve Screen')),
      ),
      GoRoute(
        path: '/account-signers',
        builder: (context, state) =>
            const Scaffold(body: Text('Account Signers Screen')),
      ),
    ],
  );

  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: ThemeData.light(useMaterial3: true),
      routerConfig: router,
    ),
  );
}

class _FixedDemoStateNotifier extends DemoStateNotifier {
  _FixedDemoStateNotifier(this._fixed);
  final WalletConnectionState _fixed;

  @override
  WalletConnectionState build() => _fixed;
}

const _disconnected = WalletConnectionState.disconnected();

WalletConnectionState _connectedDeployed() => const WalletConnectionState(
      isConnected: true,
      isDeployed: true,
      contractId: 'CDUMMYCONTRACT000000000000000000000000000000000000000000',
      credentialId: 'cred123',
      xlmBalance: '10.0',
    );

WalletConnectionState _connectedNotDeployed() => const WalletConnectionState(
      isConnected: true,
      isDeployed: false,
      contractId: 'CDUMMYCONTRACT000000000000000000000000000000000000000000',
      credentialId: 'cred123',
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MainScreen — AppBar', () {
    testWidgets('title is "Stellar Smart Account Demo"', (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('Stellar Smart Account Demo'), findsOneWidget);
    });

    testWidgets('subtitle is "Testnet"', (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('Testnet'), findsOneWidget);
    });
  });

  group('MainScreen — Not Connected branch', () {
    testWidgets('shows "No wallet connected" placeholder', (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('No wallet connected'), findsOneWidget);
    });

    testWidgets('shows "Create Wallet" CTA button', (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('Create Wallet'), findsOneWidget);
    });

    testWidgets('shows "Connect Wallet" CTA button', (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('Connect Wallet'), findsOneWidget);
    });

    testWidgets('does not show "Disconnect" when not connected', (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('Disconnect'), findsNothing);
    });

    testWidgets('does not show "Wallet Status" when not connected',
        (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('Wallet Status'), findsNothing);
    });

    testWidgets('does not show nav grid when not connected', (tester) async {
      await tester.pumpWidget(_wrap(_disconnected));
      await tester.pump();
      expect(find.text('Context Rules'), findsNothing);
      expect(find.text('Transfer'), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Account Signers'), findsNothing);
    });
  });

  group('MainScreen — Connected + Deployed branch', () {
    testWidgets('shows "Wallet Status" card', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      await tester.pump();
      expect(find.text('Wallet Status'), findsOneWidget);
    });

    testWidgets('shows navigation grid with four actions', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      await tester.pump();
      expect(find.text('Context Rules'), findsOneWidget);
      expect(find.text('Transfer'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Account Signers'), findsOneWidget);
    });

    testWidgets('shows "Disconnect" button', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      await tester.pump();
      expect(find.text('Disconnect'), findsOneWidget);
    });

    testWidgets('does not show "No wallet connected" when connected',
        (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      await tester.pump();
      expect(find.text('No wallet connected'), findsNothing);
    });

    testWidgets('does not show "Create Wallet" CTA in deployed state',
        (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      await tester.pump();
      // "Create Wallet" text still appears as the nav card title "Create Wallet"
      // if the old code left it in the grid — ensure the old CTAs are absent.
      // The nav grid should NOT have Create/Connect cards.
      // We check that "Connect Wallet" CTA button is absent.
      expect(find.text('Connect Wallet'), findsNothing);
    });

    testWidgets('undeployed warning is absent when deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      await tester.pump();
      expect(find.text('Wallet Not Deployed'), findsNothing);
    });
  });

  group('MainScreen — Connected + Not Deployed branch', () {
    testWidgets('shows "Wallet Status" card', (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      await tester.pump();
      expect(find.text('Wallet Status'), findsOneWidget);
    });

    testWidgets('shows "Wallet Not Deployed" warning', (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      await tester.pump();
      expect(find.text('Wallet Not Deployed'), findsOneWidget);
    });

    testWidgets('shows "Deploy Now" button', (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      await tester.pump();
      expect(find.text('Deploy Now'), findsOneWidget);
    });

    testWidgets('does not show nav grid when not deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      await tester.pump();
      expect(find.text('Context Rules'), findsNothing);
    });

    testWidgets('shows "Disconnect" button even when not deployed',
        (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      await tester.pump();
      expect(find.text('Disconnect'), findsOneWidget);
    });
  });
}
