/// Widget tests for [ApprovalInboxScreen].
///
/// Covers: empty state, request-card rendering with the DECODED recipient and
/// on-chain amount (the server amount is not authoritative), account-scoped
/// listing, a successful approve (card removed + reported back), the
/// retry-report affordance after a failed report-back (never re-submits),
/// concurrent-approve disabling, a reject with a note via the dialog, the
/// server-unreachable error state, and the not-connected hint. All mocked — no
/// testnet, no network.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/approval_inbox_flow.dart';
import 'package:smart_account_demo/flows/approve_flow.dart' show ContractCallType;
import 'package:smart_account_demo/screens/approval_inbox_screen.dart';
import 'package:smart_account_demo/services/coordination_client.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/coordination_client_provider.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/widgets/empty_state_card.dart';
import 'package:smart_account_demo/widgets/loading_button.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/approval_inbox_test_support.dart';

Widget _wrap(ApprovalInboxFlowTestDeps deps, {bool isConnected = true}) {
  return ProviderScope(
    overrides: [
      demoStateProvider.overrideWith(
        () => _ConnectedDemoStateNotifier(isConnected: isConnected),
      ),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
      // The bell-badge refresh after an action resolves through this provider;
      // point it at the same fake so the widget never touches the network.
      coordinationClientProvider.overrideWithValue(deps.coordination),
    ],
    child: MaterialApp(home: ApprovalInboxScreen(flow: deps.flow)),
  );
}

void main() {
  group('ApprovalInboxScreen — empty / error states', () {
    testWidgets('shows the empty state when no escalations are pending',
        (tester) async {
      final deps = makeInboxFlow(coordination: FakeCoordinationClient());
      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      expect(find.byType(EmptyStateCard), findsOneWidget);
      expect(find.text('No pending approvals'), findsOneWidget);
    });

    testWidgets('shows an error card with retry when the server is unreachable',
        (tester) async {
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          listError: const CoordinationException('GET /requests failed: down'),
        ),
      );
      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not reach the coordination server'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('ApprovalInboxScreen — request cards', () {
    testWidgets('renders a card with the decoded rejection reason',
        (tester) async {
      // buildRequest defaults to reason 3016 == unauthorizedSigner.
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[buildRequest()],
        ),
      );
      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      expect(find.text('Unauthorized signer'), findsOneWidget);
      expect(find.widgetWithText(LoadingButton, 'Approve'), findsOneWidget);
      expect(find.widgetWithText(LoadingButton, 'Reject'), findsOneWidget);
    });

    testWidgets(
        'shows the DECODED recipient and on-chain amount, not the server amount',
        (tester) async {
      // transferArgsBase64 encodes 10.5 (105000000 base units); the server
      // amount lies.
      final request = buildRequest(
        args: transferArgsBase64(),
        amount: '5',
      );
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      expect(find.text('Recipient'), findsOneWidget);
      // transferArgsBase64 defaults to GCKE...NMPM.
      expect(find.text('GCKE...NMPM'), findsOneWidget);
      // The authoritative amount is decoded from the args.
      expect(find.text('10.5'), findsOneWidget);
      // The untrusted server amount must not stand in as the displayed value.
      expect(find.text('5'), findsNothing);
      // The badge was set from the loaded list — no second identical GET.
      expect(deps.coordination.listCount, 1);
    });

    testWidgets('lists only escalations for the connected account',
        (tester) async {
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[
            // buildRequest defaults to smartAccount == fixtureSmartAccount.
            buildRequest(id: 'mine'),
            buildRequest(id: 'other', smartAccount: fixtureTarget),
          ],
        ),
      );
      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      // Exactly one card (the connected account's) is shown.
      expect(find.widgetWithText(LoadingButton, 'Approve'), findsOneWidget);
    });

    testWidgets('approve submits, removes the card, and reports back',
        (tester) async {
      final request = buildRequest(id: 'req-approve');
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(LoadingButton, 'Approve'));
      await tester.pumpAndSettle();

      // Reported the on-chain hash back and removed the resolved card.
      expect(deps.coordination.lastApprovedId, 'req-approve');
      expect(deps.coordination.lastApprovedResultHash, 'TXHASH');
      expect(find.byType(EmptyStateCard), findsOneWidget);
    });

    testWidgets(
        'a failed report switches the card to "Retry report" and never '
        're-submits', (tester) async {
      // The card grows once it switches to "Retry report"; give the test a
      // viewport tall enough that the button stays on-screen.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final request = buildRequest(id: 'req-retry');
      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[request],
        approveError:
            const CoordinationException('report failed', statusCode: 500),
      );
      final deps = makeInboxFlow(coordination: fake);
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'TXHASH');

      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(LoadingButton, 'Approve'));
      await tester.pumpAndSettle();

      // Confirmed on-chain but reporting failed: the affordance switched.
      expect(find.widgetWithText(LoadingButton, 'Retry report'), findsOneWidget);
      expect(find.widgetWithText(LoadingButton, 'Approve'), findsNothing);
      expect(deps.contractCall.callCount, 1);

      // The server recovers; retry-report only reports — no second submission.
      fake.approveError = null;
      await tester.tap(find.widgetWithText(LoadingButton, 'Retry report'));
      await tester.pumpAndSettle();

      expect(deps.coordination.lastApprovedResultHash, 'TXHASH');
      expect(deps.contractCall.callCount, 1);
      expect(find.byType(EmptyStateCard), findsOneWidget);
    });

    testWidgets('disables every card while one approval is in flight',
        (tester) async {
      // Two tall cards: enlarge the viewport so both are laid out (the lazy
      // sliver list would otherwise not build the second one off-screen).
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[
          buildRequest(id: 'r1'),
          buildRequest(id: 'r2'),
        ],
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final activityLog = container.read(activityLogProvider.notifier);
      final blocking = _BlockingContractCall();
      final flow = ApprovalInboxFlow(
        coordination: fake,
        activityLog: activityLog,
        resolveContractCall: () => blocking,
        resolveConnectedAccount: () => fixtureSmartAccount,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            demoStateProvider.overrideWith(
              () => _ConnectedDemoStateNotifier(isConnected: true),
            ),
            activityLogProvider.overrideWith(ActivityLogNotifier.new),
            coordinationClientProvider.overrideWithValue(fake),
          ],
          child: MaterialApp(home: ApprovalInboxScreen(flow: flow)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(LoadingButton, 'Approve'), findsNWidgets(2));

      // Start approving the first card; it blocks inside contractCall.
      await tester.tap(find.widgetWithText(LoadingButton, 'Approve').first);
      await tester.pump();

      // The remaining card's Approve button is now disabled.
      final approveButtons = find.widgetWithText(FilledButton, 'Approve');
      expect(approveButtons, findsOneWidget);
      expect(tester.widget<FilledButton>(approveButtons).onPressed, isNull);

      // Release the in-flight approval and settle.
      blocking.completer
          .complete(const OZTransactionResult(success: true, hash: 'H'));
      await tester.pumpAndSettle();
    });

    testWidgets(
        'while approving, only the Approve button spins (Reject does not)',
        (tester) async {
      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[buildRequest(id: 'r1')],
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final activityLog = container.read(activityLogProvider.notifier);
      final blocking = _BlockingContractCall();
      final flow = ApprovalInboxFlow(
        coordination: fake,
        activityLog: activityLog,
        resolveContractCall: () => blocking,
        resolveConnectedAccount: () => fixtureSmartAccount,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            demoStateProvider.overrideWith(
              () => _ConnectedDemoStateNotifier(isConnected: true),
            ),
            activityLogProvider.overrideWith(ActivityLogNotifier.new),
            coordinationClientProvider.overrideWithValue(fake),
          ],
          child: MaterialApp(home: ApprovalInboxScreen(flow: flow)),
        ),
      );
      await tester.pumpAndSettle();

      // Start approving; the call blocks inside contractCall.
      await tester.tap(find.widgetWithText(LoadingButton, 'Approve'));
      await tester.pump();

      // The Approve button is in its loading state...
      expect(find.text('Approving...'), findsOneWidget);
      // ...and the Reject button is NOT: it still renders its idle label.
      // (A spinning Reject would show a bare indicator with no 'Reject' text.)
      expect(find.widgetWithText(LoadingButton, 'Reject'), findsOneWidget);
      // Exactly one spinner on screen, inside the Approve button.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      blocking.completer
          .complete(const OZTransactionResult(success: true, hash: 'H'));
      await tester.pumpAndSettle();
    });

    testWidgets('reject opens the note dialog and reports the rejection',
        (tester) async {
      final request = buildRequest(id: 'req-reject');
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );

      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      // Tapping Reject opens a modal note dialog. The card's reject button
      // stays in its loading state while the dialog is open (the action future
      // is awaiting the dialog), so pump explicitly through the transition
      // rather than pumpAndSettle.
      await tester.tap(find.widgetWithText(LoadingButton, 'Reject'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The dialog is open; enter a note and confirm via its FilledButton.
      expect(find.text('Reject escalation'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'nope');
      await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
      await tester.pumpAndSettle();

      expect(deps.coordination.lastRejectedId, 'req-reject');
      expect(deps.coordination.lastRejectedNote, 'nope');
      expect(find.byType(EmptyStateCard), findsOneWidget);
    });
  });

  group('ApprovalInboxScreen — approved results', () {
    testWidgets(
        'a successful approve shows a persistent copyable hash with an '
        'explorer link', (tester) async {
      final request = buildRequest(id: 'req-approved');
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'FULLTXHASH1234567890');

      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(LoadingButton, 'Approve'));
      await tester.pumpAndSettle();

      // The Approved section persists the full hash as selectable text (its
      // own SelectableText, with the pending card now gone) plus a Copy control
      // and a "View on Explorer" affordance.
      expect(find.text('Approved'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      // The FULL hash is on screen (selectable for copy), never truncated.
      final selectable =
          tester.widget<SelectableText>(find.byType(SelectableText));
      expect(selectable.data, 'FULLTXHASH1234567890');
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('View on Explorer'), findsOneWidget);

      // The pending card was removed; only the persistent result remains.
      expect(find.byType(EmptyStateCard), findsOneWidget);

      // Tapping Copy writes the FULL hash (not a truncated form) to the system
      // clipboard channel.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, 'FULLTXHASH1234567890');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets(
        'a confirmed-on-chain approval whose report failed persists the '
        'copyable hash while the card offers Retry report', (tester) async {
      // The card grows once it switches to "Retry report"; give the test a
      // viewport tall enough that both it and the Approved section fit.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final request = buildRequest(id: 'req-confirmed-hash');
      final fake = FakeCoordinationClient(
        pending: <CoordinationRequest>[request],
        approveError:
            const CoordinationException('report failed', statusCode: 500),
      );
      final deps = makeInboxFlow(coordination: fake);
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: 'FULLTXHASHCONFIRMED1');

      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(LoadingButton, 'Approve'));
      await tester.pumpAndSettle();

      // The report failed, so the card switched to Retry report and never
      // re-submits.
      expect(find.widgetWithText(LoadingButton, 'Retry report'), findsOneWidget);
      expect(deps.contractCall.callCount, 1);

      // The confirmed hash is persisted in the Approved section as selectable
      // text (the full hash) with Copy and explorer affordances, rather than
      // living only in the transient error snackbar. The still-present
      // "Retry report" card also renders monospace values as SelectableText, so
      // match the persisted hash by its exact data.
      expect(find.text('Approved'), findsOneWidget);
      final hashFinder = find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == 'FULLTXHASHCONFIRMED1',
      );
      expect(hashFinder, findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('View on Explorer'), findsOneWidget);

      // A successful retry-report replaces the entry (no duplicate) and removes
      // the pending card.
      fake.approveError = null;
      await tester.tap(find.widgetWithText(LoadingButton, 'Retry report'));
      await tester.pumpAndSettle();

      expect(deps.contractCall.callCount, 1);
      expect(deps.coordination.lastApprovedResultHash, 'FULLTXHASHCONFIRMED1');
      // Still exactly one persisted result (deduped by request id); with the
      // pending card removed it is now the only SelectableText on screen.
      expect(hashFinder, findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byType(EmptyStateCard), findsOneWidget);
    });

    testWidgets(
        'a confirmed-on-chain approval without a hash degrades gracefully',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final request = buildRequest(id: 'req-nohash');
      final deps = makeInboxFlow(
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[request],
        ),
      );
      // Confirmed on-chain but the SDK returned no transaction hash.
      deps.contractCall.result =
          const OZTransactionResult(success: true, hash: '');

      await tester.pumpWidget(_wrap(deps));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(LoadingButton, 'Approve'));
      await tester.pumpAndSettle();

      // The Approved section records the outcome with a plain notice and no
      // copy/explorer control there is nothing to copy.
      expect(find.text('Approved'), findsOneWidget);
      expect(
        find.textContaining('Confirmed on-chain (no transaction hash returned)'),
        findsOneWidget,
      );
      expect(find.text('Copy'), findsNothing);
      expect(find.text('View on Explorer'), findsNothing);
    });
  });

  group('ApprovalInboxScreen — not connected', () {
    testWidgets(
        'shows the connect hint and lists nothing (escalations are '
        'account-scoped)', (tester) async {
      final deps = makeInboxFlow(
        connected: false,
        coordination: FakeCoordinationClient(
          pending: <CoordinationRequest>[buildRequest()],
        ),
      );
      await tester.pumpWidget(_wrap(deps, isConnected: false));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connect a wallet to review escalations'),
          findsOneWidget);
      // With no connected account there is nothing to scope to: no cards.
      expect(find.widgetWithText(LoadingButton, 'Approve'), findsNothing);
      expect(find.byType(EmptyStateCard), findsOneWidget);
    });
  });
}

/// A [DemoStateNotifier] that begins connected (or not) so the screen renders
/// the relevant branch without a real wallet connection.
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
        contractId: fixtureSmartAccount,
        credentialId: 'cred',
      );
    }
    return const WalletConnectionState.disconnected();
  }
}

/// A [ContractCallType] whose call blocks on an external [Completer], so a
/// widget test can hold an approval in flight while asserting that every card's
/// Approve action is disabled.
final class _BlockingContractCall implements ContractCallType {
  final Completer<OZTransactionResult> completer =
      Completer<OZTransactionResult>();

  @override
  Future<OZTransactionResult> contractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
  }) {
    return completer.future;
  }
}
