import 'dart:async';
import 'dart:io';

import 'package:coordination_server/coordination_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Entry point for the coordination server.
///
/// Resolves configuration, loads any persisted store, binds `0.0.0.0:<port>`,
/// and serves until interrupted. Exits with code 64 (`EX_USAGE`) on a
/// configuration error so process supervisors can distinguish a misconfigured
/// launch from a runtime crash.
Future<void> main(List<String> args) async {
  final ServerConfig config;
  try {
    config = ServerConfig.resolve(args, Platform.environment);
  } on ConfigException catch (error) {
    stderr.writeln('Configuration error: ${error.message}');
    exitCode = 64;
    return;
  }

  final store = RequestStore(storePath: config.storePath);
  try {
    await store.load();
  } catch (error) {
    stderr.writeln('Failed to load store "${config.storePath}": $error');
    exitCode = 70; // EX_SOFTWARE
    return;
  }

  final handler = buildHandler(store, config.token);
  final server = await shelf_io.serve(
    handler,
    InternetAddress.anyIPv4,
    config.port,
  );
  server.autoCompress = true;

  stdout.writeln(
    'coordination_server listening on http://${server.address.host}:'
    '${server.port}',
  );
  if (config.storePath != null) {
    stdout.writeln('Persisting requests to ${config.storePath}');
  } else {
    stdout.writeln('Running in-memory only (no --store configured)');
  }

  final shutdown = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  void onSignal(ProcessSignal signal) {
    stdout.writeln('Received $signal, shutting down');
    if (!shutdown.isCompleted) {
      shutdown.complete();
    }
  }

  subscriptions.add(ProcessSignal.sigint.watch().listen(onSignal));
  if (!Platform.isWindows) {
    subscriptions.add(ProcessSignal.sigterm.watch().listen(onSignal));
  }

  await shutdown.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await server.close();
  stdout.writeln('Stopped');
}
