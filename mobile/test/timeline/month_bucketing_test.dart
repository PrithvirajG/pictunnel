import 'dart:async';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/db/server_assets_dao.dart';
import 'package:pictunnel/core/engine/pigeon.g.dart';
import 'package:pictunnel/features/timeline/timeline_layout.dart';
import 'package:pictunnel/features/timeline/timeline_merge.dart';
import 'package:pictunnel/features/timeline/timeline_model.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';
import 'package:pictunnel_api/pictunnel_api.dart' as api;

final _now = DateTime.utc(2026, 10, 17, 12);

PhoneItem _phone(
  String id,
  String? sha,
  DateTime at, {
  ItemState state = ItemState.discovered,
}) => PhoneItem(
  localId: id,
  filename: '$id.jpg',
  sha256: sha,
  takenAtMs: at.millisecondsSinceEpoch,
  mime: 'image/jpeg',
  size: 10,
  state: state,
  isLivePhoto: false,
);

api.Asset _apiAsset(String id, String sha, DateTime takenAt) =>
    api.standardSerializers.deserializeWith(api.Asset.serializer, {
      'id': id,
      'sha256': sha,
      'size_bytes': 10,
      'mime': 'image/jpeg',
      'kind': 'photo',
      'filename': '$id.jpg',
      'taken_at': takenAt.toUtc().toIso8601String(),
      'taken_at_offset_minutes': 0,
      'taken_at_source': 'exif',
      'state': 'active',
      'thumbnails_ready': true,
      'created_at': takenAt.toUtc().toIso8601String(),
      'updated_seq': 1,
    })!;

/// A paged phone index in the engine's order that can fail and report
/// changes.
class _Index implements PhoneIndexSource, ChangingPhoneIndex {
  _Index(List<PhoneItem> items)
    : items = ([...items]
        ..sort((a, b) {
          final t = b.takenAtMs.compareTo(a.takenAtMs);
          return t != 0 ? t : b.localId.compareTo(a.localId);
        }));
  final List<PhoneItem> items;
  Object? failWith;
  int pageCalls = 0;
  final _changes = StreamController<PhoneItem>.broadcast();

  @override
  Stream<PhoneItem> get changes => _changes.stream;

  void emit(PhoneItem p) => _changes.add(p);

  @override
  Future<PhoneItemPage> page(PageRequest req) async {
    pageCalls++;
    final e = failWith;
    if (e != null) throw e;
    var start = 0;
    final k = req.afterKey;
    if (k != null) {
      final i = k.indexOf('|');
      final ms = int.parse(k.substring(0, i));
      final id = k.substring(i + 1);
      while (start < items.length) {
        final it = items[start];
        if (it.takenAtMs < ms ||
            (it.takenAtMs == ms && it.localId.compareTo(id) < 0)) {
          break;
        }
        start++;
      }
    }
    final end = min(start + req.limit, items.length);
    return PhoneItemPage(
      items: items.sublist(start, end),
      nextKey: end < items.length
          ? '${items[end - 1].takenAtMs}|${items[end - 1].localId}'
          : null,
    );
  }
}

List<TimelineItem> _flat(List<TimelineSection> s) => [
  for (final x in s) ...x.items,
];

void main() {
  test(
    'an item 2 h into a local month is in that month on both sides',
    () async {
      // Two hours into October, local time. East of UTC (the CI runs in
      // Asia/Kolkata) this instant is still September in UTC, which is
      // where the server's offset-0 wall clock puts it.
      final at = DateTime(2026, 10, 1, 2);
      final db = AppDb(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = ServerAssetsDao(db);
      await dao.upsert(_apiAsset('s1', 'shaB', at));
      final source = _Index([
        _phone('p1', 'shaB', at, state: ItemState.backedUp),
      ]);
      final container = ProviderContainer(
        overrides: [
          serverAssetsDaoProvider.overrideWithValue(dao),
          phoneIndexSourceProvider.overrideWithValue(source),
          clockProvider.overrideWithValue(
            () => _now.add(const Duration(days: 60)),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(await dao.watchMonthCounts().first, {
        const MonthKey(2026, 10): 1,
      });
      expect(await dao.watchMonth(const MonthKey(2026, 9)).first, isEmpty);

      final oct = container.listen(
        timelineMonthProvider(const MonthKey(2026, 10)),
        (_, _) {},
      );
      final sep = container.listen(
        timelineMonthProvider(const MonthKey(2026, 9)),
        (_, _) {},
      );
      final months = container.listen(timelineMonthsProvider, (_, _) {});
      addTearDown(oct.close);
      addTearDown(sep.close);
      addTearDown(months.close);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final items = _flat(oct.read().value!);
      expect(items.length, 1, reason: 'never twice');
      expect(
        items.single.presence,
        Presence.both,
        reason: 'backed up, so it must not read "not backed up"',
      );
      expect(_flat(sep.read().value!), isEmpty);
      expect(months.read().value!.map((m) => m.month).toList(), [
        const MonthKey(2026, 10),
      ]);
      final labels = buildDisplaySections([
        ...sep.read().value!,
        ...oct.read().value!,
      ]).map((d) => d.label);
      expect(labels, ['October 2026']);
    },
  );

  test('display sections merge two sections of one month', () {
    TimelineSection section(String id, DateTime at) =>
        mergeMonth([], [_phone(id, null, at)], now: _now).single;
    final a = section('a', DateTime(2026, 5, 3));
    final b = section('b', DateTime(2026, 5, 9));
    expect(a.month, const MonthKey(2026, 5));
    final out = buildDisplaySections([a, b]);
    expect(out.map((d) => d.label), ['May 2026']);
    expect(out.single.items.map((i) => i.key), ['local:b', 'local:a']);
  });

  test('placeholders stand in for months that are not loaded', () {
    final loaded = mergeMonth(
      [],
      [_phone('a', null, DateTime(2026, 5, 3))],
      now: _now,
    );
    final out = buildDisplaySections(
      loaded,
      months: const [
        MonthSummary(MonthKey(2026, 5), phone: 1),
        MonthSummary(MonthKey(2026, 4), server: 7, phone: 9),
        MonthSummary(MonthKey(2026, 3), server: 4),
      ],
      loaded: {const MonthKey(2026, 5)},
      knownCounts: {const MonthKey(2026, 3): 3},
    );
    expect(out.map((d) => (d.label, d.placeholder)).toList(), [
      ('May 2026', 0),
      ('April 2026', 9),
      ('March 2026', 3),
    ]);
    final rows = layoutRows(out, 3);
    expect(rows.whereType<PlaceholderRow>().map((r) => r.count).toList(), [
      3,
      3,
      3,
      3,
    ]);
  });

  test(
    'timelineMonthProvider reports a failure and recovers on a change',
    () async {
      final db = AppDb(NativeDatabase.memory());
      addTearDown(db.close);
      final at = DateTime(2025, 4, 10, 8);
      final source = _Index([_phone('p1', null, at)])
        ..failWith = PlatformException(code: 'internal');
      final container = ProviderContainer(
        overrides: [
          serverAssetsDaoProvider.overrideWithValue(ServerAssetsDao(db)),
          phoneIndexSourceProvider.overrideWithValue(source),
          clockProvider.overrideWithValue(() => _now),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        timelineMonthProvider(const MonthKey(2025, 4)),
        (_, _) {},
      );
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sub.read().hasError, isTrue);

      source.failWith = null;
      source.emit(_phone('p1', null, at, state: ItemState.queued));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(sub.read().hasError, isFalse);
      expect(_flat(sub.read().value!).map((i) => i.key), ['local:p1']);
    },
  );

  test('not_paired reads as an empty phone month', () async {
    final db = AppDb(NativeDatabase.memory());
    addTearDown(db.close);
    final source = _Index([])..failWith = PlatformException(code: 'not_paired');
    final container = ProviderContainer(
      overrides: [
        serverAssetsDaoProvider.overrideWithValue(ServerAssetsDao(db)),
        phoneIndexSourceProvider.overrideWithValue(source),
        clockProvider.overrideWithValue(() => _now),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(
      timelineMonthProvider(const MonthKey(2025, 4)),
      (_, _) {},
    );
    addTearDown(sub.close);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sub.read().value, isEmpty);
  });

  test(
    'phone month counts: paged once, then kept current from changes',
    () async {
      final source = _Index([
        for (var i = 0; i < 1200; i++)
          _phone('p$i', null, DateTime(2024, 1, 1).add(Duration(hours: i))),
      ]);
      final container = ProviderContainer(
        overrides: [phoneIndexSourceProvider.overrideWithValue(source)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(phoneMonthCountsProvider, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.pageCalls, 3); // 1200 items, 500 a page
      expect(sub.read().value!.values.fold<int>(0, (a, b) => a + b), 1200);

      // A new item in a new month appears without another walk.
      source.emit(_phone('new', null, DateTime(2019, 7, 4)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(sub.read().value![const MonthKey(2019, 7)], 1);
      expect(source.pageCalls, 3);
    },
  );

  test('phone month counts: not paired is empty; the first scan re-walks',
      () async {
    final source = _Index([_phone('p1', null, DateTime(2024, 3, 3))])
      ..failWith = PlatformException(code: 'not_paired');
    final container = ProviderContainer(
      overrides: [phoneIndexSourceProvider.overrideWithValue(source)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(phoneMonthCountsProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sub.read().value, isEmpty);

    // Paired now: the engine's first scan reports items.
    source.failWith = null;
    source.emit(_phone('p1', null, DateTime(2024, 3, 3)));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(sub.read().value, {const MonthKey(2024, 3): 1});
  });
}
