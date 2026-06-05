/// Widget tests for [WalletCreationScreen].
///
/// Verifies:
/// - "Passkey Name" label appears exactly once (from StyledTextField, not also
///   as a standalone Text heading).
/// - After onDeploySucceeded fires the screen swaps UndeployedResultCard for
///   DeployedResultCard.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/main_screen_flow.dart';
import 'package:smart_account_demo/flows/wallet_creation_flow.dart';
import 'package:smart_account_demo/screens/wallet_creation_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/wallet/wallet_operations_adapter.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// No-op [MainScreenFlow] that succeeds silently for all operations.
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

  @override
  WalletOperationsAdapter? buildWalletOperations() => null;
}

/// [WalletOperationsType] that returns a fixed [OZCreateWalletResult].
final class _StubWalletOps implements WalletOperationsType {
  _StubWalletOps(this._result);
  final OZCreateWalletResult _result;

  @override
  Future<OZCreateWalletResult> createWallet({
    required String userName,
    required bool autoSubmit,
    required bool autoFund,
    String? nativeTokenContract,
  }) async =>
      _result;
}

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

OZCreateWalletResult _makeSdkResult() {
  final key = Uint8List(65);
  key[0] = 0x04;
  return OZCreateWalletResult(
    credentialId: 'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU',
    contractId: 'CABC1234567890123456789012345678901234567890123456789012',
    publicKey: key,
    signedTransactionXdr: 'placeholder_xdr',
  );
}

// ---------------------------------------------------------------------------
// Widget builders
// ---------------------------------------------------------------------------

Widget _wrapForm() {
  final container = ProviderContainer(
    overrides: [
      demoStateProvider.overrideWith(DemoStateNotifier.new),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
    ],
  );
  addTearDown(container.dispose);

  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      home: const WalletCreationScreen(),
    ),
  );
}

Widget _wrapWithUndeployedFlow() {
  final container = ProviderContainer(
    overrides: [
      demoStateProvider.overrideWith(DemoStateNotifier.new),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
    ],
  );
  addTearDown(container.dispose);

  final demoState = container.read(demoStateProvider.notifier);
  final activityLog = container.read(activityLogProvider.notifier);

  final walletCreationFlow = WalletCreationFlow(
    demoState: demoState,
    activityLog: activityLog,
    walletOperations: _StubWalletOps(_makeSdkResult()),
  );

  final mainFlow = _NoOpMainScreenFlow(
    demoState: demoState,
    activityLog: activityLog,
  );

  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      home: WalletCreationScreen(
        walletCreationFlow: walletCreationFlow,
        mainScreenFlow: mainFlow,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
  });

  group('WalletCreationScreen — form labels', () {
    testWidgets('"Passkey Name" label appears exactly once', (tester) async {
      await tester.pumpWidget(_wrapForm());

      // Only the StyledTextField own label renders "Passkey Name".
      // The standalone Text heading was removed (SF-R4-12).
      expect(find.text('Passkey Name'), findsOneWidget);
    });
  });

  group('WalletCreationScreen — deploy-succeeded card swap', () {
    testWidgets(
        'swaps UndeployedResultCard to DeployedResultCard after onDeploySucceeded',
        (tester) async {
      await tester.pumpWidget(_wrapWithUndeployedFlow());

      // Enter a passkey name.
      await tester.enterText(find.byType(TextField), 'Alice');
      // Flip the auto-deploy toggle off so the flow returns isDeployed: false.
      await tester.tap(find.byType(Switch));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Create Wallet'));
      await tester.pumpAndSettle();

      // UndeployedResultCard should be visible.
      expect(find.text('Passkey Registered'), findsOneWidget);
      expect(find.text('Deploy Now'), findsOneWidget);

      // Tap Deploy Now — the NoOp main flow succeeds, onDeploySucceeded fires,
      // and the screen setState swaps to DeployedResultCard.
      await tester.tap(find.text('Deploy Now'));
      await tester.pumpAndSettle();

      expect(find.text('Wallet Created Successfully'), findsOneWidget);
      expect(find.text('Passkey Registered'), findsNothing);
    });
  });
}
