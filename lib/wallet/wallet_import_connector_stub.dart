/// Non-web implementation of [createImportConnector].
///
/// Returns a [ReownWalletHandler] that connects to Freighter Mobile via
/// its registry-defined deep-link scheme. Wrapping the WalletConnect URI
/// in Freighter's `wc-redirect` deep link avoids the system wallet picker
/// (which would otherwise let any installed wallet that claims `wc:`
/// intercept the pairing).
library;

import 'dart:developer' as developer;

import 'package:url_launcher/url_launcher.dart';

import '../config/demo_config.dart' as config;
import 'reown_wallet_handler.dart';
import 'wallet_connector.dart';

const String _logName = 'wallet.connector';

/// Returns the native external-wallet connector, or `null` when external-wallet
/// connect is disabled.
///
/// Reown pairing requires a project ID. When [config.reownProjectId] is blank
/// no connector is created, so [DemoStateNotifier.walletConnectorForUi] returns
/// null and every wallet-pairing surface hides — the same path taken on the
/// iOS Simulator and Android emulators. Register a free project ID at
/// https://reown.com/ and set `reownProjectId` in `lib/config/demo_config.dart`
/// to enable it.
WalletConnector? createImportConnector() {
  if (config.reownProjectId.trim().isEmpty) return null;
  return ReownWalletHandler(
    onPairingUri: _launchPairingUri,
    onSigningRequested: _wakeWalletForSigning,
  );
}

/// Eagerly initialises the connector so its relay WebSocket is open before
/// the user pairs with an external wallet. The [ReownWalletHandler.init]
/// guard ensures [WalletConnector.connect] still retries lazily if warm-up
/// did not complete.
Future<void> warmUpImportConnector(WalletConnector? connector) async {
  if (connector is ReownWalletHandler) {
    await connector.init();
  }
}

/// Forces the connector's relay WebSocket to reconnect if it has dropped.
/// Wired to [AppLifecycleState.resumed] so a returning user sees queued
/// session-settle / signing-response messages immediately instead of
/// waiting for the heartbeat to notice the dead socket.
Future<void> resumeImportConnector(WalletConnector? connector) async {
  if (connector is ReownWalletHandler) {
    await connector.ensureRelayConnected();
  }
}

/// Hands the pairing URI to Freighter Mobile via its registry-defined
/// deep link:
///   freighterwallet://wc-redirect?uri={percent-encoded WC URI}
///
/// Failures are logged but not surfaced; the session approval timeout
/// inside [ReownWalletHandler.connect] still bounds the wait if Freighter
/// Mobile is not installed or does not pick up the URI.
Future<void> _launchPairingUri(Uri uri) async {
  final encoded = Uri.encodeComponent(uri.toString());
  final freighterUri = Uri.parse('freighterwallet://wc-redirect?uri=$encoded');
  try {
    final launched = await launchUrl(freighterUri, mode: LaunchMode.externalApplication);
    if (!launched) {
      developer.log(
        'Pairing deep-link not handled by any installed app — '
        'is Freighter Mobile installed?',
        name: _logName,
      );
    }
  } catch (error, stackTrace) {
    developer.log(
      'Pairing deep-link launch threw',
      name: _logName,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Brings the wallet to the foreground so the user can approve a pending
/// signing request. Prefers the session's reported deep-link redirect; falls
/// back to Freighter Mobile's bare scheme when the wallet did not include a
/// redirect in its pairing metadata. Failures are logged but not surfaced —
/// the signing round-trip's own timeout still bounds the wait.
Future<void> _wakeWalletForSigning(Uri? walletRedirect) async {
  final target = walletRedirect ?? Uri.parse('freighterwallet://');
  try {
    final launched = await launchUrl(target, mode: LaunchMode.externalApplication);
    if (!launched) {
      developer.log(
        'Signing-wake deep-link not handled by any installed app — '
        'is Freighter Mobile installed?',
        name: _logName,
      );
    }
  } catch (error, stackTrace) {
    developer.log(
      'Signing-wake deep-link launch threw',
      name: _logName,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
