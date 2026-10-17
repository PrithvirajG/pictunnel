import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/api/api_client.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/db/thumb_cache.dart';

import '../support/fake_adapter.dart';

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
}
