/// Web implementation of [createImportConnector].
library;

import 'wallet_connector.dart';
import 'web/freighter_wallet_handler.dart';

WalletConnector? createImportConnector() => FreighterWalletHandler();

/// Web connector (Freighter browser extension) has no eager-init step:
/// the extension lifecycle is owned by the browser, not by this app, so
/// there is no relay WebSocket to keep alive across navigation.
Future<void> warmUpImportConnector(WalletConnector? connector) async {}

/// Web connector has no relay WebSocket; nothing to reconnect.
Future<void> resumeImportConnector(WalletConnector? connector) async {}
