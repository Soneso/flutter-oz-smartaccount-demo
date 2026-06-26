/// Demo-side client for the coordination server (agent-signer flow, steps 4+5).
///
/// The coordination server brokers policy-rejected smart-account calls between
/// the autonomous reference agent and this demo's approval inbox. The agent
/// posts a rejected call (`POST /requests`); the inbox lists the pending
/// requests, lets the user approve or reject each one, and reports the outcome
/// back. This client implements only the inbox side of that contract; the
/// agent side lives in `reference_agent/lib/src/coordination_client.dart`.
///
/// The request/response shapes mirror the canonical request object documented
/// in `coordination_server/README.md` and the agent's client, so the two stay
/// byte-for-byte consistent. The list endpoint wraps its array in a `requests`
/// key (`{ "requests": [...] }`); the single-object endpoints return the bare
/// request object.
///
/// [CoordinationClient] is an interface so the approval-inbox flow and the
/// pending-count provider can be unit/widget-tested against a fake or a
/// `package:http` `MockClient`, without a live server or network access.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// CoordinationRequest
// ---------------------------------------------------------------------------

/// A coordination-server request record.
///
/// Mirrors the canonical request object in `coordination_server/README.md`.
/// All fields are always present in a server response; nullable fields are
/// `null` until the request is resolved. The [args] entries are base64-encoded
/// `XdrSCVal` strings, opaque to the server and stored verbatim so the inbox
/// can rebuild the original call exactly.
class CoordinationRequest {
  /// Constructs a request record.
  const CoordinationRequest({
    required this.id,
    required this.smartAccount,
    required this.target,
    required this.targetFn,
    required this.args,
    required this.amount,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.resolvedAt,
    this.resultHash,
    this.note,
  });

  /// Server-assigned UUID v4.
  final String id;

  /// C-address of the smart account the call targets.
  final String smartAccount;

  /// C-address the agent tried to call.
  final String target;

  /// Function name invoked on [target] (for example `transfer`).
  final String targetFn;

  /// Base64-encoded `XdrSCVal` call arguments, verbatim.
  final List<String> args;

  /// Display-only amount string; the empty string when not supplied.
  final String amount;

  /// Integer contract error code that triggered the escalation.
  final int reason;

  /// One of `pending`, `approved`, or `rejected`.
  final String status;

  /// Creation timestamp (epoch milliseconds).
  final int createdAt;

  /// Resolution timestamp (epoch milliseconds), or `null` while pending.
  final int? resolvedAt;

  /// Transaction/result hash set on approval, or `null`.
  final String? resultHash;

  /// Optional note set on rejection, or `null`.
  final String? note;

  /// Pending status literal.
  static const String statusPending = 'pending';

  /// Approved status literal.
  static const String statusApproved = 'approved';

  /// Rejected status literal.
  static const String statusRejected = 'rejected';

  /// Whether the request has reached a terminal state.
  bool get isResolved => status == statusApproved || status == statusRejected;

  /// Parses a request record from a decoded JSON [json] map.
  factory CoordinationRequest.fromJson(Map<String, dynamic> json) {
    return CoordinationRequest(
      id: _asString(json, 'id'),
      smartAccount: _asString(json, 'smartAccount'),
      target: _asString(json, 'target'),
      targetFn: _asString(json, 'targetFn'),
      args: _asStringList(json, 'args'),
      amount: _asStringOr(json, 'amount', ''),
      reason: _asInt(json, 'reason'),
      status: _asString(json, 'status'),
      createdAt: _asInt(json, 'createdAt'),
      resolvedAt: _asIntOrNull(json, 'resolvedAt'),
      resultHash: _asStringOrNull(json, 'resultHash'),
      note: _asStringOrNull(json, 'note'),
    );
  }

  @override
  String toString() =>
      'CoordinationRequest(id: $id, status: $status, reason: $reason, '
      'resultHash: $resultHash)';
}

// ---------------------------------------------------------------------------
// CoordinationClient
// ---------------------------------------------------------------------------

/// Abstraction over the inbox-facing subset of the coordination server's REST
/// contract.
///
/// Behind an interface so the approval-inbox flow and the pending-count
/// provider can be tested with a fake that returns canned responses, without a
/// live server or network access.
abstract interface class CoordinationClient {
  /// Lists every pending request via `GET /requests?status=pending`, newest
  /// first.
  Future<List<CoordinationRequest>> listPending();

  /// Fetches one request via `GET /requests/{id}`.
  Future<CoordinationRequest> getRequest(String id);

  /// Approves a pending request via `POST /requests/{id}/approve` with
  /// `{ "resultHash": <hash> }`. Returns the updated record.
  Future<CoordinationRequest> approve(String id, {required String resultHash});

  /// Rejects a pending request via `POST /requests/{id}/reject` with an
  /// optional `{ "note": <text> }` body. Returns the updated record.
  Future<CoordinationRequest> reject(String id, {String? note});

  /// Releases any held resources (HTTP client).
  Future<void> close();
}

// ---------------------------------------------------------------------------
// CoordinationException
// ---------------------------------------------------------------------------

/// Thrown when a coordination-server call fails or returns an error response.
class CoordinationException implements Exception {
  /// Constructs a coordination exception.
  const CoordinationException(this.message, {this.statusCode});

  /// Human-readable description of the failure.
  final String message;

  /// HTTP status code when the failure carried one, otherwise `null`.
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'CoordinationException: $message'
      : 'CoordinationException($statusCode): $message';
}

// ---------------------------------------------------------------------------
// HttpCoordinationClient
// ---------------------------------------------------------------------------

/// [CoordinationClient] backed by the coordination server's HTTP API.
///
/// Sends `Authorization: Bearer <token>` on every `/requests*` call and maps
/// non-2xx responses (JSON `{ "error": "..." }`) to [CoordinationException].
class HttpCoordinationClient implements CoordinationClient {
  /// Constructs a client for [baseUrl] authenticating with [token].
  ///
  /// A trailing slash on [baseUrl] is trimmed. Supply [httpClient] to inject a
  /// test double; when omitted a default [http.Client] is created and closed
  /// by [close].
  HttpCoordinationClient({
    required String baseUrl,
    required String token,
    http.Client? httpClient,
  })  : _baseUrl = _trimTrailingSlash(baseUrl),
        _token = token,
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String _baseUrl;
  final String _token;
  final http.Client _httpClient;
  final bool _ownsClient;

  Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  @override
  Future<List<CoordinationRequest>> listPending() async {
    final http.Response response;
    try {
      response = await _httpClient.get(
        Uri.parse('$_baseUrl/requests?status=${CoordinationRequest.statusPending}'),
        headers: _headers,
      );
    } catch (e) {
      throw CoordinationException('GET /requests failed: $e');
    }

    if (response.statusCode != 200) {
      throw CoordinationException(
        'list returned ${response.statusCode}: ${_errorBody(response.body)}',
        statusCode: response.statusCode,
      );
    }

    final decoded = _decodeJson(response.body, context: 'list');
    if (decoded is! Map<String, dynamic>) {
      throw CoordinationException(
        'list returned an unexpected JSON shape: ${decoded.runtimeType}',
      );
    }
    final rawList = decoded['requests'];
    if (rawList is! List) {
      throw const CoordinationException(
        "list response missing a 'requests' array",
      );
    }
    return rawList.map((Object? entry) {
      if (entry is! Map<String, dynamic>) {
        throw CoordinationException(
          'list contained a non-object entry: ${entry.runtimeType}',
        );
      }
      return CoordinationRequest.fromJson(entry);
    }).toList(growable: false);
  }

  @override
  Future<CoordinationRequest> getRequest(String id) async {
    final http.Response response;
    try {
      response = await _httpClient.get(
        Uri.parse('$_baseUrl/requests/$id'),
        headers: _headers,
      );
    } catch (e) {
      throw CoordinationException('GET /requests/$id failed: $e');
    }
    return _decodeRequest(response, expectedStatus: 200, context: 'get');
  }

  @override
  Future<CoordinationRequest> approve(
    String id, {
    required String resultHash,
  }) async {
    final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$_baseUrl/requests/$id/approve'),
        headers: _headers,
        body: jsonEncode(<String, dynamic>{'resultHash': resultHash}),
      );
    } catch (e) {
      throw CoordinationException('POST /requests/$id/approve failed: $e');
    }
    return _decodeRequest(response, expectedStatus: 200, context: 'approve');
  }

  @override
  Future<CoordinationRequest> reject(String id, {String? note}) async {
    final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$_baseUrl/requests/$id/reject'),
        headers: _headers,
        body: jsonEncode(<String, dynamic>{'note': ?note}),
      );
    } catch (e) {
      throw CoordinationException('POST /requests/$id/reject failed: $e');
    }
    return _decodeRequest(response, expectedStatus: 200, context: 'reject');
  }

  @override
  Future<void> close() async {
    if (_ownsClient) _httpClient.close();
  }

  CoordinationRequest _decodeRequest(
    http.Response response, {
    required int expectedStatus,
    required String context,
  }) {
    if (response.statusCode != expectedStatus) {
      throw CoordinationException(
        '$context returned ${response.statusCode}: ${_errorBody(response.body)}',
        statusCode: response.statusCode,
      );
    }
    final decoded = _decodeJson(response.body, context: context);
    if (decoded is! Map<String, dynamic>) {
      throw CoordinationException(
        '$context returned an unexpected JSON shape: ${decoded.runtimeType}',
      );
    }
    return CoordinationRequest.fromJson(decoded);
  }

  static Object? _decodeJson(String body, {required String context}) {
    try {
      return jsonDecode(body);
    } catch (e) {
      throw CoordinationException('$context returned malformed JSON: $e');
    }
  }

  /// Extracts the `error` field from a JSON error body, falling back to the
  /// raw body when it is not the expected shape.
  static String _errorBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is String) return error;
      }
    } catch (_) {
      // Fall through to the raw body.
    }
    return body.isEmpty ? '(empty body)' : body;
  }

  static String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}

// ---------------------------------------------------------------------------
// JSON parsing helpers (typed, no dynamic calls)
// ---------------------------------------------------------------------------

String _asString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw CoordinationException(
    "Expected string for '$key', got ${value.runtimeType}",
  );
}

String _asStringOr(Map<String, dynamic> json, String key, String fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is String) return value;
  throw CoordinationException(
    "Expected string for '$key', got ${value.runtimeType}",
  );
}

String? _asStringOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw CoordinationException(
    "Expected string or null for '$key', got ${value.runtimeType}",
  );
}

int _asInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw CoordinationException(
    "Expected integer for '$key', got ${value.runtimeType}",
  );
}

int? _asIntOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  throw CoordinationException(
    "Expected integer or null for '$key', got ${value.runtimeType}",
  );
}

List<String> _asStringList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is List) {
    return value.map((Object? e) {
      if (e is String) return e;
      throw CoordinationException(
        "Expected string list entry for '$key', got ${e.runtimeType}",
      );
    }).toList(growable: false);
  }
  throw CoordinationException(
    "Expected list for '$key', got ${value.runtimeType}",
  );
}
