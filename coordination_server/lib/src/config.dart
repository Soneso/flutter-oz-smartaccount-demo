/// Runtime configuration resolved from CLI flags and environment variables.
///
/// CLI flags take precedence over environment variables. A bearer token is
/// mandatory: the server refuses to start without one rather than running
/// open.
class ServerConfig {
  const ServerConfig({
    required this.port,
    required this.token,
    this.storePath,
  });

  /// TCP port to bind. Defaults to [defaultPort].
  final int port;

  /// Bearer token required on all `/requests*` routes.
  final String token;

  /// Path to the JSON persistence file, or `null` for in-memory only.
  final String? storePath;

  static const int defaultPort = 8787;

  /// Environment variable holding the bearer token.
  static const String tokenEnv = 'COORDINATION_TOKEN';

  /// Environment variable holding the persistence file path.
  static const String storeEnv = 'COORDINATION_STORE';

  /// Environment variable holding the port.
  static const String portEnv = 'PORT';

  /// Resolves configuration from process [args] and [environment].
  ///
  /// Recognised flags: `--port <n>`, `--token <s>`, `--store <path>` (each also
  /// accepts the `--flag=value` form). Throws [ConfigException] on an unknown
  /// flag, a malformed port, or a missing/empty token.
  factory ServerConfig.resolve(
    List<String> args,
    Map<String, String> environment,
  ) {
    final flags = _parseFlags(args);

    final portValue = flags['port'] ?? environment[portEnv];
    final int port;
    if (portValue == null || portValue.isEmpty) {
      port = defaultPort;
    } else {
      final parsed = int.tryParse(portValue);
      if (parsed == null || parsed < 0 || parsed > 65535) {
        throw ConfigException(
          'invalid port "$portValue": expected an integer in 0..65535',
        );
      }
      port = parsed;
    }

    final token = flags['token'] ?? environment[tokenEnv];
    if (token == null || token.isEmpty) {
      throw ConfigException(
        'no bearer token configured. Set $tokenEnv or pass --token <value>. '
        'The server refuses to start without a token to avoid running open.',
      );
    }

    final storeRaw = flags['store'] ?? environment[storeEnv];
    final storePath =
        (storeRaw == null || storeRaw.isEmpty) ? null : storeRaw;

    return ServerConfig(port: port, token: token, storePath: storePath);
  }

  static Map<String, String> _parseFlags(List<String> args) {
    const known = <String>{'port', 'token', 'store'};
    final flags = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        throw ConfigException('unexpected argument "$arg"');
      }
      final body = arg.substring(2);
      final eq = body.indexOf('=');
      String name;
      String value;
      if (eq >= 0) {
        name = body.substring(0, eq);
        value = body.substring(eq + 1);
      } else {
        name = body;
        if (i + 1 >= args.length) {
          throw ConfigException('missing value for flag "--$name"');
        }
        value = args[++i];
      }
      if (!known.contains(name)) {
        throw ConfigException('unknown flag "--$name"');
      }
      flags[name] = value;
    }
    return flags;
  }
}

/// Raised when configuration cannot be resolved into a runnable state.
class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => 'ConfigException: $message';
}
