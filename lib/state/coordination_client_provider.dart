/// Riverpod provider for the shared [CoordinationClient] singleton.
///
/// Builds an [HttpCoordinationClient] from the demo configuration and closes
/// its HTTP client when the provider is disposed. Tests override this provider
/// with a fake or a `package:http` `MockClient`-backed client so the approval
/// inbox can be exercised without a live coordination server.
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/demo_config.dart' as config;
import '../services/coordination_client.dart';

/// Provider for the [CoordinationClient] instance.
final coordinationClientProvider = Provider<CoordinationClient>((ref) {
  // In a non-debug build, refuse to construct the client when the local-dev
  // defaults (development token / cleartext endpoint) are still in place, so
  // they cannot ship silently. Debug/demo runs skip the check.
  if (!kDebugMode) {
    final blocker = config.coordinationConfigShipBlocker();
    if (blocker != null) {
      throw StateError(
        'Refusing to start the approval-inbox coordination client in a '
        'non-debug build: $blocker.',
      );
    }
  }

  final client = HttpCoordinationClient(
    baseUrl: config.coordinationServerUrl,
    token: config.coordinationToken,
  );
  ref.onDispose(client.close);
  return client;
});
