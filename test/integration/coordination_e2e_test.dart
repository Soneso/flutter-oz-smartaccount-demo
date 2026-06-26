// Opt-in end-to-end test of the coordination seam: the demo's real
// HttpCoordinationClient against a real coordination_server subprocess.
//
// This is the only automatable slice of the agent-signer flow — it exercises
// the HTTP coordination contract end to end WITHOUT a chain, passkey, or
// relayer. The on-chain submission and the WebAuthn approval ceremony remain
// device-only (see documentation/agent-flow.md).
//
// GATED: skipped unless RUN_COORDINATION_E2E=true, so the default `flutter test`
// run never starts a subprocess or binds a socket. Run it explicitly:
//
//   RUN_COORDINATION_E2E=true flutter test test/integration/coordination_e2e_test.dart
//
// What it does, with the subprocess up on an ephemeral port and a temp store:
//   (a) POSTs an agent-shaped escalation via raw http, byte-for-byte matching
//       the reference agent's payload ({ smartAccount, target, targetFn,
//       args:[<base64 XdrSCVal>...], amount, reason }).
//   (b) Uses the demo's real HttpCoordinationClient.listPending() and asserts
//       the request appears, with its fields and decoded call arguments intact.
//   (c) Approves it through the client with a sample resultHash.
//   (d) getRequest() shows it approved and resolved.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smart_account_demo/config/demo_config.dart' as demo;
import 'package:smart_account_demo/services/coordination_client.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// Environment gate. The default `flutter test` run leaves this unset and skips.
const String _gateEnv = 'RUN_COORDINATION_E2E';

void main() {
  final enabled =
      (Platform.environment[_gateEnv] ?? '').toLowerCase() == 'true';

  group(
    'coordination end-to-end (real server subprocess)',
    () {
      const token = 'coordination-e2e-test-token';

      late _CoordinationServer server;
      late Directory storeDir;
      late HttpCoordinationClient client;

      setUpAll(() async {
        storeDir = await Directory.systemTemp.createTemp('coordination_e2e');
        final storePath = '${storeDir.path}/requests.store.json';
        server = await _CoordinationServer.start(
          token: token,
          storePath: storePath,
        );
        client = HttpCoordinationClient(baseUrl: server.baseUrl, token: token);
      });

      tearDownAll(() async {
        await client.close();
        await server.stop();
        if (storeDir.existsSync()) {
          await storeDir.delete(recursive: true);
        }
      });

      test('agent escalation round-trips through approve and resolve', () async {
        // The exact call the agent would escalate: transfer(from, to, amount).
        const smartAccount =
            'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC';
        const target = demo.nativeTokenContract;
        final destination = KeyPair.random().accountId;
        const amount = '1';
        const reason = 3016; // a spending-limit policy rejection code

        final baseUnits = OZTransactionOperations.amountToBaseUnits(
          amount,
          decimals: demo.demoTokenDecimals,
        );
        final scArgs = <XdrSCVal>[
          XdrSCVal.forAddressStrKey(smartAccount),
          XdrSCVal.forAddressStrKey(destination),
          Util.bigIntToI128ScVal(baseUnits),
        ];
        final encodedArgs = scArgs
            .map((a) => a.toBase64EncodedXdrString())
            .toList(growable: false);

        // (a) POST the agent-shaped escalation via raw http, byte-for-byte the
        // reference agent's HttpCoordinationClient.createRequest body.
        final postResponse = await http.post(
          Uri.parse('${server.baseUrl}/requests'),
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'smartAccount': smartAccount,
            'target': target,
            'targetFn': 'transfer',
            'args': encodedArgs,
            'reason': reason,
            'amount': amount,
          }),
        );
        expect(
          postResponse.statusCode,
          201,
          reason: 'POST /requests body: ${postResponse.body}',
        );
        final created =
            jsonDecode(postResponse.body) as Map<String, dynamic>;
        final requestId = created['id'] as String;
        expect(requestId, isNotEmpty);
        expect(created['status'], 'pending');

        // (b) The demo's real client lists the pending request with its fields
        // and decoded call arguments intact.
        final pending = await client.listPending();
        final match = pending.where((r) => r.id == requestId).toList();
        expect(match, hasLength(1), reason: 'escalation not found in listPending');
        final request = match.single;
        expect(request.smartAccount, smartAccount);
        expect(request.target, target);
        expect(request.targetFn, 'transfer');
        expect(request.amount, amount);
        expect(request.reason, reason);
        expect(request.status, CoordinationRequest.statusPending);
        expect(request.isResolved, isFalse);

        // The args round-trip verbatim and decode to the original call: two
        // addresses and the i128 amount the inbox would re-submit.
        expect(request.args, encodedArgs);
        final decoded = request.args
            .map(XdrSCVal.fromBase64EncodedXdrString)
            .toList(growable: false);
        expect(decoded[0].discriminant, XdrSCValType.SCV_ADDRESS);
        expect(decoded[1].discriminant, XdrSCValType.SCV_ADDRESS);
        expect(decoded[2].toBigInt(), baseUnits);

        // (c) Approve through the client with a sample result hash.
        const resultHash =
            'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
        final approved = await client.approve(requestId, resultHash: resultHash);
        expect(approved.status, CoordinationRequest.statusApproved);
        expect(approved.resultHash, resultHash);
        expect(approved.isResolved, isTrue);

        // (d) A fresh fetch shows it approved and resolved (the agent's poll).
        final polled = await client.getRequest(requestId);
        expect(polled.status, CoordinationRequest.statusApproved);
        expect(polled.resultHash, resultHash);
        expect(polled.resolvedAt, isNotNull);
        expect(polled.isResolved, isTrue);

        // It is no longer pending in the inbox.
        final afterApproval = await client.listPending();
        expect(afterApproval.where((r) => r.id == requestId), isEmpty);
      });
    },
    skip: enabled
        ? false
        : 'Set RUN_COORDINATION_E2E=true to run the coordination end-to-end test '
            'against a real coordination_server subprocess.',
  );
}

/// A coordination_server child process bound to an ephemeral port.
///
/// Started with `dart run bin/server.dart --port 0`, which binds an OS-assigned
/// port; the actual port is parsed from the server's startup line. The caller
/// must [stop] it to terminate the subprocess.
class _CoordinationServer {
  _CoordinationServer._(this._process, this.port, this._output);

  final Process _process;

  /// The OS-assigned port the server bound to.
  final int port;

  /// Accumulated stdout+stderr, surfaced on a startup or assertion failure.
  final StringBuffer _output;

  /// Loopback base URL for HTTP calls.
  String get baseUrl => 'http://127.0.0.1:$port';

  /// Starts the server and resolves once it reports its listening port and
  /// answers `/health` with `200`.
  static Future<_CoordinationServer> start({
    required String token,
    required String storePath,
  }) async {
    final serverDir = _coordinationServerDir();
    final dartExecutable = _resolveDartExecutable();

    final process = await Process.start(
      dartExecutable,
      <String>[
        'run',
        'bin/server.dart',
        '--port',
        '0',
        '--token',
        token,
        '--store',
        storePath,
      ],
      workingDirectory: serverDir.path,
    );

    final output = StringBuffer();
    final portCompleter = Completer<int>();
    final listeningPattern = RegExp(r'listening on http://[^:]+:(\d+)');

    void scan(String source, String line) {
      output.writeln('[$source] $line');
      if (!portCompleter.isCompleted) {
        final match = listeningPattern.firstMatch(line);
        if (match != null) {
          portCompleter.complete(int.parse(match.group(1)!));
        }
      }
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => scan('out', line));
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => scan('err', line));

    // If the process dies before announcing a port, fail fast with its output.
    unawaited(process.exitCode.then((code) {
      if (!portCompleter.isCompleted) {
        portCompleter.completeError(
          StateError(
            'coordination_server exited early (code $code) before binding.\n'
            '$output',
          ),
        );
      }
    }));

    final int port;
    try {
      port = await portCompleter.future.timeout(const Duration(seconds: 60));
    } catch (e) {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }

    final server = _CoordinationServer._(process, port, output);
    await server._awaitHealthy();
    return server;
  }

  Future<void> _awaitHealthy() async {
    final healthUri = Uri.parse('$baseUrl/health');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await http
            .get(healthUri)
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) return;
      } catch (_) {
        // Not up yet; retry until the deadline.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    process.kill(ProcessSignal.sigkill);
    throw StateError(
      'coordination_server did not become healthy on $baseUrl.\n$_output',
    );
  }

  /// Terminates the subprocess, escalating to SIGKILL if it does not stop.
  Future<void> stop() async {
    // kill() defaults to SIGTERM, which the server handles for a clean shutdown.
    _process.kill();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode;
    }
  }

  /// The process handle (used by [_awaitHealthy] to kill on failure).
  Process get process => _process;

  /// Resolves `<demo-root>/coordination_server`. `flutter test` runs with the
  /// package root as the current directory.
  static Directory _coordinationServerDir() {
    final dir = Directory('${Directory.current.path}/coordination_server');
    if (!dir.existsSync()) {
      throw StateError(
        'coordination_server directory not found at ${dir.path}. Run this test '
        'from the demo package root.',
      );
    }
    return dir;
  }

  /// Resolves the `dart` executable: the Flutter SDK copy when `FLUTTER_ROOT`
  /// is set, otherwise the bare name resolved against `PATH`.
  static String _resolveDartExecutable() {
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      final name = Platform.isWindows ? 'dart.bat' : 'dart';
      final candidate = '$flutterRoot/bin/$name';
      if (File(candidate).existsSync()) return candidate;
    }
    return Platform.isWindows ? 'dart.exe' : 'dart';
  }
}
