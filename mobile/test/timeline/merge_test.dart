import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glados/glados.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/db/server_assets_dao.dart';
import 'package:pictunnel/core/engine/pigeon.g.dart';
import 'package:pictunnel/features/timeline/timeline_merge.dart';
import 'package:pictunnel/features/timeline/timeline_model.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';

final _now = DateTime.utc(2026, 10, 17, 12);

ServerAsset _server(String id, String sha, DateTime at,
        {String state = 'active', String kind = 'image'}) =>
    ServerAsset(
      id: id,
      sha256: sha,
      sizeBytes: 10,
      mime: kind == 'video' ? 'video/mp4' : 'image/jpeg',
      kind: kind,
      filename: '$id.jpg',
      sortAt: at,
      year: at.year,
      month: at.month,
      state: state,
      thumbnailsReady: true,
      updatedSeq: 1,
    );

PhoneItem _phone(String id, String? sha, DateTime at,
        {ItemState state = ItemState.discovered, bool live = false}) =>
    PhoneItem(
      localId: id,
      filename: '$id.jpg',
      sha256: sha,
      takenAtMs: at.millisecondsSinceEpoch,
      mime: 'image/jpeg',
      size: 10,
      state: state,
      isLivePhoto: live,
    );

class _Scenario {
  _Scenario(this.server, this.phone);
  final List<ServerAsset> server;
  final List<PhoneItem> phone;
}

/// Deterministic random scenario from [seed]; small sha pool forces overlaps.
_Scenario _scenario(int seed) {
  final r = Random(seed);
  DateTime when() =>
      _now.subtract(Duration(hours: r.nextInt(24 * 400), minutes: r.nextInt(60)));
  final server = <ServerAsset>[
    for (var i = 0; i < r.nextInt(40); i++)
      _server('s$i', 'sha${r.nextInt(30)}', when(),
          state: r.nextInt(4) == 0 ? 'trashed' : 'active',
          kind: r.nextBool() ? 'video' : 'image'),
  ];
  final phone = <PhoneItem>[
    for (var i = 0; i < r.nextInt(40); i++)
      _phone('p$i', r.nextInt(3) == 0 ? null : 'sha${r.nextInt(30)}', when(),
          live: r.nextBool()),
  ];
  return _Scenario(server, phone);
}

List<TimelineItem> _flat(List<TimelineSection> s) =>
    [for (final x in s) ...x.items];

class _FakeIndex implements PhoneIndexSource {
  _FakeIndex(List<PhoneItem> items)
      : items = ([...items]..sort((a, b) {
          final t = b.takenAtMs.compareTo(a.takenAtMs);
          return t != 0 ? t : b.localId.compareTo(a.localId);
        }));
  final List<PhoneItem> items;
  int pageCalls = 0;
  int itemsReturned = 0;

  @override
  Future<PhoneItemPage> page(PageRequest req) async {
    pageCalls++;
    var start = 0;
    final k = req.afterKey;
    if (k != null) {
      final i = k.indexOf('|');
      final ms = int.parse(k.substring(0, i));
      final id = k.substring(i + 1);
      // First item strictly after the key in (ms desc, id desc) order.
      var lo = 0, hi = items.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        final it = items[mid];
        final after = it.takenAtMs < ms ||
            (it.takenAtMs == ms && it.localId.compareTo(id) < 0);
        if (after) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      start = lo;
    }
    final end = min(start + req.limit, items.length);
    final slice = items.sublist(start, end);
    itemsReturned += slice.length;
    final next = end < items.length
        ? '${items[end - 1].takenAtMs}|${items[end - 1].localId}'
        : null;
    return PhoneItemPage(items: slice, nextKey: next);
  }
}

void main() {
  Glados<int>(any.int, ExploreConfig(numRuns: 60)).test(
      'every active server asset and phone item appears exactly once', (seed) {
    final s = _scenario(seed);
    final flat = _flat(mergeMonth(s.server, s.phone, now: _now));
    final active = s.server.where((a) => a.state == 'active').toList();
    // Count underlying records covered.
    final serverIds = <String>[];
    final phoneIds = <String>[];
    for (final it in flat) {
      if (it.server != null) serverIds.add(it.server!.id);
      if (it.phone != null) phoneIds.add(it.phone!.localId);
    }
    expect(serverIds.toSet().length, serverIds.length);
    expect(phoneIds.toSet().length, phoneIds.length);
    expect(serverIds.toSet(), active.map((a) => a.id).toSet());
    expect(phoneIds.toSet(), s.phone.map((p) => p.localId).toSet());
    expect(flat.map((i) => i.key).toSet().length, flat.length);
  });

  Glados<int>(any.int, ExploreConfig(numRuns: 60)).test(
      'equal sha yields exactly one both item', (seed) {
    final s = _scenario(seed);
    final flat = _flat(mergeMonth(s.server, s.phone, now: _now));
    final activeShas = {
      for (final a in s.server.where((a) => a.state == 'active')) a.sha256
    };
    final phoneShas = {
      for (final p in s.phone)
        if (p.sha256 != null) p.sha256!
    };
    final both = flat.where((i) => i.presence == Presence.both).toList();
    expect(both.map((i) => i.key).toSet(),
        activeShas.intersection(phoneShas));
    expect(both.length, activeShas.intersection(phoneShas).length);
    for (final b in both) {
      expect(b.server!.sha256, b.phone!.sha256);
    }
  });

  Glados<int>(any.int, ExploreConfig(numRuns: 60)).test(
      'phone item without sha is phoneOnly', (seed) {
    final s = _scenario(seed);
    final flat = _flat(mergeMonth(s.server, s.phone, now: _now));
    for (final it in flat.where((i) => i.phone != null)) {
      if (it.phone!.sha256 == null) {
        expect(it.presence, Presence.phoneOnly);
        expect(it.key, 'local:${it.phone!.localId}');
      }
    }
  });

  Glados<int>(any.int, ExploreConfig(numRuns: 60)).test(
      'trashed server assets are excluded', (seed) {
    final s = _scenario(seed);
    final flat = _flat(mergeMonth(s.server, s.phone, now: _now));
    final trashed = s.server.where((a) => a.state != 'active').map((a) => a.id);
    for (final it in flat) {
      expect(trashed.contains(it.server?.id), isFalse);
    }
  });

  Glados<int>(any.int, ExploreConfig(numRuns: 60)).test(
      'ordering is total and stable', (seed) {
    final s = _scenario(seed);
    final a = _flat(mergeMonth(s.server, s.phone, now: _now));
    final b = _flat(mergeMonth(
        s.server.reversed.toList(), s.phone.reversed.toList(),
        now: _now));
    expect(a.map((i) => i.key).toList(), b.map((i) => i.key).toList());
    for (var i = 1; i < a.length; i++) {
      final c = compareItems(a[i - 1], a[i]);
      expect(c <= 0, isTrue, reason: '${a[i - 1]} before ${a[i]}');
      expect(a[i - 1].takenAt.compareTo(a[i].takenAt) >= 0, isTrue);
    }
  });

  test('sections: this week first, then months newest first', () {
    final sections = mergeMonth([
      _server('a', 'x1', _now.subtract(const Duration(days: 2))),
      _server('b', 'x2', DateTime.utc(2026, 9, 3)),
      _server('c', 'x3', DateTime.utc(2025, 12, 31)),
    ], [
      _phone('p', null, DateTime.utc(2026, 9, 20)),
    ], now: _now);
    expect(sections.map((s) => s.label).toList(),
        ['This week', 'September 2026', 'December 2025']);
    expect(sections[1].items.map((i) => i.key).toList(),
        ['local:p', 'x2']);
  });

  test('badges fields: video, live, phone state', () {
    final items = _flat(mergeMonth(
      [_server('v', 'v1', DateTime.utc(2026, 3, 1), kind: 'video')],
      [_phone('l', 'v1', DateTime.utc(2026, 3, 1),
          state: ItemState.uploading, live: true)],
      now: _now,
    ));
    expect(items.single.presence, Presence.both);
    expect(items.single.isVideo, isTrue);
    expect(items.single.isLive, isTrue);
    expect(items.single.phoneState, ItemState.uploading);
  });

  test('mergeIsPerMonthAndPaged', () async {
    // 100k phone items spread over ~100 months, 1000 per month.
    final base = DateTime(2018, 1, 1);
    final phone = <PhoneItem>[];
    for (var m = 0; m < 100; m++) {
      final start = DateTime(base.year, base.month + m);
      for (var i = 0; i < 1000; i++) {
        phone.add(_phone('m${m}_$i', null,
            start.add(Duration(minutes: i * 30 + 1))));
      }
    }
    expect(phone.length, 100000);
    final source = _FakeIndex(phone);

    const target = MonthKey(2022, 6);
    final loaded = await loadPhoneMonth(source, target, limit: 500);
    expect(source.pageCalls, lessThanOrEqualTo(3));
    expect(loaded.length, 1000);
    for (final p in loaded) {
      expect(
          MonthKey.of(DateTime.fromMillisecondsSinceEpoch(p.takenAtMs)),
          target);
    }
    // Touches only the month's items plus at most one extra page of context.
    expect(source.itemsReturned, lessThanOrEqualTo(1500));

    final sections = mergeMonth([
      _server('s1', 'zzz', DateTime(2022, 6, 5)),
      _server('s2', 'yyy', DateTime(2022, 6, 6), state: 'trashed'),
    ], loaded, now: _now);
    expect(_flat(sections).length, 1001);
    expect(sections.single.month, target);
  });

  test('mergeIsPerMonthAndPaged: month page count is at most 2', () async {
    final items = [
      for (var i = 0; i < 300; i++)
        _phone('a$i', null, DateTime(2024, 5, 1).add(Duration(hours: i))),
      for (var i = 0; i < 60000; i++)
        _phone('o$i', null, DateTime(2020, 1, 1).add(Duration(minutes: i))),
      for (var i = 0; i < 40000; i++)
        _phone('n$i', null, DateTime(2025, 2, 1).add(Duration(minutes: i))),
    ];
    final source = _FakeIndex(items);
    final got = await loadPhoneMonth(source, const MonthKey(2024, 5));
    expect(got.length, 300);
    expect(source.pageCalls, lessThanOrEqualTo(2));
  });

  test('timelineMonthProvider merges one month from db and index',
      () async {
    final db = AppDb(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = ServerAssetsDao(db);
    final source = _FakeIndex([
      _phone('p1', 'shaA', DateTime(2025, 4, 10, 8)),
      _phone('p2', null, DateTime(2025, 4, 11, 8)),
      _phone('p3', null, DateTime(2025, 3, 11, 8)),
    ]);
    final container = ProviderContainer(overrides: [
      serverAssetsDaoProvider.overrideWithValue(dao),
      phoneIndexSourceProvider.overrideWithValue(source),
      clockProvider.overrideWithValue(() => _now),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(
        timelineMonthProvider(const MonthKey(2025, 4)), (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final v = container.read(timelineMonthProvider(const MonthKey(2025, 4)));
    expect(v.hasValue, isTrue);
    expect(_flat(v.value!).map((i) => i.key).toList(),
        ['local:p2', 'shaA']);
  });
}
