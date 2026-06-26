/// Unit tests for the demo-side [HttpCoordinationClient].
///
/// All HTTP is mocked via `package:http`'s [MockClient]; no live server or
/// network access. The shapes asserted here mirror the wire contract in
/// `coordination_server/README.md` and the reference agent's client.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_account_demo/services/coordination_client.dart';

Map<String, dynamic> _requestJson({
  String id = 'req-1',
  String status = 'pending',
  List<String> args = const <String>['AAAA', 'BBBB'],
  String? resultHash,
  String? note,
  int? resolvedAt,
}) {
  return <String, dynamic>{
    'id': id,
    'smartAccount': 'CSMART',
    'target': 'CTARGET',
    'targetFn': 'transfer',
    'args': args,
    'amount': '10.5',
    'reason': 3016,
    'status': status,
    'createdAt': 1782485036185,
    'resolvedAt': resolvedAt,
    'resultHash': resultHash,
    'note': note,
  };
}

void main() {
  group('CoordinationRequest.fromJson', () {
    test('parses a full record including nulls', () {
      final request = CoordinationRequest.fromJson(_requestJson());
      expect(request.id, 'req-1');
      expect(request.smartAccount, 'CSMART');
      expect(request.target, 'CTARGET');
      expect(request.targetFn, 'transfer');
      expect(request.args, <String>['AAAA', 'BBBB']);
      expect(request.amount, '10.5');
      expect(request.reason, 3016);
      expect(request.status, 'pending');
      expect(request.resolvedAt, isNull);
      expect(request.resultHash, isNull);
      expect(request.note, isNull);
      expect(request.isResolved, isFalse);
    });

    test('isResolved is true for approved and rejected', () {
      expect(
        CoordinationRequest.fromJson(_requestJson(status: 'approved'))
            .isResolved,
        isTrue,
      );
      expect(
        CoordinationRequest.fromJson(_requestJson(status: 'rejected'))
            .isResolved,
        isTrue,
      );
    });
  });

  group('HttpCoordinationClient.listPending', () {
    test('GETs /requests?status=pending and parses the requests array',
        () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'requests': <Map<String, dynamic>>[
              _requestJson(id: 'a'),
              _requestJson(id: 'b'),
            ],
          }),
          200,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 'dev-token-change-me',
        httpClient: mock,
      );

      final pending = await client.listPending();

      expect(pending.map((r) => r.id), <String>['a', 'b']);
      expect(captured.method, 'GET');
      expect(captured.url.toString(),
          'http://localhost:8787/requests?status=pending');
      expect(captured.headers['Authorization'], 'Bearer dev-token-change-me');
    });

    test('returns an empty list when no requests are pending', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{'requests': <dynamic>[]}),
          200,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      expect(await client.listPending(), isEmpty);
    });

    test('maps a non-200 to CoordinationException carrying the status', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, String>{'error': 'unauthorized'}),
          401,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 'bad',
        httpClient: mock,
      );

      await expectLater(
        client.listPending(),
        throwsA(isA<CoordinationException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', contains('unauthorized'))),
      );
    });

    test('throws when the response omits the requests array', () async {
      final mock = MockClient((request) async {
        return http.Response(jsonEncode(<String, dynamic>{}), 200);
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await expectLater(
        client.listPending(),
        throwsA(isA<CoordinationException>()),
      );
    });

    test('surfaces a transport failure as CoordinationException', () async {
      final mock = MockClient((request) async {
        throw const SocketLikeException();
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await expectLater(
        client.listPending(),
        throwsA(isA<CoordinationException>()
            .having((e) => e.message, 'message', contains('GET /requests'))),
      );
    });
  });

  group('HttpCoordinationClient.getRequest', () {
    test('GETs /requests/{id} with the bearer token, trimming a trailing slash',
        () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_requestJson(
            status: 'approved',
            resultHash: 'RESULTHASH',
            resolvedAt: 1782485040000,
          )),
          200,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787/',
        token: 'tok',
        httpClient: mock,
      );

      final request = await client.getRequest('req-1');

      expect(request.status, 'approved');
      expect(request.resultHash, 'RESULTHASH');
      expect(captured.method, 'GET');
      expect(captured.url.toString(), 'http://localhost:8787/requests/req-1');
      expect(captured.headers['Authorization'], 'Bearer tok');
    });

    test('maps a 404 to CoordinationException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, String>{'error': 'not found'}),
          404,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await expectLater(
        client.getRequest('missing'),
        throwsA(isA<CoordinationException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('maps malformed JSON to CoordinationException', () async {
      final mock = MockClient((request) async {
        return http.Response('not json', 200);
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await expectLater(
        client.getRequest('req-1'),
        throwsA(isA<CoordinationException>()
            .having((e) => e.message, 'message', contains('malformed JSON'))),
      );
    });
  });

  group('HttpCoordinationClient.approve', () {
    test('POSTs the resultHash and returns the updated record', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_requestJson(
            status: 'approved',
            resultHash: 'TXHASH',
            resolvedAt: 1782485040000,
          )),
          200,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 'tok',
        httpClient: mock,
      );

      final updated = await client.approve('req-1', resultHash: 'TXHASH');

      expect(updated.status, 'approved');
      expect(updated.resultHash, 'TXHASH');
      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'http://localhost:8787/requests/req-1/approve');
      expect(captured.headers['Authorization'], 'Bearer tok');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['resultHash'], 'TXHASH');
    });

    test('maps a 409 (already resolved) to CoordinationException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, String>{'error': 'already resolved'}),
          409,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await expectLater(
        client.approve('req-1', resultHash: 'TXHASH'),
        throwsA(isA<CoordinationException>()
            .having((e) => e.statusCode, 'statusCode', 409)),
      );
    });
  });

  group('HttpCoordinationClient.reject', () {
    test('POSTs the note when provided', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_requestJson(status: 'rejected', note: 'looks malicious')),
          200,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 'tok',
        httpClient: mock,
      );

      final updated = await client.reject('req-1', note: 'looks malicious');

      expect(updated.status, 'rejected');
      expect(updated.note, 'looks malicious');
      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'http://localhost:8787/requests/req-1/reject');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['note'], 'looks malicious');
    });

    test('omits the note key from the body when null', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_requestJson(status: 'rejected')),
          200,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await client.reject('req-1');

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body.containsKey('note'), isFalse);
    });
  });
}

/// A stand-in transport error so the client's catch-all transport mapping can
/// be exercised without depending on `dart:io` (web-incompatible) types.
class SocketLikeException implements Exception {
  const SocketLikeException();

  @override
  String toString() => 'SocketLikeException: connection refused';
}
