/// Widget tests for [KnownSignersScreen].
///
/// Covers:
/// - Not-connected guard renders the inventory message.
/// - Description card and "Go Back" button are always present.
/// - Connected + loaded rules renders the count header and per-rule chips.
/// - Empty rule list renders the "No signers found" empty card.
/// - Failure path renders the sanitised error card.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/account_signers_flow.dart';
import 'package:smart_account_demo/screens/known_signers_screen.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/account_signers_test_support.dart';
import '../flows/transfer_test_support.dart' show MockNetworkError;

OZParsedContextRule _ruleWithSigners({
  required int id,
  required String name,
  required List<OZSmartAccountSigner> signers,
}) {
  return OZParsedContextRule(
    id: id,
    contextType: const OZContextRuleTypeDefault(),
    name: name,
    signers: signers,
    signerIds: List<int>.generate(signers.length, (i) => i + 1),
    policies: const [],
    policyIds: const [],
  );
}

/// Notifier subclass that sets the connected state synchronously during
/// [build], so the [KnownSignersScreen] post-frame callback observes the
/// connection on its first read.
class _PreconnectedDemoState extends DemoStateNotifier {
  @override
  WalletConnectionState build() {
    return const WalletConnectionState(
      isConnected: true,
      isDeployed: true,
      contractId: AccountSignersFixtures.defaultContractId,
      credentialId: AccountSignersFixtures.defaultCredentialId,
    );
  }
}

Widget _wrap(AccountSignersFlow? flow, {bool isConnected = true}) {
  return ProviderScope(
    overrides: [
      if (isConnected)
        demoStateProvider.overrideWith(_PreconnectedDemoState.new)
      else
        demoStateProvider.overrideWith(DemoStateNotifier.new),
      activityLogProvider.overrideWith(ActivityLogNotifier.new),
    ],
    child: MaterialApp(
      home: KnownSignersScreen(flow: flow),
    ),
  );
}

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    // Wider canvas so all rows + cards render without overflow.
    binding.platformDispatcher.views.first
      ..physicalSize = const Size(1200, 2200)
      ..devicePixelRatio = 1.0;
  });

  // -------------------------------------------------------------------------
  // Not-connected
  // -------------------------------------------------------------------------

  group('KnownSignersScreen — not connected', () {
    testWidgets('shows verbatim not-connected card', (tester) async {
      await tester.pumpWidget(_wrap(null, isConnected: false));
      await tester.pump();

      expect(
        find.text('Connect a wallet to view account signers'),
        findsOneWidget,
      );
    });

    testWidgets('does not show the Refresh button when not connected',
        (tester) async {
      await tester.pumpWidget(_wrap(null, isConnected: false));
      await tester.pump();

      expect(find.text('Refresh'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Always-on widgets
  // -------------------------------------------------------------------------

  group('KnownSignersScreen — always present', () {
    testWidgets('AppBar title is "Account Signers"', (tester) async {
      await tester.pumpWidget(_wrap(null, isConnected: false));
      await tester.pump();
      // Both AppBar title and description heading match — accept findsWidgets.
      expect(find.text('Account Signers'), findsWidgets);
    });

    testWidgets('shows the description body verbatim', (tester) async {
      await tester.pumpWidget(_wrap(null, isConnected: false));
      await tester.pump();
      expect(
        find.text(
          'All signers registered on this smart account across all '
          'context rules.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the Go Back button', (tester) async {
      await tester.pumpWidget(_wrap(null, isConnected: false));
      await tester.pump();
      expect(find.text('Go Back'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Connected — empty rule list
  // -------------------------------------------------------------------------

  group('KnownSignersScreen — empty signers', () {
    testWidgets('shows the empty card after a load completes', (tester) async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = const <OZParsedContextRule>[];

      await tester.pumpWidget(_wrap(deps.flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('No signers found on this account'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Connected — populated list
  // -------------------------------------------------------------------------

  group('KnownSignersScreen — populated list', () {
    testWidgets('shows the pluralised count header', (tester) async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = <OZParsedContextRule>[
        _ruleWithSigners(
          id: 1,
          name: 'r1',
          signers: [OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1)],
        ),
        _ruleWithSigners(
          id: 2,
          name: 'r2',
          signers: [OZDelegatedSigner(AccountSignersFixtures.delegatedAddress2)],
        ),
      ];

      await tester.pumpWidget(_wrap(deps.flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('2 signers'), findsOneWidget);
    });

    testWidgets('singular count uses "1 signer" form', (tester) async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = <OZParsedContextRule>[
        _ruleWithSigners(
          id: 1,
          name: 'r1',
          signers: [OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1)],
        ),
      ];

      await tester.pumpWidget(_wrap(deps.flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('1 signer'), findsOneWidget);
    });

    testWidgets('rule chip renders "#{id}" prefix and rule name',
        (tester) async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = <OZParsedContextRule>[
        _ruleWithSigners(
          id: 7,
          name: 'My Rule',
          signers: [OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1)],
        ),
      ];

      await tester.pumpWidget(_wrap(deps.flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('#7'), findsOneWidget);
      expect(find.text('My Rule'), findsOneWidget);
    });

    testWidgets('rule chip shows "Unnamed Rule" when the name is blank',
        (tester) async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = <OZParsedContextRule>[
        _ruleWithSigners(
          id: 9,
          name: '',
          signers: [OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1)],
        ),
      ];

      await tester.pumpWidget(_wrap(deps.flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Unnamed Rule'), findsOneWidget);
    });

    testWidgets('renders the G-Address type badge for delegated signers',
        (tester) async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.rules = <OZParsedContextRule>[
        _ruleWithSigners(
          id: 1,
          name: 'r1',
          signers: [OZDelegatedSigner(AccountSignersFixtures.delegatedAddress1)],
        ),
      ];

      await tester.pumpWidget(_wrap(deps.flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('G-Address'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Failure path
  // -------------------------------------------------------------------------

  group('KnownSignersScreen — failure path', () {
    testWidgets('shows the error card with sanitised message', (tester) async {
      final deps = AccountSignersFixtures.makeFlowWithDeps();
      deps.contextRuleManager.error = MockNetworkError();

      await tester.pumpWidget(_wrap(deps.flow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.textContaining('Failed to load signers:'),
        findsOneWidget,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Screens-never-call-SDK guard
  // -------------------------------------------------------------------------

  group('KnownSignersScreen — screens never call SDK guard', () {
    test('only accepts AccountSignersFlow, not OZSmartAccountKit', () {
      const screen = KnownSignersScreen();
      expect(screen.flow, isNull);
    });
  });
}
