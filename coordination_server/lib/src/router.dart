import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'middleware.dart';
import 'models.dart';
import 'request_store.dart';

/// Builds the fully wired request handler: CORS, request logging, error
/// mapping, and bearer auth around the routed endpoints.
///
/// Middleware order (outermost first): CORS so every response — including
/// `401` and `500` — carries CORS headers and preflight is answered before
/// auth; logging; error mapping; then auth guarding the routes.
Handler buildHandler(RequestStore store, String token) {
  return const Pipeline()
      .addMiddleware(corsMiddleware())
      .addMiddleware(logRequestsMiddleware())
      .addMiddleware(errorMiddleware())
      .addMiddleware(authMiddleware(token))
      .addHandler(createRouter(store).call);
}

/// Builds the route table for the coordination API.
///
/// Handlers throw [ValidationException], [NotFoundException], and
/// [ConflictException]; [errorMiddleware] maps them to 400/404/409. This keeps
/// each handler focused on the happy path.
Router createRouter(RequestStore store) {
  final router = Router();

  router.get('/health', (Request request) {
    return _json(200, <String, String>{'status': 'ok'});
  });

  router.post('/requests', (Request request) async {
    final body = await _readJsonObject(request);
    final input = CreateRequestInput.fromJson(body);
    final created = await store.create(input);
    return _json(201, created.toJson());
  });

  router.get('/requests', (Request request) {
    final statusParam = request.url.queryParameters['status'];
    final status =
        statusParam == null ? null : RequestStatus.fromWire(statusParam);
    final requests = store.list(status: status);
    return _json(200, <String, dynamic>{
      'requests': requests.map((r) => r.toJson()).toList(growable: false),
    });
  });

  router.get('/requests/<id>', (Request request, String id) {
    final found = store.getById(id);
    if (found == null) {
      throw NotFoundException("request '$id' not found");
    }
    return _json(200, found.toJson());
  });

  router.post('/requests/<id>/approve', (Request request, String id) async {
    final body = await _readJsonObject(request);
    final resultHash = body['resultHash'];
    if (resultHash is! String || resultHash.isEmpty) {
      throw ValidationException("field 'resultHash' must be a non-empty string");
    }
    final updated = await store.approve(id, resultHash: resultHash);
    return _json(200, updated.toJson());
  });

  router.post('/requests/<id>/reject', (Request request, String id) async {
    final body = await _readJsonObject(request, allowEmpty: true);
    final dynamic noteValue = body['note'];
    if (noteValue != null && noteValue is! String) {
      throw ValidationException("field 'note' must be a string when present");
    }
    final updated = await store.reject(id, note: noteValue as String?);
    return _json(200, updated.toJson());
  });

  return router;
}

/// Reads and decodes a JSON object body.
///
/// When [allowEmpty] is true an empty body yields an empty map (used by reject,
/// whose `note` is optional). Throws [ValidationException] on a non-object or
/// malformed JSON body.
Future<Map<String, dynamic>> _readJsonObject(
  Request request, {
  bool allowEmpty = false,
}) async {
  final raw = await request.readAsString();
  if (raw.trim().isEmpty) {
    if (allowEmpty) {
      return <String, dynamic>{};
    }
    throw ValidationException('request body must be a JSON object');
  }
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw ValidationException('request body is not valid JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw ValidationException('request body must be a JSON object');
  }
  return decoded;
}

Response _json(int status, Object data) {
  return Response(
    status,
    body: jsonEncode(data),
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}
