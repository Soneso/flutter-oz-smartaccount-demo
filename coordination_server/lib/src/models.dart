/// Domain models, validation, and typed errors for the coordination server.
///
/// The wire contract is locked: the reference agent and the Flutter inbox
/// depend on the exact field names, types, and status values defined here.
library;

/// Lifecycle state of a coordination request.
///
/// A request is created as [pending] and transitions exactly once to either
/// [approved] or [rejected]. No other transition is permitted.
enum RequestStatus {
  pending('pending'),
  approved('approved'),
  rejected('rejected');

  const RequestStatus(this.wireName);

  /// The string used on the wire and in persisted JSON.
  final String wireName;

  /// Parses a wire value into a [RequestStatus].
  ///
  /// Throws [ValidationException] when [value] is not a known status.
  static RequestStatus fromWire(String value) {
    for (final status in RequestStatus.values) {
      if (status.wireName == value) {
        return status;
      }
    }
    throw ValidationException(
      "status must be one of 'pending', 'approved', 'rejected'",
    );
  }
}

/// A policy-rejected smart-account call awaiting human approval.
///
/// Instances are immutable; mutations produce a new object via [copyWith].
/// The `args` list holds base64-encoded `XdrSCVal` entries that are opaque to
/// the server and are stored and returned verbatim so the inbox can rebuild
/// the original call exactly.
class SmartAccountRequest {
  const SmartAccountRequest({
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

  /// Builds a request from its persisted/transported JSON representation.
  ///
  /// Throws [ValidationException] when a field is missing or has the wrong
  /// type, keeping a persisted store file from loading silently corrupted
  /// records.
  factory SmartAccountRequest.fromJson(Map<String, dynamic> json) {
    return SmartAccountRequest(
      id: _requireNonEmptyString(json, 'id'),
      smartAccount: _requireNonEmptyString(json, 'smartAccount'),
      target: _requireNonEmptyString(json, 'target'),
      targetFn: _requireNonEmptyString(json, 'targetFn'),
      args: _requireStringList(json, 'args'),
      amount: _requireString(json, 'amount'),
      reason: _requireInt(json, 'reason'),
      status: RequestStatus.fromWire(_requireNonEmptyString(json, 'status')),
      createdAt: _requireInt(json, 'createdAt'),
      resolvedAt: _optionalInt(json, 'resolvedAt'),
      resultHash: _optionalString(json, 'resultHash'),
      note: _optionalString(json, 'note'),
    );
  }

  /// Server-assigned UUID v4 identifier.
  final String id;

  /// C-address of the smart account the call targets.
  final String smartAccount;

  /// C-address the agent attempted to call.
  final String target;

  /// Contract function name, e.g. `transfer`.
  final String targetFn;

  /// Base64-encoded `XdrSCVal` arguments, opaque to the server.
  final List<String> args;

  /// Display-only amount string. Empty when the agent supplied none.
  final String amount;

  /// On-chain rejection contract error code, e.g. `3016`.
  final int reason;

  /// Current lifecycle state.
  final RequestStatus status;

  /// Creation time in unix milliseconds.
  final int createdAt;

  /// Resolution time in unix milliseconds, or `null` while pending.
  final int? resolvedAt;

  /// Transaction/result hash recorded on approval, or `null`.
  final String? resultHash;

  /// Optional free-text note recorded on rejection, or `null`.
  final String? note;

  /// Whether this request has already transitioned out of [RequestStatus.pending].
  bool get isResolved => status != RequestStatus.pending;

  /// Returns a copy with the supplied fields replaced.
  ///
  /// `resolvedAt`, `resultHash`, and `note` are nullable; sentinel wrappers
  /// let callers distinguish "leave unchanged" from "set to null".
  SmartAccountRequest copyWith({
    RequestStatus? status,
    Object? resolvedAt = _unset,
    Object? resultHash = _unset,
    Object? note = _unset,
  }) {
    return SmartAccountRequest(
      id: id,
      smartAccount: smartAccount,
      target: target,
      targetFn: targetFn,
      args: args,
      amount: amount,
      reason: reason,
      status: status ?? this.status,
      createdAt: createdAt,
      resolvedAt:
          identical(resolvedAt, _unset) ? this.resolvedAt : resolvedAt as int?,
      resultHash:
          identical(resultHash, _unset)
              ? this.resultHash
              : resultHash as String?,
      note: identical(note, _unset) ? this.note : note as String?,
    );
  }

  /// Serializes to the canonical wire/persistence JSON shape.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'smartAccount': smartAccount,
      'target': target,
      'targetFn': targetFn,
      'args': List<String>.unmodifiable(args),
      'amount': amount,
      'reason': reason,
      'status': status.wireName,
      'createdAt': createdAt,
      'resolvedAt': resolvedAt,
      'resultHash': resultHash,
      'note': note,
    };
  }
}

/// Sentinel marking an unsupplied [SmartAccountRequest.copyWith] argument.
const Object _unset = Object();

/// Validated input for `POST /requests`.
///
/// The client supplies only the agent-controlled fields; the server assigns
/// `id`, `status`, and `createdAt`.
class CreateRequestInput {
  const CreateRequestInput({
    required this.smartAccount,
    required this.target,
    required this.targetFn,
    required this.args,
    required this.amount,
    required this.reason,
  });

  /// Validates a decoded JSON object into a [CreateRequestInput].
  ///
  /// Throws [ValidationException] with a field-specific message on any
  /// missing or wrongly typed field. Server-assigned fields present in the
  /// body are ignored.
  factory CreateRequestInput.fromJson(Map<String, dynamic> json) {
    return CreateRequestInput(
      smartAccount: _requireNonEmptyString(json, 'smartAccount'),
      target: _requireNonEmptyString(json, 'target'),
      targetFn: _requireNonEmptyString(json, 'targetFn'),
      args: _requireStringList(json, 'args'),
      amount: _optionalString(json, 'amount') ?? '',
      reason: _requireInt(json, 'reason'),
    );
  }

  final String smartAccount;
  final String target;
  final String targetFn;
  final List<String> args;
  final String amount;
  final int reason;
}

/// Raised when a client-supplied value fails validation. Maps to HTTP 400.
class ValidationException implements Exception {
  ValidationException(this.message);

  final String message;

  @override
  String toString() => 'ValidationException: $message';
}

/// Raised when a referenced request id does not exist. Maps to HTTP 404.
class NotFoundException implements Exception {
  NotFoundException(this.message);

  final String message;

  @override
  String toString() => 'NotFoundException: $message';
}

/// Raised when a state transition is not permitted, e.g. resolving an
/// already-resolved request. Maps to HTTP 409.
class ConflictException implements Exception {
  ConflictException(this.message);

  final String message;

  @override
  String toString() => 'ConflictException: $message';
}

String _requireString(Map<String, dynamic> json, String field) {
  final dynamic value = json[field];
  if (value is! String) {
    throw ValidationException("field '$field' must be a string");
  }
  return value;
}

String _requireNonEmptyString(Map<String, dynamic> json, String field) {
  final value = _requireString(json, field);
  if (value.isEmpty) {
    throw ValidationException("field '$field' must not be empty");
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String field) {
  final dynamic value = json[field];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw ValidationException("field '$field' must be a string when present");
  }
  return value;
}

int _requireInt(Map<String, dynamic> json, String field) {
  final dynamic value = json[field];
  if (value is! int) {
    throw ValidationException("field '$field' must be an integer");
  }
  return value;
}

int? _optionalInt(Map<String, dynamic> json, String field) {
  final dynamic value = json[field];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw ValidationException("field '$field' must be an integer when present");
  }
  return value;
}

List<String> _requireStringList(Map<String, dynamic> json, String field) {
  final dynamic value = json[field];
  if (value is! List) {
    throw ValidationException("field '$field' must be a list of strings");
  }
  final result = <String>[];
  for (final element in value) {
    if (element is! String) {
      throw ValidationException(
        "field '$field' must contain only string elements",
      );
    }
    result.add(element);
  }
  return result;
}
