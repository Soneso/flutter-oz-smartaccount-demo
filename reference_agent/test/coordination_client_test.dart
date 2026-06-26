// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reference_agent/reference_agent.dart';

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
    test('parses a full record, including nulls', () {
      final request = CoordinationRequest.fromJson(_requestJson());
      expect(request.id, 'req-1');
      expect(request.smartAccount, 'CSMART');
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

  group('HttpCoordinationClient.createRequest', () {
    test('POSTs to /requests with the bearer token and exact body', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_requestJson(args: const <String>['AAAA'])),
          201,
        );
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 'dev-token-change-me',
        httpClient: mock,
      );

      final created = await client.createRequest(
        smartAccount: 'CSMART',
        target: 'CTARGET',
        targetFn: 'transfer',
        args: const <String>['AAAA'],
        amount: '10.5',
        reason: 3016,
      );

      expect(created.id, 'req-1');
      expect(created.status, 'pending');

      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'http://localhost:8787/requests');
      expect(captured.headers['Authorization'], 'Bearer dev-token-change-me');
      expect(captured.headers['Content-Type'], contains('application/json'));

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['smartAccount'], 'CSMART');
      expect(body['target'], 'CTARGET');
      expect(body['targetFn'], 'transfer');
      expect(body['args'], <String>['AAAA']);
      expect(body['amount'], '10.5');
      expect(body['reason'], 3016);
    });

    test('omits amount from the body when null', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(_requestJson()), 201);
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await client.createRequest(
        smartAccount: 'CSMART',
        target: 'CTARGET',
        targetFn: 'transfer',
        args: const <String>['AAAA'],
        reason: 3016,
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body.containsKey('amount'), isFalse);
    });

    test('maps a non-201 error response to CoordinationException', () async {
      final mock = MockClient((request) async {
        return http.Response(jsonEncode(<String, String>{'error': 'bad body'}), 400);
      });
      final client = HttpCoordinationClient(
        baseUrl: 'http://localhost:8787',
        token: 't',
        httpClient: mock,
      );

      await expectLater(
        client.createRequest(
          smartAccount: 'CSMART',
          target: 'CTARGET',
          targetFn: 'transfer',
          args: const <String>[],
          reason: 3016,
        ),
        throwsA(
          isA<CoordinationException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message, 'message', contains('bad body')),
        ),
      );
    });
  });

  group('HttpCoordinationClient.getRequest', () {
    test('GETs /requests/{id} with the bearer token', () async {
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
      // Trailing slash on the base URL must be trimmed.
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
        return http.Response(jsonEncode(<String, String>{'error': 'not found'}), 404);
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
  });
}
