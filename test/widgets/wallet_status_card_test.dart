/// Widget tests for [WalletStatusCard].
///
/// Verifies the three state branches:
/// - Deployed: balance section, navigation grid, Disconnect, Refresh button,
///   and Copy button visible; undeployed warning absent.
/// - Not deployed: undeployed warning card visible; balance section absent.
/// - Contract address truncation and Copy snackbar text.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/widgets/wallet_status_card.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

WalletConnectionState _connectedDeployed({
  String contractId =
      'CDUMMYCONTRACT000000000000000000000000000000000000000000',
  String credentialId = 'cred123',
  String? xlmBalance = '10.0',
  String? demoBalance,
}) {
  return WalletConnectionState(
    isConnected: true,
    isDeployed: true,
    contractId: contractId,
    credentialId: credentialId,
    xlmBalance: xlmBalance,
    demoTokenBalance: demoBalance,
  );
}

WalletConnectionState _connectedNotDeployed({
  String contractId =
      'CDUMMYCONTRACT000000000000000000000000000000000000000000',
  String credentialId = 'cred123',
}) {
  return WalletConnectionState(
    isConnected: true,
    isDeployed: false,
    contractId: contractId,
    credentialId: credentialId,
  );
}

Widget _wrap(WalletConnectionState state) {
  final container = ProviderContainer(
    overrides: [
      demoStateProvider.overrideWith(() => _FixedDemoStateNotifier(state)),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      home: Scaffold(
        body: SingleChildScrollView(
          child: WalletStatusCard(
            onRefresh: () async {},
            onDisconnect: () async {},
            onDeployNow: () async {},
          ),
        ),
      ),
    ),
  );
}

class _FixedDemoStateNotifier extends DemoStateNotifier {
  _FixedDemoStateNotifier(this._fixed);
  final WalletConnectionState _fixed;

  @override
  WalletConnectionState build() => _fixed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WalletStatusCard — card header', () {
    testWidgets('shows "Wallet Status" title', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.text('Wallet Status'), findsOneWidget);
    });
  });

  group('WalletStatusCard — address rows', () {
    testWidgets('shows "Contract Address:" label', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.text('Contract Address:'), findsOneWidget);
    });

    testWidgets('shows "Credential ID:" label', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.text('Credential ID:'), findsOneWidget);
    });

    testWidgets('shows Copy contract address icon button', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(
        find.byTooltip('Copy contract address'),
        findsOneWidget,
      );
    });

    testWidgets('tapping Copy shows "Contract address copied" snackbar',
        (tester) async {
      // Install a clipboard mock so the platform channel does not throw.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') return null;
        if (call.method == 'Clipboard.getData') return {'text': ''};
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.pumpWidget(_wrap(_connectedDeployed()));
      await tester.tap(find.byTooltip('Copy contract address'));
      await tester.pumpAndSettle();
      expect(find.text('Contract address copied'), findsOneWidget);
    });
  });

  group('WalletStatusCard — deployed branch', () {
    testWidgets('shows balance section when deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.text('Balance:'), findsOneWidget);
    });

    testWidgets('shows Refresh balances icon button when deployed',
        (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.byTooltip('Refresh balances'), findsOneWidget);
    });

    testWidgets('shows XLM balance when provided', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed(xlmBalance: '42.5')));
      expect(find.text('42.5 XLM'), findsOneWidget);
    });

    testWidgets('shows "Loading..." when xlmBalance is null', (tester) async {
      await tester.pumpWidget(
        _wrap(_connectedDeployed(xlmBalance: null)),
      );
      expect(find.text('Loading... XLM'), findsOneWidget);
    });

    testWidgets('navigation grid is present when deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.text('Context Rules'), findsOneWidget);
      expect(find.text('Transfer'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Account Signers'), findsOneWidget);
    });

    testWidgets('undeployed warning is absent when deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.text('Wallet Not Deployed'), findsNothing);
      expect(find.text('Deploy Now'), findsNothing);
    });

    testWidgets('shows outlined Disconnect button', (tester) async {
      await tester.pumpWidget(_wrap(_connectedDeployed()));
      expect(find.text('Disconnect'), findsOneWidget);
    });
  });

  group('WalletStatusCard — not deployed branch', () {
    testWidgets('shows "Wallet Not Deployed" warning when not deployed',
        (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      expect(find.text('Wallet Not Deployed'), findsOneWidget);
    });

    testWidgets('shows "Deploy Now" button when not deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      expect(find.text('Deploy Now'), findsOneWidget);
    });

    testWidgets('balance section is absent when not deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      expect(find.text('Balance:'), findsNothing);
    });

    testWidgets('navigation grid is absent when not deployed', (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      expect(find.text('Context Rules'), findsNothing);
      expect(find.text('Transfer'), findsNothing);
    });

    testWidgets('Disconnect button still shown when not deployed',
        (tester) async {
      await tester.pumpWidget(_wrap(_connectedNotDeployed()));
      expect(find.text('Disconnect'), findsOneWidget);
    });
  });
}
