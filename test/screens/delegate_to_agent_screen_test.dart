/// Widget tests for [DelegateToAgentScreen].
///
/// Covers: not-connected guard, connected form rendering, agent-key validation,
/// and a successful delegation rendering the confirmation card. All mocked —
/// no testnet, no network.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/context_rule_flow.dart'
    show ledgersPerDay;
import 'package:smart_account_demo/flows/delegate_to_agent_flow.dart';
import 'package:smart_account_demo/screens/delegate_to_agent_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/widgets/loading_button.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/context_rule_test_support.dart';

DelegateToAgentFlow _makeFlow(MockContextRuleFlowManager manager) {
  // MockBuilderEnvironment defaults to currentLedger 50000 and the testnet
  // Ed25519 verifier, which the assertions below rely on.
  final deps = ContextRuleFixtures.makeFlowWithDeps(
    manager: manager,
    environment: MockBuilderEnvironment(),
  );
  return DelegateToAgentFlow(
    contextRuleFlow: deps.flow,
    activityLog: deps.activityLog,
  );
}

/// Sizes the test surface tall enough to lay out and build the whole form,
/// so the bottom submit button is never disposed by the lazy [ListView] when
/// a top field takes focus.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _wrap(DelegateToAgentFlow? flow, {bool isConnected = true}) {
  return ProviderScope(
    overrides: [
      demoStateProvider.overrideWith(
        () => _ConnectedDemoStateNotifier(isConnected: isConnected),
      ),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
    ],
    child: MaterialApp(home: DelegateToAgentScreen(flow: flow)),
  );
}

void main() {
  group('DelegateToAgentScreen — not connected', () {
    testWidgets('shows the not-connected card', (tester) async {
      await tester.pumpWidget(_wrap(null, isConnected: false));
      await tester.pump();

      expect(find.text('Delegate to Agent'), findsAtLeast(1));
      expect(
        find.textContaining('No wallet connected'),
        findsOneWidget,
      );
    });
  });

  group('DelegateToAgentScreen — connected form', () {
    testWidgets('renders the form fields and submit button', (tester) async {
      _useTallSurface(tester);
      final manager = MockContextRuleFlowManager()
        ..addResult = successResult(hash: 'h');
      await tester.pumpWidget(_wrap(_makeFlow(manager)));
      await tester.pump();

      expect(find.widgetWithText(TextField, 'Agent Ed25519 Public Key (hex)'),
          findsOneWidget);
      expect(find.widgetWithText(TextField, 'Token Contract'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Spending Limit'), findsOneWidget);
      expect(find.text('Spending Limit Period'), findsOneWidget);
      expect(find.text('Rule Expires In'), findsOneWidget);
      expect(find.byType(LoadingButton), findsOneWidget);
    });

    testWidgets('flags a malformed agent key', (tester) async {
      _useTallSurface(tester);
      final manager = MockContextRuleFlowManager()
        ..addResult = successResult(hash: 'h');
      await tester.pumpWidget(_wrap(_makeFlow(manager)));
      await tester.pump();

      await tester.enterText(
        find.widgetWithText(TextField, 'Agent Ed25519 Public Key (hex)'),
        'not-a-key',
      );
      await tester.pump();

      expect(
        find.textContaining('Must be 64 hex characters'),
        findsOneWidget,
      );
    });

    testWidgets('successful delegation shows the confirmation card',
        (tester) async {
      _useTallSurface(tester);
      final manager = MockContextRuleFlowManager()
        ..addResult = successResult(hash: 'delegationhash');
      final agentKey =
          Util.bytesToHex(Uint8List.fromList(KeyPair.random().publicKey));

      await tester.pumpWidget(_wrap(_makeFlow(manager)));
      await tester.pump();

      await tester.enterText(
        find.widgetWithText(TextField, 'Agent Ed25519 Public Key (hex)'),
        agentKey,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Spending Limit'),
        '100',
      );
      await tester.pump();

      // Tap the submit button by type; its label renders via ButtonLabel and
      // the AppBar title shares the same text.
      await tester.tap(find.byType(LoadingButton));
      await tester.pumpAndSettle();

      // The composition reached the manager exactly once via the single-signer
      // path, and the screen rendered the confirmation.
      expect(manager.addCallCount, 1);
      expect(manager.lastAddedValidUntil, 50000 + ledgersPerDay);
      expect(manager.lastAddedSelectedSigners, isEmpty);
      expect(find.text('Agent Authorised'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });
  });
}

/// A [DemoStateNotifier] that begins connected so the screen shows the
/// form branch without a real wallet connection.
final class _ConnectedDemoStateNotifier extends DemoStateNotifier {
  _ConnectedDemoStateNotifier({required bool isConnected})
      : _startConnected = isConnected;

  final bool _startConnected;

  @override
  WalletConnectionState build() {
    if (_startConnected) {
      return const WalletConnectionState(
        isConnected: true,
        isDeployed: true,
        contractId: fixtureContractId,
        credentialId: fixtureCredentialId,
      );
    }
    return const WalletConnectionState.disconnected();
  }
}
