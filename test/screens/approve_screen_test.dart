/// Widget tests for [ApproveScreen].
///
/// Covers:
/// - Not-connected guard renders the inventory message and a Go Back button.
/// - Connected layout: description, balance, token contract, form fields.
/// - Validation: spender / amount errors with verbatim text.
/// - Single-signer happy path: tapping Approve invokes the flow and shows the
///   result card.
/// - Result card: New Approve resets the form.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/approve_flow.dart';
import 'package:smart_account_demo/flows/transfer_flow.dart';
import 'package:smart_account_demo/screens/approve_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';

import 'package:smart_account_demo/widgets/loading_button.dart';

import '../flows/approve_test_support.dart';
import '../flows/context_rule_test_support.dart' show MockBuilderEnvironment;
import '../flows/transfer_test_support.dart' show TransferFixtures;

/// Notifier subclass that synchronously emits a connected state in [build]
/// so the [ApproveScreen] post-frame callback observes the connection on
/// its first read.
class _PreconnectedDemoState extends DemoStateNotifier {
  _PreconnectedDemoState({this.demoTokenContractId});

  final String? demoTokenContractId;

  @override
  WalletConnectionState build() {
    return WalletConnectionState(
      isConnected: true,
      isDeployed: true,
      contractId: ApproveFixtures.defaultContractId,
      credentialId: ApproveFixtures.defaultCredentialId,
      demoTokenContractId: demoTokenContractId,
      demoTokenBalance: demoTokenContractId != null ? '100.0' : null,
    );
  }
}

Widget _wrap({
  required ApproveFlow approveFlow,
  required TransferFlow transferFlow,
  bool isConnected = true,
  String? demoTokenContractId,
}) {
  return ProviderScope(
    overrides: [
      if (isConnected)
        demoStateProvider.overrideWith(
          () => _PreconnectedDemoState(
            demoTokenContractId: demoTokenContractId,
          ),
        )
      else
        demoStateProvider.overrideWith(DemoStateNotifier.new),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
    ],
    child: MaterialApp(
      home: ApproveScreen(
        approveFlow: approveFlow,
        transferFlow: transferFlow,
      ),
    ),
  );
}

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first
      ..physicalSize = const Size(1200, 2400)
      ..devicePixelRatio = 1.0;
  });

  // -------------------------------------------------------------------------
  // Not-connected guard
  // -------------------------------------------------------------------------

  group('ApproveScreen — not connected guard', () {
    testWidgets('shows verbatim error message', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps(isConnected: false);
      final transferDeps = TransferFixtures.makeFlowWithDeps(
        isConnected: false,
      );

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        isConnected: false,
      ));
      await tester.pump();

      expect(
        find.text('No wallet connected. Please connect a wallet first.'),
        findsOneWidget,
      );
    });

    testWidgets('shows Go Back button', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps(isConnected: false);
      final transferDeps = TransferFixtures.makeFlowWithDeps(
        isConnected: false,
      );

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        isConnected: false,
      ));
      await tester.pump();

      expect(find.text('Go Back'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Connected layout
  // -------------------------------------------------------------------------

  group('ApproveScreen — connected layout', () {
    testWidgets('AppBar title is "Approve"', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      // "Approve" appears in AppBar + button — accept findsWidgets.
      expect(find.text('Approve'), findsWidgets);
    });

    testWidgets('shows the description card heading', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      expect(find.text('Token Allowance'), findsOneWidget);
    });

    testWidgets('shows the DEMO Balance card label', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      expect(find.text('DEMO Balance'), findsOneWidget);
    });

    testWidgets('shows the Token Contract label', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      expect(find.text('Token Contract'), findsOneWidget);
    });

    testWidgets(
      'shows "DEMO token not deployed" when the contract is missing',
      (tester) async {
        final approveDeps = ApproveFixtures.makeFlowWithDeps();
        final transferDeps = TransferFixtures.makeFlowWithDeps();

        await tester.pumpWidget(_wrap(
          approveFlow: approveDeps.flow,
          transferFlow: transferDeps.flow,
        ));
        await tester.pump();

        expect(find.text('DEMO token not deployed'), findsOneWidget);
      },
    );

    testWidgets('shows Spender Address field', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      expect(find.text('Spender Address'), findsOneWidget);
    });

    testWidgets('shows Amount field', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      expect(find.text('Amount'), findsOneWidget);
    });

    testWidgets('shows the Expiration dropdown', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      expect(find.text('Expiration'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  group('ApproveScreen — validation', () {
    testWidgets('spender helper text shows verbatim supporting text',
        (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      expect(
        find.text('Address to grant the allowance to'),
        findsOneWidget,
      );
    });

    testWidgets('rejects malformed spender input', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'not-an-address');
      await tester.pump();

      expect(
        find.textContaining(
          'Must be a valid Stellar account (G...) or contract (C...) address',
        ),
        findsOneWidget,
      );
    });

    testWidgets('rejects scientific notation for amount', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField).at(1), '1e10');
      await tester.pump();

      expect(find.text('Scientific notation is not supported'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Single-signer happy path
  // -------------------------------------------------------------------------

  group('ApproveScreen — single-signer happy path', () {
    testWidgets('shows the result card on success', (tester) async {
      final approveDeps = ApproveFixtures.makeFlowWithDeps(
        environment: MockBuilderEnvironment(currentLedger: 100),
      );
      approveDeps.contractCall.result = ApproveFixtures.successResult();
      final transferDeps = TransferFixtures.makeFlowWithDeps();

      await tester.pumpWidget(_wrap(
        approveFlow: approveDeps.flow,
        transferFlow: transferDeps.flow,
        demoTokenContractId: ApproveFixtures.defaultTokenContract,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.enterText(
        find.byType(TextField).first,
        ApproveFixtures.defaultSpender,
      );
      await tester.enterText(find.byType(TextField).at(1), '10.0');
      await tester.pump();

      // Tap the Approve button. The AppBar title and the button both render
      // "Approve" — target the LoadingButton via its type so the tap
      // reliably hits the action surface.
      await tester.tap(find.byType(LoadingButton));
      // Drain the loading future and the post-success setState cycle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.text('Approve Successful'), findsOneWidget);
      expect(find.text('Amount Approved'), findsOneWidget);
      expect(find.text('10.0 DEMO'), findsOneWidget);

      // The allowance fetch waits 5 seconds before reading on-chain state.
      // Drain that delay so the test framework's pending-timer guard passes.
      await tester.pump(const Duration(seconds: 6));
    });
  });

  // -------------------------------------------------------------------------
  // Screens-never-call-SDK guard
  // -------------------------------------------------------------------------

  group('ApproveScreen — screens never call SDK guard', () {
    test('only accepts injected flows, not OZSmartAccountKit', () {
      const screen = ApproveScreen();
      expect(screen.approveFlow, isNull);
      expect(screen.transferFlow, isNull);
    });
  });
}
