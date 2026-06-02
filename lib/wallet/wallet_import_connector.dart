/// Platform-conditional factory for a one-shot wallet connector used by
/// the "Import from Freighter" button on the Context Rule Builder.
///
/// Web → FreighterWalletHandler. Native → ReownWalletHandler (Freighter
/// Mobile via deep link).
library;

export 'wallet_import_connector_stub.dart'
    if (dart.library.html) 'wallet_import_connector_web.dart';
