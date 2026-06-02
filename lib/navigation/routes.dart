/// Navigation layer: go_router typed routes for the demo app.
///
/// All route declarations live here. Screens never navigate by string path;
/// they call [context.go] with an [AppRoutes] constant.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../screens/approve_screen.dart';
import '../screens/context_rule_builder_screen.dart';
import '../screens/context_rules_screen.dart';
import '../screens/known_signers_screen.dart';
import '../screens/main_screen.dart';
import '../screens/transfer_screen.dart';
import '../screens/wallet_connection_screen.dart';
import '../screens/wallet_creation_screen.dart';

// ---------------------------------------------------------------------------
// Route path constants
// ---------------------------------------------------------------------------

/// Route path strings. Use these constants instead of hard-coded strings.
abstract final class AppRoutes {
  static const String main = '/';
  static const String walletCreation = '/wallet-creation';
  static const String walletConnection = '/wallet-connection';
  static const String transfer = '/transfer';

  static const String contextRules = '/context-rules';

  /// Context Rule Builder. Accepts an optional `editRuleId` query parameter
  /// to switch the screen into edit-mode for that rule. When absent, the
  /// screen opens in create-mode.
  static const String contextRuleBuilder = '/context-rule-builder';

  /// Query-parameter name used to switch the builder route into edit mode.
  static const String editRuleIdParam = 'editRuleId';

  /// Account Signers — read-only list of all signers across context rules.
  static const String accountSigners = '/account-signers';

  /// Approve — token spending allowance for another address.
  static const String approve = '/approve';
}

// ---------------------------------------------------------------------------
// Router configuration
// ---------------------------------------------------------------------------

/// The application's [GoRouter] instance.
///
/// All routes are declared here.
final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.main,
  routes: [
    GoRoute(
      path: AppRoutes.main,
      builder: (context, state) => const MainScreen(),
    ),
    GoRoute(
      path: AppRoutes.walletCreation,
      builder: (context, state) => const WalletCreationScreen(),
    ),
    GoRoute(
      path: AppRoutes.walletConnection,
      builder: (context, state) => const WalletConnectionScreen(),
    ),
    GoRoute(
      path: AppRoutes.transfer,
      builder: (context, state) => const TransferScreen(),
    ),
    GoRoute(
      path: AppRoutes.contextRules,
      builder: (context, state) => const ContextRulesScreen(),
    ),
    GoRoute(
      path: AppRoutes.contextRuleBuilder,
      builder: (context, state) {
        final raw =
            state.uri.queryParameters[AppRoutes.editRuleIdParam];
        final editRuleId = raw != null ? int.tryParse(raw) : null;
        return ContextRuleBuilderScreen(editRuleId: editRuleId);
      },
    ),
    GoRoute(
      path: AppRoutes.accountSigners,
      builder: (context, state) => const KnownSignersScreen(),
    ),
    GoRoute(
      path: AppRoutes.approve,
      builder: (context, state) => const ApproveScreen(),
    ),
  ],
);

/// Back-button handler used by every in-app AppBar `leading` icon.
///
/// Pops the current route when a back stack exists (so the previous screen
/// slides in with the standard reverse animation). Falls back to
/// `go(AppRoutes.main)` for deep-linked or page-refreshed routes that have
/// no pop history, where pop would otherwise leave a blank page.
void popOrGoMain(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRoutes.main);
  }
}
