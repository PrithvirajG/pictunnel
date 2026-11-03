import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/api/api_client.dart';
import 'package:pictunnel_api/pictunnel_api.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/db/server_assets_dao.dart';
import 'package:pictunnel/core/sync/mirror_sync.dart';

import '../support/fake_adapter.dart';

class _Tokens implements TokenProvider {
  int calls = 0;
  @override
  Future<String> accessToken() async => 'pt_at_${++calls}';
}

void main() {
  late AppDb db;
  late ServerAssetsDao dao;

  setUp(() {
    db = AppDb(NativeDatabase.memory());
    dao = ServerAssetsDao(db);
  });
  tearDown(() => db.close());

  MirrorSync build(FakeAdapter fake) {
    final dio = Dio()..httpClientAdapter = fake;
    final client = createApiClient(
        baseUrl: 'https://pt.test', tokens: _Tokens(), dio: dio);
    return MirrorSync(api: client.getSyncApi(), db: db, pageSize: 2);
  }

  test('snapshotThenChanges', () async {
    final fake = FakeAdapter((r) {
      if (r.path.endsWith('/sync/snapshot')) {
        if (r.queryParameters['page_token'] == null) {
          return FakeReply.json(200, {
            'cursor': '10',
            'assets': [assetJson('a1', seq: 5), assetJson('a2', seq: 6)],
            'next_page_token': 'p2',
            'has_more': true,
          });
        }
        return FakeReply.json(200, {
          'assets': [assetJson('a3', seq: 7)],
          'has_more': false,
        });
      }
      expect(r.queryParameters['cursor'], '10');
      return FakeReply.json(200, {
        'changes': [
          {'seq': 11, 'kind': 'asset.upsert', 'asset': assetJson('a4', seq: 11)},
          {'seq': 12, 'kind': 'album.created'},
        ],
        'next_cursor': '12',
        'has_more': false,
      });
    });
    final sync = build(fake);
    final emitted = <int>[];
    sync.changes.listen(emitted.add);

    await sync.syncOnce();

    expect(await dao.total(), 4);
    expect(await dao.cursor(), '12');
    expect(fake.requests.first.headers['Authorization'], startsWith('Bearer '));
    expect(emitted.fold<int>(0, (a, b) => a + b), 4);
    final counts = await dao.watchMonthCounts().first;
    expect(counts.values.fold<int>(0, (a, b) => a + b), 4);
    final month = counts.keys.single;
    expect((await dao.watchMonth(month).first).length, 4);
  });

  test('cursorExpiredResnapshots', () async {
    await dao.upsert(_asset('old', 1));
    await dao.setCursor('3');
    var snapshots = 0;
    final fake = FakeAdapter((r) {
      if (r.path.endsWith('/sync/changes')) {
        if (r.queryParameters['cursor'] == '3') {
          return FakeReply.json(410, problem('cursor_expired', 410));
        }
        return FakeReply.json(
            200, {'changes': [], 'next_cursor': '50', 'has_more': false});
      }
      snapshots++;
      return FakeReply.json(200, {
        'cursor': '50',
        'assets': [assetJson('new', seq: 40)],
        'has_more': false,
      });
    });
    await build(fake).syncOnce();

    expect(snapshots, 1);
    expect(await dao.byId('old'), isNull);
    expect(await dao.byId('new'), isNotNull);
    expect(await dao.cursor(), '50');
  });

  test('410 re-snapshots first, then drops only rows it no longer lists',
      () async {
    await dao.upsert(_asset('old', 1));
    await dao.upsert(_asset('kept', 2));
    await dao.setCursor('3');
    var failSecondPage = true;
    final fake = FakeAdapter((r) {
      if (r.path.endsWith('/sync/changes')) {
        if (r.queryParameters['cursor'] == '3') {
          return FakeReply.json(410, problem('cursor_expired', 410));
        }
        return FakeReply.json(
            200, {'changes': [], 'next_cursor': '50', 'has_more': false});
      }
      if (r.queryParameters['page_token'] == null) {
        return FakeReply.json(200, {
          'cursor': '50',
          'assets': [assetJson('kept', seq: 2), assetJson('new', seq: 40)],
          'next_page_token': 'p2',
          'has_more': true,
        });
      }
      if (failSecondPage) {
        return FakeReply.json(503, problem('unavailable', 503));
      }
      return FakeReply.json(200, {
        'assets': [assetJson('new2', seq: 41)],
        'has_more': false,
      });
    });

    // Interrupted: nothing is wiped, the old rows stay visible meanwhile.
    await expectLater(build(fake).syncOnce(), throwsA(isA<DioException>()));
    expect(await dao.byId('old'), isNotNull);
    expect(await dao.byId('kept'), isNotNull);
    expect(await dao.byId('new'), isNotNull);
    expect(await dao.cursor(), isNull);

    // After a restart the snapshot runs again and sweeps what it never listed.
    failSecondPage = false;
    await build(fake).syncOnce();
    expect(await dao.byId('old'), isNull);
    for (final id in ['kept', 'new', 'new2']) {
      expect(await dao.byId(id), isNotNull, reason: id);
    }
    expect(await dao.cursor(), '50');
  });

  test('an interrupted first snapshot leaves no stale rows after a restart',
      () async {
    var run = 0;
    final fake = FakeAdapter((r) {
      if (r.path.endsWith('/sync/changes')) {
        return FakeReply.json(
            200, {'changes': [], 'next_cursor': '9', 'has_more': false});
      }
      if (run == 0) {
        if (r.queryParameters['page_token'] == null) {
          return FakeReply.json(200, {
            'cursor': '9',
            'assets': [assetJson('gone', seq: 1), assetJson('a2', seq: 2)],
            'next_page_token': 'p2',
            'has_more': true,
          });
        }
        throw DioException.connectionError(
            requestOptions: r, reason: 'connection reset');
      }
      // Meanwhile `gone` was purged on the server.
      return FakeReply.json(200, {
        'cursor': '9',
        'assets': [assetJson('a2', seq: 2), assetJson('a3', seq: 3)],
        'has_more': false,
      });
    });
    await expectLater(build(fake).syncOnce(), throwsA(isA<DioException>()));
    expect(await dao.byId('gone'), isNotNull);

    run = 1;
    await build(fake).syncOnce();
    expect(await dao.byId('gone'), isNull);
    expect(await dao.total(), 2);
    expect(await dao.cursor(), '9');
  });

  test('staleUpsertIgnored', () async {
    await dao.upsert(_asset('a1', 9, name: 'newer.jpg'));
    await dao.setCursor('9');
    final fake = FakeAdapter((r) => FakeReply.json(200, {
          'changes': [
            {
              'seq': 10,
              'kind': 'asset.upsert',
              'asset': assetJson('a1', seq: 4, filename: 'older.jpg')
            },
          ],
          'next_cursor': '10',
          'has_more': false,
        }));
    await build(fake).syncOnce();
    expect((await dao.byId('a1'))!.filename, 'newer.jpg');
    expect(await dao.cursor(), '10');
  });

  test('removedDeletesRow', () async {
    await dao.upsert(_asset('a1', 1));
    await dao.setCursor('1');
    final fake = FakeAdapter((r) => FakeReply.json(200, {
          'changes': [
            {'seq': 2, 'kind': 'asset.removed', 'asset_id': 'a1'},
          ],
          'next_cursor': '2',
          'has_more': false,
        }));
    await build(fake).syncOnce();
    expect(await dao.byId('a1'), isNull);
  });
}

Asset _asset(String id, int seq, {String name = 'a.jpg'}) =>
    standardSerializers.deserializeWith(
        Asset.serializer, assetJson(id, seq: seq, filename: name))!;
