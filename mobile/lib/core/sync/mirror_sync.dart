import 'dart:async';

import 'package:dio/dio.dart';
import 'package:pictunnel_api/pictunnel_api.dart';

import '../api/api_client.dart';
import '../db/app_db.dart';
import '../db/server_assets_dao.dart';
import '../decisions/decide.dart';

/// Keeps the local mirror of server metadata current: snapshot paging, then
/// the change feed from the cursor (sync-protocol §7.6).
class MirrorSync {
  MirrorSync({required this.api, required this.db, this.pageSize = 500})
      : _dao = ServerAssetsDao(db);

  final SyncApi api;
  final AppDb db;
  final ServerAssetsDao _dao;
  final int pageSize;
  final _changes = StreamController<int>.broadcast();
  Future<void>? _running;

  /// Emits the number of mirror rows changed after each page that changed any.
  Stream<int> get changes => _changes.stream;

  /// Runs one sync. Concurrent calls share the same run.
  Future<void> syncOnce() => _running ??= _run().whenComplete(() {
        _running = null;
      });

  Future<void> _run() async {
    final cursor = await _dao.cursor();
    if (cursor == null) {
      await _snapshot();
      return;
    }
    try {
      await _feed(cursor);
    } on DioException catch (e) {
      if (!_needsSnapshot(e)) rethrow;
      await _dao.clear();
      await _dao.clearCursor();
      await _snapshot();
    }
  }

  bool _needsSnapshot(DioException e) {
    final r = e.response;
    if (r == null) return false;
    final d = decide(
        const Given(flow: 'browse', lastAction: 'changes'), outcomeOf(e));
    return d.action == 'run_snapshot' || r.statusCode == 410;
  }

  Future<void> _snapshot() async {
    String? pageToken;
    String? cursor;
    while (true) {
      final page =
          (await api.getSnapshot(pageToken: pageToken, limit: pageSize))
              .data!;
      cursor ??= page.cursor;
      var changed = 0;
      await db.transaction(() async {
        for (final a in page.assets) {
          if (await _dao.upsert(a)) changed++;
        }
      });
      if (changed > 0) _changes.add(changed);
      pageToken = page.nextPageToken;
      if (!page.hasMore || pageToken == null) break;
    }
    if (cursor == null) {
      throw StateError('snapshot returned no cursor');
    }
    await _dao.setCursor(cursor);
    await _feed(cursor);
  }

  Future<void> _feed(String start) async {
    var cursor = start;
    while (true) {
      final page =
          (await api.getChanges(cursor: cursor, limit: pageSize)).data!;
      var changed = 0;
      await db.transaction(() async {
        for (final c in page.changes) {
          switch (c.kind) {
            case 'asset.upsert':
              final a = c.asset;
              if (a != null && await _dao.upsert(a)) changed++;
            case 'asset.removed':
              final id = c.assetId;
              if (id != null && await _dao.remove(id)) changed++;
            default:
              break; // clients MUST ignore unknown kinds
          }
        }
        await _dao.setCursor(page.nextCursor);
      });
      cursor = page.nextCursor;
      if (changed > 0) _changes.add(changed);
      if (!page.hasMore) break;
    }
  }

  Future<void> dispose() => _changes.close();
}
