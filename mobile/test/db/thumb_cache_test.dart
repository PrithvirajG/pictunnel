import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/api/api_client.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/db/thumb_cache.dart';

import '../support/fake_adapter.dart';

/// Records every SELECT that reads thumbnail rows (not aggregates).
class _RowReads extends QueryInterceptor {
  final statements = <String>[];
  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    if (statement.contains('"thumb_entries"') &&
        !statement.contains('SUM(')) {
      statements.add(statement);
    }
    return super.runSelect(executor, statement, args);
  }
}

class _Tokens implements TokenProvider {
  @override
  Future<String> accessToken() async => 'pt_at_x';
}

void main() {
  late AppDb db;
  late Directory dir;

  setUp(() {
    db = AppDb(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('thumbs');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ThumbCache build(FakeAdapter fake,
      {int budget = 300, void Function(String, String)? retry, DateTime Function()? now}) {
    final dio = Dio()..httpClientAdapter = fake;
    final client = createApiClient(
        baseUrl: 'https://pt.test', tokens: _Tokens(), dio: dio);
    return ThumbCache(
        api: client.getAssetsApi(),
        db: db,
        dir: dir,
        budgetBytes: budget,
        now: now,
        scheduleRetry: retry);
  }

  test('thumbCacheEvictsLru', () async {
    var t = DateTime.utc(2026);
    final fake = FakeAdapter((r) => FakeReply.bytes(200, List.filled(100, 7)));
    final cache = build(fake, now: () => t = t.add(const Duration(seconds: 1)));

    final a = await cache.get('a', 'thumb');
    await cache.get('b', 'thumb');
    await cache.get('c', 'thumb');
    expect(fake.requests.length, 3);
    await cache.get('a', 'thumb'); // touch a: b is now the oldest
    expect(fake.requests.length, 3);

    await cache.get('d', 'thumb'); // 4 files > 3-file budget
    expect(File('${dir.path}/b-thumb.jpg').existsSync(), isFalse);
    expect(a!.existsSync(), isTrue);
    expect(File('${dir.path}/c-thumb.jpg').existsSync(), isTrue);
    expect(File('${dir.path}/d-thumb.jpg').existsSync(), isTrue);

    await cache.get('b', 'thumb'); // refetched after eviction
    expect(fake.requests.length, 5);
  });

  test('notReadyReturnsNull', () async {
    final retries = <String>[];
    final fake =
        FakeAdapter((r) => FakeReply.json(404, problem('not_ready', 404)));
    final cache = build(fake, retry: (id, size) => retries.add('$id/$size'));

    expect(await cache.get('x', 'thumb'), isNull);
    expect(retries, ['x/thumb']);
  });

  test('an asset id cannot steer the file out of the cache dir', () async {
    final fake = FakeAdapter((r) => FakeReply.bytes(200, List.filled(10, 7)));
    final cache = build(fake, budget: 10000);
    for (final id in ['../../escape', r'..\..\escape', '..', 'a/b']) {
      final f = (await cache.get(id, '../x'))!;
      expect(f.parent.absolute.path, dir.absolute.path, reason: id);
      expect(f.path.split(Platform.pathSeparator).last, isNot(contains('/')));
    }
    // Distinct ids never share a file.
    final a = await cache.get('a/b', 'thumb');
    final b = await cache.get('a_b', 'thumb');
    expect(a!.path, isNot(b!.path));
  });

  test('eviction reads no rows while under budget, few when over', () async {
    final rows = _RowReads();
    await db.close();
    db = AppDb(NativeDatabase.memory().interceptWith(rows));
    var t = DateTime.utc(2026);
    final fake = FakeAdapter((r) => FakeReply.bytes(200, List.filled(100, 7)));
    final cache = build(fake,
        budget: 100 * 300, now: () => t = t.add(const Duration(seconds: 1)));
    await db.batch((b) {
      for (var i = 0; i < 299; i++) {
        b.insert(
            db.thumbEntries,
            ThumbEntry(
                assetId: 'seed$i',
                size: 'thumb',
                path: '${dir.path}/none$i',
                bytes: 100,
                lastUsedAt: DateTime.utc(2025, 1, 1, 0, 0, i)));
      }
    });

    rows.statements.clear();
    await cache.get('new1', 'thumb'); // 300 entries: at budget
    // Only the cache lookup itself reads a row.
    expect(rows.statements.length, 1, reason: rows.statements.join(' | '));

    rows.statements.clear();
    await cache.get('new2', 'thumb'); // one over: one small batch is read
    expect(rows.statements.length, 2, reason: rows.statements.join(' | '));
    expect(rows.statements.last, contains('LIMIT'));
    final left = await db.select(db.thumbEntries).get();
    expect(left.length, 300);
    expect(left.any((e) => e.assetId == 'seed0'), isFalse);
    expect(left.any((e) => e.assetId == 'new2'), isTrue);
  });
}
