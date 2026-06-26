import 'dart:convert';
import 'dart:io';

import 'package:coordination_server/coordination_server.dart';
import 'package:test/test.dart';

CreateRequestInput _input({
  String smartAccount = 'CSMART',
  String target = 'CTARGET',
  String targetFn = 'transfer',
  List<String> args = const <String>['AAAA', 'BBBB'],
  String amount = '10.5',
  int reason = 3016,
}) {
  return CreateRequestInput(
    smartAccount: smartAccount,
    target: target,
    targetFn: targetFn,
    args: args,
    amount: amount,
    reason: reason,
  );
}

void main() {
  group('RequestStore CRUD', () {
    test('create assigns id, pending status, and createdAt', () async {
      var counter = 0;
      final store = RequestStore(
        idGenerator: () => 'id-${counter++}',
        clock: () => 1700000000000,
      );

      final created = await store.create(_input());

      expect(created.id, 'id-0');
      expect(created.status, RequestStatus.pending);
      expect(created.createdAt, 1700000000000);
      expect(created.resolvedAt, isNull);
      expect(created.resultHash, isNull);
      expect(created.note, isNull);
      expect(created.amount, '10.5');
      expect(created.reason, 3016);
      expect(created.args, <String>['AAAA', 'BBBB']);
    });

    test('args are stored verbatim and returned unmodifiable', () async {
      final store = RequestStore();
      final created = await store.create(
        _input(args: const <String>['Zm9v', 'YmFy']),
      );
      expect(created.args, <String>['Zm9v', 'YmFy']);
      expect(() => created.args.add('x'), throwsUnsupportedError);
    });

    test('getById returns the request or null', () async {
      final store = RequestStore();
      final created = await store.create(_input());
      expect(store.getById(created.id), same(created));
      expect(store.getById('missing'), isNull);
    });

    test('list returns newest first', () async {
      var counter = 0;
      final store = RequestStore(idGenerator: () => 'id-${counter++}');
      final a = await store.create(_input());
      final b = await store.create(_input());
      final c = await store.create(_input());

      final ids = store.list().map((r) => r.id).toList();
      expect(ids, <String>[c.id, b.id, a.id]);
    });

    test('list filters by status', () async {
      var counter = 0;
      final store = RequestStore(idGenerator: () => 'id-${counter++}');
      final a = await store.create(_input());
      final b = await store.create(_input());
      await store.create(_input());

      await store.approve(a.id, resultHash: 'hashA');
      await store.reject(b.id, note: 'nope');

      expect(
        store.list(status: RequestStatus.pending).length,
        1,
      );
      expect(
        store.list(status: RequestStatus.approved).single.id,
        a.id,
      );
      expect(
        store.list(status: RequestStatus.rejected).single.id,
        b.id,
      );
    });
  });

  group('RequestStore transitions', () {
    test('approve sets status, resolvedAt, and resultHash', () async {
      final store = RequestStore(clock: () => 42);
      final created = await store.create(_input());
      final approved = await store.approve(created.id, resultHash: 'abc123');

      expect(approved.status, RequestStatus.approved);
      expect(approved.resolvedAt, 42);
      expect(approved.resultHash, 'abc123');
      expect(approved.note, isNull);
      expect(store.getById(created.id), same(approved));
    });

    test('reject sets status, resolvedAt, and optional note', () async {
      final store = RequestStore(clock: () => 99);
      final created = await store.create(_input());
      final rejected = await store.reject(created.id, note: 'policy violation');

      expect(rejected.status, RequestStatus.rejected);
      expect(rejected.resolvedAt, 99);
      expect(rejected.note, 'policy violation');
      expect(rejected.resultHash, isNull);
    });

    test('reject without a note leaves note null', () async {
      final store = RequestStore();
      final created = await store.create(_input());
      final rejected = await store.reject(created.id);
      expect(rejected.note, isNull);
    });

    test('approve on unknown id throws NotFoundException', () async {
      final store = RequestStore();
      expect(
        () => store.approve('nope', resultHash: 'h'),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('reject on unknown id throws NotFoundException', () async {
      final store = RequestStore();
      expect(
        () => store.reject('nope'),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('double approve throws ConflictException', () async {
      final store = RequestStore();
      final created = await store.create(_input());
      await store.approve(created.id, resultHash: 'h1');
      expect(
        () => store.approve(created.id, resultHash: 'h2'),
        throwsA(isA<ConflictException>()),
      );
    });

    test('approving an already rejected request throws ConflictException',
        () async {
      final store = RequestStore();
      final created = await store.create(_input());
      await store.reject(created.id);
      expect(
        () => store.approve(created.id, resultHash: 'h'),
        throwsA(isA<ConflictException>()),
      );
    });

    test('rejecting an already approved request throws ConflictException',
        () async {
      final store = RequestStore();
      final created = await store.create(_input());
      await store.approve(created.id, resultHash: 'h');
      expect(
        () => store.reject(created.id),
        throwsA(isA<ConflictException>()),
      );
    });
  });

  group('RequestStore persistence', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('coord_store_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('round-trips state through the store file', () async {
      final path = '${tempDir.path}/store.json';
      var counter = 0;
      final writer = RequestStore(
        storePath: path,
        idGenerator: () => 'id-${counter++}',
        clock: () => 1000,
      );
      final a = await writer.create(_input(amount: 'one'));
      final b = await writer.create(_input(amount: 'two'));
      await writer.approve(a.id, resultHash: 'tx-hash');
      await writer.reject(b.id, note: 'too risky');

      expect(File(path).existsSync(), isTrue);

      final reader = RequestStore(storePath: path);
      await reader.load();

      final loaded = reader.list();
      expect(loaded.length, 2);
      // Newest-first preserved across reload.
      expect(loaded.first.id, b.id);
      expect(loaded.last.id, a.id);

      final loadedA = reader.getById(a.id)!;
      expect(loadedA.status, RequestStatus.approved);
      expect(loadedA.resultHash, 'tx-hash');
      expect(loadedA.amount, 'one');

      final loadedB = reader.getById(b.id)!;
      expect(loadedB.status, RequestStatus.rejected);
      expect(loadedB.note, 'too risky');
    });

    test('writes a well-formed JSON array atomically', () async {
      final path = '${tempDir.path}/store.json';
      final store = RequestStore(storePath: path);
      await store.create(_input());

      final dynamic decoded = jsonDecode(File(path).readAsStringSync());
      expect(decoded, isA<List<dynamic>>());
      expect((decoded as List).single, isA<Map<String, dynamic>>());
      // The temp file must not linger after an atomic rename.
      expect(File('$path.tmp').existsSync(), isFalse);
    });

    test('load on a missing file leaves an empty store', () async {
      final store = RequestStore(storePath: '${tempDir.path}/absent.json');
      await store.load();
      expect(store.list(), isEmpty);
    });

    test('load rejects a non-array store file', () async {
      final path = '${tempDir.path}/bad.json';
      File(path).writeAsStringSync('{"not":"an array"}');
      final store = RequestStore(storePath: path);
      expect(store.load(), throwsA(isA<FormatException>()));
    });

    test('concurrent mutations persist the final consistent snapshot',
        () async {
      final path = '${tempDir.path}/store.json';
      var counter = 0;
      final store = RequestStore(
        storePath: path,
        idGenerator: () => 'id-${counter++}',
      );

      // Fire several mutations without awaiting individually to exercise the
      // serialized write queue.
      final futures = <Future<Object>>[
        store.create(_input()),
        store.create(_input()),
        store.create(_input()),
      ];
      await Future.wait(futures);

      final reader = RequestStore(storePath: path);
      await reader.load();
      expect(reader.list().length, 3);
    });
  });
}
