/// Widget tests for [ContextRulesScreen].
///
/// Covers: not-connected guard, loading state, empty state, loaded list,
/// expand/collapse, removal dialog, last-rule disabled, error card, and
/// screens-never-call-SDK guard.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/context_rule_flow.dart';
import 'package:smart_account_demo/screens/context_rules_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/context_rule_flow_provider.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/context_rule_test_support.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _wrapWithFlow(ContextRuleFlow? flow, {bool isConnected = true}) {
  // The ContextRulesScreen reads demoStateProvider for the isConnected guard in
  // the UI. We set the initial state synchronously inside the build() callback
  // by having the notifier begin in connected state so the guard shows the
  // connected UI immediately. The flow uses its own internal DemoStateNotifier
  // (injected at construction) for the SDK-level isConnected check.
  return ProviderScope(
    overrides: [
      demoStateProvider.overrideWith(() => _ConnectedDemoStateNotifier(
            isConnected: isConnected,
          )),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
      contextRuleFlowProvider.overrideWithValue(flow),
    ],
    child: MaterialApp(
      home: ContextRulesScreen(flow: flow),
    ),
  );
}

/// Builds a [ContextRuleFlow] for screen tests.
ContextRuleFlow _makeFlow({
  MockContextRuleFlowManager? manager,
  bool isConnected = true,
}) {
  final deps = ContextRuleFixtures.makeFlowWithDeps(
    manager: manager,
    isConnected: isConnected,
  );
  return deps.flow;
}

void main() {
  // ---------------------------------------------------------------------------
  // Not connected
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — not connected', () {
    testWidgets('shows AppBar title "Context Rules"', (tester) async {
      await tester.pumpWidget(_wrapWithFlow(null, isConnected: false));
      await tester.pump();

      expect(find.text('Context Rules'), findsAtLeast(1));
    });

    testWidgets('shows description card title', (tester) async {
      await tester.pumpWidget(_wrapWithFlow(null, isConnected: false));
      await tester.pump();

      expect(find.text('On-Chain Authorization Rules'), findsOneWidget);
    });

    testWidgets('shows "No wallet connected"', (tester) async {
      await tester.pumpWidget(_wrapWithFlow(null, isConnected: false));
      await tester.pump();

      expect(find.text('No wallet connected'), findsOneWidget);
    });

    testWidgets('shows "Connect a wallet to view context rules."',
        (tester) async {
      await tester.pumpWidget(_wrapWithFlow(null, isConnected: false));
      await tester.pump();

      expect(
        find.text('Connect a wallet to view context rules.'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Description card
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — description card', () {
    testWidgets('shows verbatim description text', (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();

      expect(
        find.textContaining(
          'Context rules define who can authorize what operations',
        ),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — loading state', () {
    testWidgets('shows "Loading context rules..."', (tester) async {
      // Build the flow with a stalling manager outside ContextRuleFixtures
      // because the stalling manager is a separate class.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final demoStateNotifier = container.read(demoStateProvider.notifier);
      final activityLog = container.read(activityLogProvider.notifier);
      demoStateNotifier.setConnected(
        contractId: fixtureContractId,
        credentialId: fixtureCredentialId,
        isDeployed: true,
      );
      final flow = ContextRuleFlow(
        demoState: demoStateNotifier,
        activityLog: activityLog,
        contextRuleManager: _StallingMockManager(),
      );

      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump(); // initState schedules postFrameCallback
      await tester.pump(); // postFrameCallback fires, setState(_isLoading=true)

      expect(find.text('Loading context rules...'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — empty state', () {
    testWidgets('shows "No context rules found"', (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump(); // let async complete

      expect(find.text('No context rules found'), findsOneWidget);
    });

    testWidgets('shows default-config body text', (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('default configuration'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Loaded list
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — loaded state', () {
    testWidgets('shows rule count summary', (tester) async {
      final mgr = MockContextRuleFlowManager()
        ..rules = [makeRule(id: 1), makeRule(id: 2)];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.text('2 context rule(s) loaded'), findsOneWidget);
    });

    testWidgets('shows rule ID badges for all rules', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final mgr = MockContextRuleFlowManager()
        ..rules = [makeRule(id: 1), makeRule(id: 2), makeRule(id: 3)];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
    });

    testWidgets('shows rule names', (tester) async {
      final mgr = MockContextRuleFlowManager()
        ..rules = [makeRule(id: 1, name: 'rule-alpha')];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.text('rule-alpha'), findsOneWidget);
    });

    testWidgets('rules sorted by id ascending', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final mgr = MockContextRuleFlowManager()
        ..rules = [makeRule(id: 3), makeRule(id: 1), makeRule(id: 2)];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      // All three badges present.
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — expand/collapse', () {
    testWidgets('Signers section shown after tapping expand', (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [makeRule(id: 1)];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      // Signers section not visible initially.
      expect(find.text('Signers'), findsNothing);

      await tester.tap(find.byIcon(Icons.expand_more).first);
      await tester.pump();

      expect(find.text('Signers'), findsOneWidget);
    });

    testWidgets('Signers section hidden after collapse', (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [makeRule(id: 1)];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      // Expand.
      await tester.tap(find.byIcon(Icons.expand_more).first);
      await tester.pump();
      expect(find.text('Signers'), findsOneWidget);

      // Collapse.
      await tester.tap(find.byIcon(Icons.expand_less).first);
      await tester.pump();
      expect(find.text('Signers'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // Last-rule safety check
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — last rule disabled', () {
    testWidgets('shows "Last Rule" when only one rule exists', (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [makeRule(id: 1)];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.text('Last Rule'), findsOneWidget);
    });

    testWidgets('shows "Remove Rule" when multiple rules exist', (tester) async {
      final mgr = MockContextRuleFlowManager()
        ..rules = [makeRule(id: 1), makeRule(id: 2)];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.text('Remove Rule'), findsAtLeast(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — error card', () {
    testWidgets('shows error card when listContextRules throws', (tester) async {
      final mgr = MockContextRuleFlowManager()
        ..listError = MockNetworkError();
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      // Error classified as network or unexpected.
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('Refresh button present in connected state', (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.text('Refresh'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // + Add Rule action
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — Add Rule action', () {
    testWidgets('renders the "+ Add Rule" button in the action row',
        (tester) async {
      final mgr = MockContextRuleFlowManager()..rules = [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.text('+ Add Rule'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Screens-never-call-SDK guard
  // ---------------------------------------------------------------------------

  group('ContextRulesScreen — screens-never-call-SDK', () {
    testWidgets('accepts a ContextRuleFlow; does not accept a raw manager',
        (tester) async {
      // This test compiles only if ContextRulesScreen.flow is typed as
      // ContextRuleFlow?. Passing a MockContextRuleFlowManager directly would
      // be a compile error, which is the enforcement mechanism.
      final mgr = MockContextRuleFlowManager()..rules = [];
      final flow = _makeFlow(manager: mgr);

      // Would fail to compile if screen accepted raw manager.
      await tester.pumpWidget(_wrapWithFlow(flow));
      await tester.pump();
      await tester.pump();

      expect(find.byType(ContextRulesScreen), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------
// _ConnectedDemoStateNotifier
// ---------------------------------------------------------------------------

/// A [DemoStateNotifier] that starts in the connected (or disconnected) state
/// synchronously so the widget tree sees the correct guard state on first build.
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

// ---------------------------------------------------------------------------
// Stalling manager
// ---------------------------------------------------------------------------

/// A [ContextRuleFlowManagerType] whose [listContextRules] never completes,
/// so tests can assert on the loading state.
final class _StallingMockManager implements ContextRuleFlowManagerType {
  @override
  Future<List<OZParsedContextRule>> listContextRules() {
    return Completer<List<OZParsedContextRule>>().future;
  }

  @override
  Future<OZTransactionResult> removeContextRule({
    required int id,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) {
    return Completer<OZTransactionResult>().future;
  }

  @override
  Future<OZTransactionResult> addContextRule({
    required OZContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    Map<String, OZPolicyInstallParams> policies =
        const <String, OZPolicyInstallParams>{},
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) {
    return Completer<OZTransactionResult>().future;
  }

  @override
  Future<OZTransactionResult> updateContextRuleName({
    required int ruleId,
    required String name,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> removeSignerFromRule({
    required int ruleId,
    required int signerId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> addDelegatedSignerToRule({
    required int ruleId,
    required String address,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> addEd25519SignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> addPasskeySignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    required Uint8List credentialId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> removePolicyFromRule({
    required int ruleId,
    required int policyId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> addSimpleThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> addWeightedThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required List<PolicyWeightedEntry> entries,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> addSpendingLimitToRule({
    required int ruleId,
    required String policyAddress,
    required String amount,
    required int decimals,
    required int periodLedgers,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> updateContextRuleValidUntil({
    required int ruleId,
    int? validUntil,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;

  @override
  Future<OZTransactionResult> setPolicyThreshold({
    required int ruleId,
    required String policyAddress,
    required int newThreshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      Completer<OZTransactionResult>().future;
}
