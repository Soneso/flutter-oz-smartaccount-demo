// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A coordination-server request record.
///
/// Mirrors the canonical request object documented in
/// `coordination_server/README.md`. All fields are always present in a server
/// response; nullable fields are `null` until the request is resolved.
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

  /// C-address of the smart account.
  final String smartAccount;

  /// C-address the agent tried to call.
  final String target;

  /// Function name invoked on [target] (e.g. `transfer`).
  final String targetFn;

  /// Base64-encoded `XdrSCVal` call arguments, verbatim, so the inbox can
  /// rebuild the original call.
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

  /// Whether the request has reached a terminal state.
  bool get isResolved => status == statusApproved || status == statusRejected;

  /// Pending status literal.
  static const String statusPending = 'pending';

  /// Approved status literal.
  static const String statusApproved = 'approved';

  /// Rejected status literal.
  static const String statusRejected = 'rejected';

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

/// Abstraction over the coordination server's REST contract.
///
/// Behind an interface so the agent runner can be unit-tested with a fake that
/// returns canned responses, without a live server or network access.
abstract interface class CoordinationClient {
  /// Posts a rejected call to `POST /requests`.
  ///
  /// [args] is the list of base64-encoded `XdrSCVal` strings — the exact call
  /// arguments, so the inbox can rebuild the call verbatim. [reason] is the
  /// integer contract error code. Returns the created record with a
  /// server-assigned [CoordinationRequest.id] and `pending` status.
  Future<CoordinationRequest> createRequest({
    required String smartAccount,
    required String target,
    required String targetFn,
    required List<String> args,
    String? amount,
    required int reason,
  });

  /// Fetches one request from `GET /requests/{id}` to poll its status.
  Future<CoordinationRequest> getRequest(String id);

  /// Releases any held resources (HTTP client).
  Future<void> close();
}

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
  Future<CoordinationRequest> createRequest({
    required String smartAccount,
    required String target,
    required String targetFn,
    required List<String> args,
    String? amount,
    required int reason,
  }) async {
    final body = <String, dynamic>{
      'smartAccount': smartAccount,
      'target': target,
      'targetFn': targetFn,
      'args': args,
      'reason': reason,
      'amount': ?amount,
    };

    final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$_baseUrl/requests'),
        headers: _headers,
        body: jsonEncode(body),
      );
    } catch (e) {
      throw CoordinationException('POST /requests failed: $e');
    }

    return _decodeRequest(response, expectedStatus: 201, context: 'create');
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

    return _decodeRequest(response, expectedStatus: 200, context: 'poll');
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
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (e) {
      throw CoordinationException('$context returned malformed JSON: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw CoordinationException(
        '$context returned an unexpected JSON shape: ${decoded.runtimeType}',
      );
    }
    return CoordinationRequest.fromJson(decoded);
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

// --- JSON parsing helpers (typed, no dynamic calls) ---

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
