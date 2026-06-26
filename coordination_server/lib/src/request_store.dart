import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'models.dart';

/// In-memory store of [SmartAccountRequest]s with optional JSON-file
/// persistence.
///
/// The server runs on a single isolate event loop, so in-memory mutations are
/// race-free without locks: each public method mutates synchronously before
/// awaiting persistence. Persistence is serialized through an internal write
/// queue and each flush writes the full snapshot to a temporary file that is
/// atomically renamed over the target, so the store file is never observed in
/// a partially written state.
class RequestStore {
  RequestStore({
    String? storePath,
    String Function()? idGenerator,
    int Function()? clock,
  }) : _storePath = storePath,
       _idGenerator = idGenerator ?? const Uuid().v4,
       _clock = clock ?? _defaultClock;

  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  final String? _storePath;
  final String Function() _idGenerator;
  final int Function() _clock;

  /// Records keyed by id for O(1) lookup.
  final Map<String, SmartAccountRequest> _byId = <String, SmartAccountRequest>{};

  /// Insertion order of ids. Reversed when listing so newest appears first.
  final List<String> _order = <String>[];

  /// Tail of the serialized write queue; keeps flushes ordered and
  /// non-overlapping.
  Future<void> _writeQueue = Future<void>.value();

  /// Path of the backing JSON file, or `null` when persistence is disabled.
  String? get storePath => _storePath;

  /// Loads persisted records when a store path is configured and the file
  /// exists. Safe to call once during startup.
  ///
  /// Throws [FormatException] when the file is not a JSON array of request
  /// objects, and [ValidationException] when a record is structurally
  /// invalid, so a corrupt store fails loudly instead of dropping data.
  Future<void> load() async {
    final path = _storePath;
    if (path == null) {
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      return;
    }
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) {
      return;
    }
    final dynamic decoded = jsonDecode(contents);
    if (decoded is! List) {
      throw const FormatException('store file must contain a JSON array');
    }
    _byId.clear();
    _order.clear();
    for (final dynamic entry in decoded) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException(
          'store file entries must be JSON objects',
        );
      }
      final request = SmartAccountRequest.fromJson(entry);
      _byId[request.id] = request;
      _order.add(request.id);
    }
  }

  /// Creates a new pending request from validated [input], assigning the id,
  /// `createdAt`, and `pending` status. Persists before returning.
  Future<SmartAccountRequest> create(CreateRequestInput input) async {
    final request = SmartAccountRequest(
      id: _idGenerator(),
      smartAccount: input.smartAccount,
      target: input.target,
      targetFn: input.targetFn,
      args: List<String>.unmodifiable(input.args),
      amount: input.amount,
      reason: input.reason,
      status: RequestStatus.pending,
      createdAt: _clock(),
    );
    _byId[request.id] = request;
    _order.add(request.id);
    await _flush();
    return request;
  }

  /// Returns the request with [id], or `null` when absent.
  SmartAccountRequest? getById(String id) => _byId[id];

  /// Returns stored requests newest-first, optionally filtered by [status].
  List<SmartAccountRequest> list({RequestStatus? status}) {
    final result = <SmartAccountRequest>[];
    for (var i = _order.length - 1; i >= 0; i--) {
      final request = _byId[_order[i]]!;
      if (status == null || request.status == status) {
        result.add(request);
      }
    }
    return result;
  }

  /// Transitions a pending request to approved, recording [resultHash] and the
  /// resolution time. Persists before returning.
  ///
  /// Throws [NotFoundException] when [id] is unknown and [ConflictException]
  /// when the request is already resolved.
  Future<SmartAccountRequest> approve(
    String id, {
    required String resultHash,
  }) {
    return _resolve(
      id,
      status: RequestStatus.approved,
      resultHash: resultHash,
    );
  }

  /// Transitions a pending request to rejected, recording the optional [note]
  /// and the resolution time. Persists before returning.
  ///
  /// Throws [NotFoundException] when [id] is unknown and [ConflictException]
  /// when the request is already resolved.
  Future<SmartAccountRequest> reject(String id, {String? note}) {
    return _resolve(id, status: RequestStatus.rejected, note: note);
  }

  Future<SmartAccountRequest> _resolve(
    String id, {
    required RequestStatus status,
    String? resultHash,
    String? note,
  }) async {
    final existing = _byId[id];
    if (existing == null) {
      throw NotFoundException("request '$id' not found");
    }
    if (existing.isResolved) {
      throw ConflictException(
        "request '$id' is already ${existing.status.wireName}",
      );
    }
    final updated = existing.copyWith(
      status: status,
      resolvedAt: _clock(),
      resultHash: resultHash,
      note: note,
    );
    _byId[id] = updated;
    await _flush();
    return updated;
  }

  /// Serializes the current snapshot and appends an atomic write to the queue.
  ///
  /// The snapshot string is captured synchronously, so the persisted file
  /// reflects the state at call time and queued writes apply in call order.
  Future<void> _flush() {
    final path = _storePath;
    if (path == null) {
      return Future<void>.value();
    }
    final snapshot = jsonEncode(
      _order.map((id) => _byId[id]!.toJson()).toList(growable: false),
    );
    final previous = _writeQueue;
    final completer = Completer<void>();
    _writeQueue = completer.future;
    return Future<void>(() async {
      try {
        await previous;
      } catch (_) {
        // A failed earlier write must not stall later ones; its awaiter
        // already received the error.
      }
      try {
        await _writeAtomically(path, snapshot);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
        rethrow;
      }
    });
  }

  Future<void> _writeAtomically(String path, String contents) async {
    final target = File(path);
    final directory = target.parent;
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    final temp = File('$path.tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(path);
  }
}
