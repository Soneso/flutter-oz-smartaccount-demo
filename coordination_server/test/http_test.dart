import 'dart:convert';

import 'package:coordination_server/coordination_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _token = 'test-token-123';

Map<String, String> _authHeaders() => <String, String>{
      'authorization': 'Bearer $_token',
      'content-type': 'application/json',
    };

Request _request(
  String method,
  String path, {
  Map<String, String>? headers,
  Object? body,
}) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    headers: headers,
    body: body is String ? body : (body == null ? null : jsonEncode(body)),
  );
}

Future<Map<String, dynamic>> _jsonBody(Response response) async {
  final text = await response.readAsString();
  return jsonDecode(text) as Map<String, dynamic>;
}

Map<String, dynamic> _createBody({
  String smartAccount = 'CSMART',
  String target = 'CTARGET',
  String targetFn = 'transfer',
  List<String> args = const <String>['AAAA', 'BBBB'],
  String? amount = '10.5',
  Object? reason = 3016,
}) {
  return <String, dynamic>{
    'smartAccount': smartAccount,
    'target': target,
    'targetFn': targetFn,
    'args': args,
    'amount': ?amount,
    'reason': reason,
  };
}

void main() {
  late Handler handler;

  setUp(() {
    handler = buildHandler(RequestStore(), _token);
  });

  group('health', () {
    test('returns ok without auth', () async {
      final response = await handler(_request('GET', '/health'));
      expect(response.statusCode, 200);
      expect(await _jsonBody(response), <String, dynamic>{'status': 'ok'});
    });
  });

  group('auth', () {
    test('rejects missing Authorization header with 401', () async {
      final response = await handler(_request('GET', '/requests'));
      expect(response.statusCode, 401);
      expect((await _jsonBody(response))['error'], isA<String>());
    });

    test('rejects a wrong bearer token with 401', () async {
      final response = await handler(
        _request(
          'GET',
          '/requests',
          headers: <String, String>{'authorization': 'Bearer wrong'},
        ),
      );
      expect(response.statusCode, 401);
    });

    test('rejects a non-Bearer scheme with 401', () async {
      final response = await handler(
        _request(
          'GET',
          '/requests',
          headers: <String, String>{'authorization': 'Basic $_token'},
        ),
      );
      expect(response.statusCode, 401);
    });

    test('accepts the configured bearer token', () async {
      final response = await handler(
        _request('GET', '/requests', headers: _authHeaders()),
      );
      expect(response.statusCode, 200);
    });
  });

  group('POST /requests', () {
    test('creates a pending request and returns 201 with the full object',
        () async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(),
        ),
      );
      expect(response.statusCode, 201);
      final body = await _jsonBody(response);
      expect(body['id'], isA<String>());
      expect((body['id'] as String).length, greaterThan(0));
      expect(body['status'], 'pending');
      expect(body['createdAt'], isA<int>());
      expect(body['resolvedAt'], isNull);
      expect(body['resultHash'], isNull);
      expect(body['note'], isNull);
      expect(body['smartAccount'], 'CSMART');
      expect(body['targetFn'], 'transfer');
      expect(body['args'], <String>['AAAA', 'BBBB']);
      expect(body['reason'], 3016);
    });

    test('assigns a uuid v4 id', () async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(),
        ),
      );
      final body = await _jsonBody(response);
      final id = body['id'] as String;
      final uuidV4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidV4.hasMatch(id), isTrue, reason: 'id was $id');
    });

    test('defaults amount to an empty string when omitted', () async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(amount: null),
        ),
      );
      expect((await _jsonBody(response))['amount'], '');
    });

    test('ignores client-supplied id/status/createdAt', () async {
      final body = _createBody()
        ..['id'] = 'client-id'
        ..['status'] = 'approved'
        ..['createdAt'] = 1;
      final response = await handler(
        _request('POST', '/requests', headers: _authHeaders(), body: body),
      );
      final created = await _jsonBody(response);
      expect(created['id'], isNot('client-id'));
      expect(created['status'], 'pending');
      expect(created['createdAt'], isNot(1));
    });

    test('400 on malformed JSON body', () async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: '{not json',
        ),
      );
      expect(response.statusCode, 400);
      expect((await _jsonBody(response))['error'], isA<String>());
    });

    test('400 when a required field is missing', () async {
      final body = _createBody()..remove('targetFn');
      final response = await handler(
        _request('POST', '/requests', headers: _authHeaders(), body: body),
      );
      expect(response.statusCode, 400);
    });

    test('400 when reason is not an integer', () async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(reason: 'oops'),
        ),
      );
      expect(response.statusCode, 400);
    });

    test('400 when args contains a non-string element', () async {
      final body = _createBody()..['args'] = <dynamic>['ok', 5];
      final response = await handler(
        _request('POST', '/requests', headers: _authHeaders(), body: body),
      );
      expect(response.statusCode, 400);
    });

    test('400 when a required string field is empty', () async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(smartAccount: ''),
        ),
      );
      expect(response.statusCode, 400);
    });
  });

  group('GET /requests', () {
    Future<String> create() async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(),
        ),
      );
      return (await _jsonBody(response))['id'] as String;
    }

    test('lists newest first', () async {
      final first = await create();
      final second = await create();
      final response = await handler(
        _request('GET', '/requests', headers: _authHeaders()),
      );
      final list = (await _jsonBody(response))['requests'] as List<dynamic>;
      expect(list.length, 2);
      expect((list.first as Map<String, dynamic>)['id'], second);
      expect((list.last as Map<String, dynamic>)['id'], first);
    });

    test('filters by status', () async {
      final pendingId = await create();
      final toApprove = await create();
      await handler(
        _request(
          'POST',
          '/requests/$toApprove/approve',
          headers: _authHeaders(),
          body: <String, String>{'resultHash': 'h'},
        ),
      );

      final pendingResponse = await handler(
        _request('GET', '/requests?status=pending', headers: _authHeaders()),
      );
      final pendingList =
          (await _jsonBody(pendingResponse))['requests'] as List<dynamic>;
      expect(pendingList.length, 1);
      expect((pendingList.single as Map<String, dynamic>)['id'], pendingId);

      final approvedResponse = await handler(
        _request('GET', '/requests?status=approved', headers: _authHeaders()),
      );
      final approvedList =
          (await _jsonBody(approvedResponse))['requests'] as List<dynamic>;
      expect(approvedList.length, 1);
      expect((approvedList.single as Map<String, dynamic>)['id'], toApprove);
    });

    test('400 on an unknown status filter', () async {
      final response = await handler(
        _request('GET', '/requests?status=bogus', headers: _authHeaders()),
      );
      expect(response.statusCode, 400);
    });
  });

  group('GET /requests/{id}', () {
    test('returns the request', () async {
      final created = await _jsonBody(
        await handler(
          _request(
            'POST',
            '/requests',
            headers: _authHeaders(),
            body: _createBody(),
          ),
        ),
      );
      final id = created['id'] as String;
      final response = await handler(
        _request('GET', '/requests/$id', headers: _authHeaders()),
      );
      expect(response.statusCode, 200);
      expect((await _jsonBody(response))['id'], id);
    });

    test('404 for an unknown id', () async {
      final response = await handler(
        _request('GET', '/requests/does-not-exist', headers: _authHeaders()),
      );
      expect(response.statusCode, 404);
      expect((await _jsonBody(response))['error'], isA<String>());
    });
  });

  group('POST /requests/{id}/approve', () {
    Future<String> create() async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(),
        ),
      );
      return (await _jsonBody(response))['id'] as String;
    }

    test('approves a pending request and returns the updated object',
        () async {
      final id = await create();
      final response = await handler(
        _request(
          'POST',
          '/requests/$id/approve',
          headers: _authHeaders(),
          body: <String, String>{'resultHash': 'tx-hash-xyz'},
        ),
      );
      expect(response.statusCode, 200);
      final body = await _jsonBody(response);
      expect(body['status'], 'approved');
      expect(body['resultHash'], 'tx-hash-xyz');
      expect(body['resolvedAt'], isA<int>());
    });

    test('404 for an unknown id', () async {
      final response = await handler(
        _request(
          'POST',
          '/requests/missing/approve',
          headers: _authHeaders(),
          body: <String, String>{'resultHash': 'h'},
        ),
      );
      expect(response.statusCode, 404);
    });

    test('409 when already resolved', () async {
      final id = await create();
      await handler(
        _request(
          'POST',
          '/requests/$id/approve',
          headers: _authHeaders(),
          body: <String, String>{'resultHash': 'h1'},
        ),
      );
      final response = await handler(
        _request(
          'POST',
          '/requests/$id/approve',
          headers: _authHeaders(),
          body: <String, String>{'resultHash': 'h2'},
        ),
      );
      expect(response.statusCode, 409);
    });

    test('400 when resultHash is missing', () async {
      final id = await create();
      final response = await handler(
        _request(
          'POST',
          '/requests/$id/approve',
          headers: _authHeaders(),
          body: <String, dynamic>{},
        ),
      );
      expect(response.statusCode, 400);
    });
  });

  group('POST /requests/{id}/reject', () {
    Future<String> create() async {
      final response = await handler(
        _request(
          'POST',
          '/requests',
          headers: _authHeaders(),
          body: _createBody(),
        ),
      );
      return (await _jsonBody(response))['id'] as String;
    }

    test('rejects a pending request with a note', () async {
      final id = await create();
      final response = await handler(
        _request(
          'POST',
          '/requests/$id/reject',
          headers: _authHeaders(),
          body: <String, String>{'note': 'looks malicious'},
        ),
      );
      expect(response.statusCode, 200);
      final body = await _jsonBody(response);
      expect(body['status'], 'rejected');
      expect(body['note'], 'looks malicious');
      expect(body['resolvedAt'], isA<int>());
    });

    test('rejects with an empty body (note optional)', () async {
      final id = await create();
      final response = await handler(
        _request(
          'POST',
          '/requests/$id/reject',
          headers: _authHeaders(),
        ),
      );
      expect(response.statusCode, 200);
      expect((await _jsonBody(response))['note'], isNull);
    });

    test('404 for an unknown id', () async {
      final response = await handler(
        _request(
          'POST',
          '/requests/missing/reject',
          headers: _authHeaders(),
        ),
      );
      expect(response.statusCode, 404);
    });

    test('409 when already resolved', () async {
      final id = await create();
      await handler(
        _request(
          'POST',
          '/requests/$id/reject',
          headers: _authHeaders(),
        ),
      );
      final response = await handler(
        _request(
          'POST',
          '/requests/$id/reject',
          headers: _authHeaders(),
        ),
      );
      expect(response.statusCode, 409);
    });
  });

  group('CORS', () {
    test('preflight returns 204 with CORS headers and no auth', () async {
      final response = await handler(_request('OPTIONS', '/requests'));
      expect(response.statusCode, 204);
      expect(response.headers['access-control-allow-origin'], '*');
      expect(
        response.headers['access-control-allow-methods'],
        contains('POST'),
      );
      expect(
        response.headers['access-control-allow-headers'],
        contains('Authorization'),
      );
    });

    test('CORS headers are present on normal responses', () async {
      final response = await handler(_request('GET', '/health'));
      expect(response.headers['access-control-allow-origin'], '*');
    });

    test('CORS headers are present on 401 responses', () async {
      final response = await handler(_request('GET', '/requests'));
      expect(response.statusCode, 401);
      expect(response.headers['access-control-allow-origin'], '*');
    });
  });
}
