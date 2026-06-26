import 'package:coordination_server/coordination_server.dart';
import 'package:test/test.dart';

void main() {
  group('ServerConfig.resolve', () {
    test('uses defaults with only a token in the environment', () {
      final config = ServerConfig.resolve(
        const <String>[],
        const <String, String>{'COORDINATION_TOKEN': 'secret'},
      );
      expect(config.port, ServerConfig.defaultPort);
      expect(config.token, 'secret');
      expect(config.storePath, isNull);
    });

    test('reads port and store from the environment', () {
      final config = ServerConfig.resolve(
        const <String>[],
        const <String, String>{
          'COORDINATION_TOKEN': 'secret',
          'PORT': '9000',
          'COORDINATION_STORE': '/var/data/store.json',
        },
      );
      expect(config.port, 9000);
      expect(config.storePath, '/var/data/store.json');
    });

    test('CLI flags override environment variables', () {
      final config = ServerConfig.resolve(
        const <String>['--token', 'flag-token', '--port', '1234'],
        const <String, String>{
          'COORDINATION_TOKEN': 'env-token',
          'PORT': '8787',
        },
      );
      expect(config.token, 'flag-token');
      expect(config.port, 1234);
    });

    test('accepts the --flag=value form', () {
      final config = ServerConfig.resolve(
        const <String>['--token=abc', '--port=2020', '--store=/tmp/s.json'],
        const <String, String>{},
      );
      expect(config.token, 'abc');
      expect(config.port, 2020);
      expect(config.storePath, '/tmp/s.json');
    });

    test('throws when no token is configured', () {
      expect(
        () => ServerConfig.resolve(
          const <String>[],
          const <String, String>{},
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('throws on an empty token', () {
      expect(
        () => ServerConfig.resolve(
          const <String>['--token', ''],
          const <String, String>{},
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('throws on a non-numeric port', () {
      expect(
        () => ServerConfig.resolve(
          const <String>['--token', 't', '--port', 'abc'],
          const <String, String>{},
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('throws on an out-of-range port', () {
      expect(
        () => ServerConfig.resolve(
          const <String>['--token', 't', '--port', '70000'],
          const <String, String>{},
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('throws on an unknown flag', () {
      expect(
        () => ServerConfig.resolve(
          const <String>['--token', 't', '--bogus', 'x'],
          const <String, String>{},
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('throws on a missing flag value', () {
      expect(
        () => ServerConfig.resolve(
          const <String>['--token'],
          const <String, String>{},
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
