import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'models.dart';

/// CORS headers applied to every response. The web demo polls this service
/// from a browser, so cross-origin reads and the bearer header must be allowed.
const Map<String, String> _corsHeaders = <String, String>{
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type',
  'Access-Control-Max-Age': '86400',
};

/// Adds CORS headers to all responses and answers `OPTIONS` preflight requests
/// directly with `204` and the CORS headers, short-circuiting before auth.
Middleware corsMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response(204, headers: _corsHeaders);
      }
      final response = await inner(request);
      return response.change(headers: _corsHeaders);
    };
  };
}

/// Requires `Authorization: Bearer <token>` on every route except `/health`.
///
/// `OPTIONS` preflight never reaches this layer because [corsMiddleware] runs
/// outermost and answers it first. Token comparison is constant-time to avoid
/// leaking the token through response timing.
Middleware authMiddleware(String token) {
  final expected = utf8.encode(token);
  return (Handler inner) {
    return (Request request) {
      if (request.url.path == 'health') {
        return inner(request);
      }
      final header = request.headers['authorization'];
      const prefix = 'Bearer ';
      if (header == null || !header.startsWith(prefix)) {
        return _jsonError(401, 'missing or malformed Authorization header');
      }
      final presented = utf8.encode(header.substring(prefix.length));
      if (!_constantTimeEquals(expected, presented)) {
        return _jsonError(401, 'invalid bearer token');
      }
      return inner(request);
    };
  };
}

/// Translates thrown domain errors into JSON HTTP responses with the right
/// status code, and turns any unexpected error into a `500` without leaking
/// internals to the client.
Middleware errorMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on ValidationException catch (error) {
        return _jsonError(400, error.message);
      } on FormatException catch (error) {
        return _jsonError(400, error.message);
      } on NotFoundException catch (error) {
        return _jsonError(404, error.message);
      } on ConflictException catch (error) {
        return _jsonError(409, error.message);
      } catch (error, stackTrace) {
        stderr.writeln('Unhandled error: $error');
        stderr.writeln(stackTrace);
        return _jsonError(500, 'internal server error');
      }
    };
  };
}

/// Logs one line per request to stdout: method, path, status, and duration.
Middleware logRequestsMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final watch = Stopwatch()..start();
      final response = await inner(request);
      watch.stop();
      stdout.writeln(
        '${DateTime.now().toIso8601String()} '
        '${request.method} /${request.url.path} '
        '${response.statusCode} ${watch.elapsedMilliseconds}ms',
      );
      return response;
    };
  };
}

/// Builds a JSON error response of the shape `{ "error": "..." }`.
Response _jsonError(int status, String message) {
  return Response(
    status,
    body: jsonEncode(<String, String>{'error': message}),
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

/// Length-aware constant-time byte comparison.
bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final max = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < max; i++) {
    final byteA = i < a.length ? a[i] : 0;
    final byteB = i < b.length ? b[i] : 0;
    diff |= byteA ^ byteB;
  }
  return diff == 0;
}
