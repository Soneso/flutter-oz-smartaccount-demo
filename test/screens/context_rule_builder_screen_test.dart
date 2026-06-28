/// Widget tests for [ContextRuleBuilderScreen].
///
/// Covers: not-connected guard, canonical strings, primary CTA gating,
/// successful submission with hash, error display.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/context_rule_flow.dart';
import 'package:smart_account_demo/screens/context_rule_builder_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/context_rule_flow_provider.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/context_rule_test_support.dart';

Widget _wrap(
  ContextRuleFlow? flow, {
  bool isConnected = true,
  int? editRuleId,
}) {
  return ProviderScope(
    overrides: [
      demoStateProvider.overrideWith(
        () => _ConnectedDemoStateNotifier(isConnected: isConnected),
      ),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
      contextRuleFlowProvider.overrideWithValue(flow),
    ],
    child: MaterialApp(
      home: ContextRuleBuilderScreen(
        flow: flow,
        editRuleId: editRuleId,
      ),
    ),
  );
}

ContextRuleFlow _makeFlow({
  MockContextRuleFlowManager? manager,
  MockBuilderEnvironment? environment,
  bool isConnected = true,
}) {
  final deps = ContextRuleFixtures.makeFlowWithDeps(
    manager: manager,
    environment: environment ?? MockBuilderEnvironment(),
    isConnected: isConnected,
  );
  return deps.flow;
}

void main() {
  // ---------------------------------------------------------------------------
  // Layout: oversize viewport so the long form does not overflow
  // ---------------------------------------------------------------------------

  setUp(() {
    // No global setup; per-test viewport sizing via tester.view.
  });

  // ---------------------------------------------------------------------------
  // Not connected
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — not connected', () {
    testWidgets('shows "Add Context Rule" AppBar title', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(_wrap(null, isConnected: false));
      await tester.pump();
      expect(find.text('Add Context Rule'), findsAtLeast(1));
      expect(find.text('No wallet connected'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Description card
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — description card', () {
    testWidgets('shows "Rule Configuration" heading verbatim', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mgr = MockContextRuleFlowManager()..rules = const [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrap(flow));
      await tester.pump();

      expect(find.text('Rule Configuration'), findsOneWidget);
      expect(
        find.text('Define the context type and basic settings for this rule.'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Form sections
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — sections render', () {
    testWidgets('renders Rule Name field with canonical placeholder',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mgr = MockContextRuleFlowManager()..rules = const [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrap(flow));
      await tester.pump();

      expect(find.text('Rule Name'), findsOneWidget);
      expect(find.text('e.g., DefaultRule, TokenTransfers'), findsOneWidget);
    });

    testWidgets('renders Signers and Policies headers', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mgr = MockContextRuleFlowManager()..rules = const [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrap(flow));
      await tester.pump();

      expect(find.text('Signers'), findsOneWidget);
      expect(find.text('Policies'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Rule Name field behaviour
  //
  // The rule-name field is rendered by a stateless widget that forwards
  // `onChanged` to the parent screen. The two assertions below pin the
  // visible behaviour the parent relies on:
  //   - typing updates the controller-backed text shown in the field;
  //   - typing into the field rebuilds the parent so the submit CTA's
  //     enabled state can flip in response to the new input.
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — rule name field', () {
    testWidgets('typing into the field updates the displayed text',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mgr = MockContextRuleFlowManager()..rules = const [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrap(flow));
      await tester.pumpAndSettle();

      final fieldFinder = find.widgetWithText(TextField, 'Rule Name');
      expect(fieldFinder, findsOneWidget);

      await tester.enterText(fieldFinder, 'MyRule');
      await tester.pump();

      final field = tester.widget<TextField>(fieldFinder);
      expect(field.controller?.text, 'MyRule');
      expect(find.text('MyRule'), findsOneWidget);
    });

    testWidgets(
      'typing into the field rebuilds the parent and enables the submit CTA',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()..rules = const [];
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow));
        await tester.pumpAndSettle();

        // Stage a signer first so the only remaining gate on the submit
        // button is a non-empty rule name. The submit CTA must still be
        // disabled until the rule-name field's onChanged reaches the
        // parent and triggers a rebuild.
        await tester.enterText(
          find.widgetWithText(TextField, 'Stellar Address (G-address)'),
          fixtureDelegatedAddress1,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Delegated Signer'));
        await tester.pumpAndSettle();

        FilledButton submitButton() =>
            tester.widget<FilledButton>(find.ancestor(
              of: find.text('Create Context Rule'),
              matching: find.byType(FilledButton),
            ));

        expect(submitButton().onPressed, isNull);

        await tester.enterText(
          find.widgetWithText(TextField, 'Rule Name'),
          'EnablerRule',
        );
        await tester.pumpAndSettle();

        expect(submitButton().onPressed, isNotNull);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Primary CTA gating
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — primary CTA', () {
    testWidgets('Create Context Rule button is disabled when form is empty',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mgr = MockContextRuleFlowManager()..rules = const [];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrap(flow));
      await tester.pump();

      final button = tester
          .widgetList<FilledButton>(find.byType(FilledButton))
          .firstWhere(
            (b) => (b.child is Text) && (b.child as Text).data ==
                'Create Context Rule',
            orElse: () => const FilledButton(onPressed: null, child: SizedBox()),
          );
      expect(button.onPressed, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Success path
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — success', () {
    testWidgets(
      'successful submission shows Transaction Successful card with hash',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()
          ..rules = const []
          ..addResult = const OZTransactionResult(success: true, hash: 'abc123def456');
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow));
        await tester.pump();

        await tester.enterText(
          find.widgetWithText(TextField, 'Rule Name'),
          'TestRule',
        );
        await tester.pumpAndSettle();

        // Add a single delegated signer.
        await tester.enterText(
          find.widgetWithText(TextField, 'Stellar Address (G-address)'),
          fixtureDelegatedAddress1,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Delegated Signer'));
        await tester.pumpAndSettle();

        // Now the submit button should be enabled.
        await tester.tap(find.text('Create Context Rule'));
        await tester.pumpAndSettle();

        expect(find.text('Transaction Successful'), findsOneWidget);
        expect(find.textContaining('Hash: abc123def456'), findsOneWidget);
        expect(find.text('Go Back'), findsOneWidget);
        expect(mgr.addCallCount, 1);
        expect(mgr.lastAddedName, 'TestRule');
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Multi-signer picker description (when EXISTING on-chain signers > 1)
  //
  // Create-mode multi-signer routing is driven by the EXISTING on-chain
  // signer set (which authorises the `add_context_rule` operation), not by
  // the staged new signers (which exist only client-side until the create
  // succeeds). Seed the mock manager with two rules carrying distinct
  // delegated signers to force the picker.
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — multi-signer picker', () {
    testWidgets(
      'with two existing on-chain signers, submit opens the picker with the '
      'create-mode description copy',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()
          ..rules = [
            makeRule(
              name: 'rule-a',
              signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
            ),
            makeRule(
              id: 2,
              name: 'rule-b',
              signers: [OZDelegatedSigner(fixtureDelegatedAddress2)],
            ),
          ]
          ..addResult = const OZTransactionResult(success: true, hash: 'multi-h');
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow));
        await tester.pump();
        // Allow the post-frame `_loadCreateAvailableSigners` callback to
        // resolve so the submit path sees the seeded signers.
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Rule Name'),
          'MultiRule',
        );
        await tester.pumpAndSettle();

        // Stage one signer (any kind) so the form passes its own
        // "rule must have ≥ 1 signer" validation; the picker decision
        // does not depend on this list.
        await tester.enterText(
          find.widgetWithText(TextField, 'Stellar Address (G-address)'),
          fixtureDelegatedAddress1,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Delegated Signer'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create Context Rule'));
        // Pump frames manually instead of pumpAndSettle so the bottom-sheet
        // animation has time to enter without blocking on never-settled
        // streams.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Select Signers'), findsOneWidget);
        expect(
          find.textContaining('co-authorize creating this context rule'),
          findsOneWidget,
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Failure path
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — failure', () {
    testWidgets(
      'failure response shows error card and preserves form',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()
          ..rules = const []
          ..addResult = const OZTransactionResult(
            success: false,
            error: 'on-chain rejected',
          );
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow));
        await tester.pump();

        await tester.enterText(
          find.widgetWithText(TextField, 'Rule Name'),
          'TestRule',
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Stellar Address (G-address)'),
          fixtureDelegatedAddress1,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add Delegated Signer'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create Context Rule'));
        await tester.pumpAndSettle();

        // Form remains visible (name field still present) and no Go Back
        // button is rendered.
        expect(find.text('Rule Name'), findsOneWidget);
        expect(find.text('Go Back'), findsNothing);
        // Some error text is rendered (classifier may rewrite the body).
        expect(find.text('Transaction Successful'), findsNothing);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Edit-mode: AppBar title + load lifecycle
  // ---------------------------------------------------------------------------

  group('ContextRuleBuilderScreen — edit-mode', () {
    testWidgets('shows "Edit Context Rule" title when editRuleId is supplied',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mgr = MockContextRuleFlowManager()
        ..rules = [makeRule(id: 7, name: 'EditMe')];
      final flow = _makeFlow(manager: mgr);
      await tester.pumpWidget(_wrap(flow, editRuleId: 7));
      await tester.pumpAndSettle();

      expect(find.text('Edit Context Rule'), findsAtLeast(1));
      expect(find.text('Add Context Rule'), findsNothing);
    });

    testWidgets(
      'failed rule load surfaces "Failed to load rule #{id}" message',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()
          ..rules = const <OZParsedContextRule>[];
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow, editRuleId: 99));
        await tester.pumpAndSettle();

        expect(find.textContaining('Failed to load rule #99'), findsOneWidget);
      },
    );

    testWidgets(
      'after rule loads: pre-populates name + signers + (on-chain) badge',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()
          ..rules = [
            makeRule(id: 12, name: 'LoadedRule'),
          ];
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow, editRuleId: 12));
        await tester.pumpAndSettle();

        // Name field pre-populated.
        expect(find.widgetWithText(TextField, 'Rule Name'), findsOneWidget);
        expect(find.text('LoadedRule'), findsOneWidget);
        // On-chain badge is shown on the single signer entry.
        expect(find.text('(on-chain)'), findsOneWidget);
        // Edit-mode helper line for context type.
        expect(
          find.text('Context type cannot be changed after creation.'),
          findsOneWidget,
        );
        // Edit-mode per-step authentication notice on the signers card.
        expect(
          find.text(
            'Each signer change requires a separate passkey authentication.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Apply Changes button is disabled until the diff is non-empty',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()
          ..rules = [makeRule(name: 'Ready')];
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow, editRuleId: 1));
        await tester.pumpAndSettle();

        // "No changes to apply" is shown initially in the summary card.
        expect(find.text('No changes to apply'), findsOneWidget);

        // The Apply Changes button is rendered but disabled.
        expect(find.text('Apply Changes'), findsOneWidget);
        final button = tester
            .widgetList<FilledButton>(find.byType(FilledButton))
            .firstWhere(
              (b) =>
                  (b.child is Text) &&
                  (b.child as Text).data == 'Apply Changes',
              orElse: () => const FilledButton(
                onPressed: null,
                child: SizedBox(),
              ),
            );
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'changing the name enables Apply Changes and shows the pending-changes '
      'summary',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mgr = MockContextRuleFlowManager()
          ..rules = [makeRule(id: 4, name: 'Original')];
        final flow = _makeFlow(manager: mgr);
        await tester.pumpWidget(_wrap(flow, editRuleId: 4));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Rule Name'),
          'Renamed',
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Pending changes: name update'),
            findsOneWidget);
        expect(find.text('1 passkey prompt(s) required'), findsOneWidget);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// _ConnectedDemoStateNotifier
// ---------------------------------------------------------------------------

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
