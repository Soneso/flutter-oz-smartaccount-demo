/// Coordination server library: the message channel between the autonomous
/// reference agent and the OpenZeppelin smart-account demo app.
///
/// The agent posts policy-rejected smart-account calls; the app polls them,
/// lets the user approve or reject, and reports the outcome back. This barrel
/// exposes the configuration, domain model, store, and HTTP wiring used by
/// `bin/server.dart` and the tests.
library;

export 'src/config.dart';
export 'src/middleware.dart';
export 'src/models.dart';
export 'src/request_store.dart';
export 'src/router.dart';
