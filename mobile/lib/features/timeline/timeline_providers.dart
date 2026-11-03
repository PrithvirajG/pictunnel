import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_db.dart';
import '../../core/db/server_assets_dao.dart';
import '../../core/engine/engine.dart';
import 'timeline_layout.dart';
import 'timeline_merge.dart';
import 'timeline_model.dart';

/// The phone index.
///
/// Paging contract: items are ordered `takenAtMs` descending, then `localId`
/// descending. `PageRequest.afterKey` is exclusive and has the form
/// `<takenAtMs>|<localId>`; a client may synthesize `<ms>|` to seek to the
/// first item strictly older than `ms`.
abstract class PhoneIndexSource {
  Future<PhoneItemPage> page(PageRequest req);
}

/// Optional capability of a [PhoneIndexSource]: phone items whose state
/// changed (or that were discovered), used to re-merge their month and to
/// keep the per-month counts current.
abstract interface class ChangingPhoneIndex {
  Stream<PhoneItem> get changes;
}

/// The phone index backed by the [Engine] (`listPhoneItems`, `items$`).
class EnginePhoneIndexSource implements PhoneIndexSource, ChangingPhoneIndex {
  EnginePhoneIndexSource(this._engine);

  final Engine _engine;

  @override
  Future<PhoneItemPage> page(PageRequest req) => _engine.listPhoneItems(req);

  @override
  Stream<PhoneItem> get changes => _engine.items$;
}

Stream<PhoneItem> _changesOf(PhoneIndexSource source) =>
    source is ChangingPhoneIndex
    ? (source as ChangingPhoneIndex).changes
    : const Stream<PhoneItem>.empty();

const phonePageSize = 500;

/// Debounce for re-merging a month or re-emitting counts after item changes.
const phoneChangeDebounce = Duration(milliseconds: 300);

/// Whether [e] says the engine has no paired server (its index is empty).
bool isNotPaired(Object e) => e is PlatformException && e.code == 'not_paired';

/// Seek key positioned before every item taken at or after [t].
String seekKeyBefore(DateTime t) => '${t.millisecondsSinceEpoch}|';

/// Loads only the phone items taken in [month], walking pages from a seek key
/// until an older item or the end of the index is seen.
Future<List<PhoneItem>> loadPhoneMonth(
  PhoneIndexSource source,
  MonthKey month, {
  int limit = phonePageSize,
}) async {
  final out = <PhoneItem>[];
  final startMs = month.start.millisecondsSinceEpoch;
  final endMs = month.end.millisecondsSinceEpoch;
  String? after = seekKeyBefore(month.end);
  while (true) {
    final page = await source.page(PageRequest(afterKey: after, limit: limit));
    var reachedOlder = false;
    for (final p in page.items) {
      if (p.takenAtMs >= endMs) continue;
      if (p.takenAtMs < startMs) {
        reachedOlder = true;
        break;
      }
      out.add(p);
    }
    after = page.nextKey;
    if (reachedOlder || after == null || page.items.isEmpty) break;
  }
  return out;
}

/// Phone item counts per month, kept as `localId -> month` only (no items).
class PhoneMonthIndex {
  final _monthOf = <String, MonthKey>{};
  final _counts = <MonthKey, int>{};

  /// Pages the whole index once.
  Future<void> load(PhoneIndexSource source) async {
    String? after;
    do {
      final page = await source.page(
        PageRequest(afterKey: after, limit: phonePageSize),
      );
      for (final p in page.items) {
        put(p.localId, p.takenAtMs);
      }
      after = page.items.isEmpty ? null : page.nextKey;
    } while (after != null);
  }

  /// Records [localId] at [takenAtMs]; returns whether a count changed.
  bool put(String localId, int takenAtMs) {
    final month = MonthKey.ofMs(takenAtMs);
    final old = _monthOf[localId];
    if (old == month) return false;
    if (old != null) {
      final n = _counts[old]! - 1;
      if (n == 0) {
        _counts.remove(old);
      } else {
        _counts[old] = n;
      }
    }
    _monthOf[localId] = month;
    _counts[month] = (_counts[month] ?? 0) + 1;
    return true;
  }

  Map<MonthKey, int> get counts => Map.unmodifiable(_counts);
}

final serverAssetsDaoProvider = Provider<ServerAssetsDao>(
  (ref) => throw UnimplementedError('override serverAssetsDaoProvider'),
);

final phoneIndexSourceProvider = Provider<PhoneIndexSource>(
  (ref) => EnginePhoneIndexSource(ref.watch(engineProvider)),
);

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Active server assets per month (in the phone's zone), from the mirror.
final serverMonthCountsProvider =
    StreamProvider.autoDispose<Map<MonthKey, int>>(
      (ref) => ref.watch(serverAssetsDaoProvider).watchMonthCounts(),
    );

/// Phone items per month: the index is paged once (keys only) and then kept
/// current from the engine's item events (debounced).
///
/// It lives as long as the timeline does, so a timeline shown again after
/// pairing (the pair screen is outside the tabs) walks the index afresh, and
/// pull-to-refresh rebuilds it, which also catches deletions. An unpaired
/// engine has no index: `not_paired` reads as empty, and the next item event
/// (the engine's first scan after pairing) walks again.
final phoneMonthCountsProvider =
    StreamProvider.autoDispose<Map<MonthKey, int>>((ref) {
      final source = ref.watch(phoneIndexSourceProvider);
      final out = StreamController<Map<MonthKey, int>>();
      final index = PhoneMonthIndex();
      final early = <PhoneItem>[];
      var loaded = false;
      var sawNotPaired = false;
      Timer? debounce;
      void emit() {
        if (!out.isClosed) out.add(index.counts);
      }

      void later(void Function() f) {
        debounce?.cancel();
        debounce = Timer(phoneChangeDebounce, f);
      }

      final sub = _changesOf(source).listen((p) {
        if (!loaded) {
          early.add(p);
        } else if (sawNotPaired) {
          later(ref.invalidateSelf);
        } else if (index.put(p.localId, p.takenAtMs)) {
          later(emit);
        }
      }, onError: (Object e) => debugPrint('phone item events: $e'));
      ref.onDispose(() {
        debounce?.cancel();
        sub.cancel();
        out.close();
      });
      () async {
        try {
          await index.load(source);
        } catch (e, st) {
          if (!isNotPaired(e)) {
            if (!out.isClosed) out.addError(e, st);
            return;
          }
          sawNotPaired = true;
        }
        loaded = true;
        if (sawNotPaired && early.isNotEmpty) {
          later(ref.invalidateSelf);
        } else {
          for (final p in early) {
            index.put(p.localId, p.takenAtMs);
          }
        }
        early.clear();
        emit();
      }();
      return out.stream;
    });

/// One month of the timeline: how many items each side holds there.
class MonthSummary {
  const MonthSummary(this.month, {this.server = 0, this.phone = 0});
  final MonthKey month;
  final int server;
  final int phone;

  @override
  bool operator ==(Object other) =>
      other is MonthSummary &&
      other.month == month &&
      other.server == server &&
      other.phone == phone;

  @override
  int get hashCode => Object.hash(month, server, phone);

  @override
  String toString() => 'MonthSummary($month, s$server, p$phone)';
}

/// Months with content on the server or the phone, newest first, from the
/// two cheap per-month counts (no item is read). While the phone counts are
/// still being built the server months show alone (or, with none, it is
/// still loading).
final timelineMonthsProvider = Provider.autoDispose<AsyncValue<List<MonthSummary>>>((
  ref,
) {
  final server = ref.watch(serverMonthCountsProvider);
  final phone = ref.watch(phoneMonthCountsProvider);
  final s = server.value;
  if (s == null) {
    return server.hasError
        ? AsyncError(server.error!, server.stackTrace ?? StackTrace.empty)
        : const AsyncLoading();
  }
  final p = phone.value;
  if (p == null && s.isEmpty && phone.isLoading) return const AsyncLoading();
  final months = {...s.keys, ...?p?.keys}.toList()
    ..sort((a, b) => b.compareTo(a));
  return AsyncData([
    for (final m in months)
      MonthSummary(m, server: s[m] ?? 0, phone: p?[m] ?? 0),
  ]);
});

/// The merged sections for one month; reads only that month on both sides.
/// Alive only while something (a visible row, the viewer) watches it.
/// Errors are reported per emission; the month keeps following the mirror
/// and the phone's item events.
final timelineMonthProvider = StreamProvider.autoDispose
    .family<List<TimelineSection>, MonthKey>((ref, month) {
      final dao = ref.watch(serverAssetsDaoProvider);
      final source = ref.watch(phoneIndexSourceProvider);
      final now = ref.watch(clockProvider);
      final out = StreamController<List<TimelineSection>>();
      List<ServerAsset>? server;
      var generation = 0;
      Timer? debounce;

      Future<void> merge() async {
        final rows = server;
        if (rows == null) return;
        final mine = ++generation;
        try {
          List<PhoneItem> phone;
          try {
            phone = await loadPhoneMonth(source, month);
          } catch (e) {
            if (!isNotPaired(e)) rethrow;
            phone = const [];
          }
          if (mine != generation || out.isClosed) return;
          out.add(mergeMonth(rows, phone, now: now()));
        } catch (e, st) {
          if (mine == generation && !out.isClosed) out.addError(e, st);
        }
      }

      final serverSub = dao
          .watchMonth(month)
          .listen(
            (rows) {
              server = rows;
              merge();
            },
            onError: (Object e, StackTrace st) {
              if (!out.isClosed) out.addError(e, st);
            },
          );
      final phoneSub = _changesOf(source)
          .where((p) => MonthKey.ofMs(p.takenAtMs) == month)
          .listen((_) {
            debounce?.cancel();
            debounce = Timer(phoneChangeDebounce, merge);
          }, onError: (Object _) {});
      ref.onDispose(() {
        debounce?.cancel();
        serverSub.cancel();
        phoneSub.cancel();
        out.close();
      });
      return out.stream;
    });

/// Months the UI wants loaded, per owner (the timeline's visible rows, the
/// viewer's current month and its neighbours). Months outside every owner's
/// window are released and their providers dispose. Each owner is one fixed
/// key ([timelineOwner], [viewerOwner]) that replaces its own request, so
/// nothing has to be released from a widget's `dispose`.
class TimelineWindow extends Notifier<Set<MonthKey>> {
  final _byOwner = <Object, Set<MonthKey>>{};

  @override
  Set<MonthKey> build() => const {};

  void request(Object owner, Set<MonthKey> months) {
    final old = _byOwner[owner];
    if (old != null && old.length == months.length && old.containsAll(months)) {
      return;
    }
    _byOwner[owner] = Set.unmodifiable(months);
    _publish();
  }

  void release(Object owner) {
    if (_byOwner.remove(owner) != null) _publish();
  }

  void _publish() =>
      state = Set.unmodifiable({for (final s in _byOwner.values) ...s});
}

const timelineOwner = 'timeline';
const viewerOwner = 'viewer';

final timelineWindowProvider =
    NotifierProvider<TimelineWindow, Set<MonthKey>>(TimelineWindow.new);

/// The months "This week" can draw from: always loaded.
Set<MonthKey> weekMonths(DateTime now) {
  final from = MonthKey.of(now.subtract(const Duration(days: 7)));
  final to = MonthKey.of(now);
  return {from, to};
}

/// The month list plus the sections of the months loaded so far.
class TimelineData {
  const TimelineData(
    this.sections, {
    required this.loading,
    this.months = const [],
    this.loaded = const {},
  });

  /// Sections of the loaded months only.
  final List<TimelineSection> sections;

  /// A wanted month is still loading (or the phone counts are).
  final bool loading;

  /// Every month, newest first, with its counts.
  final List<MonthSummary> months;

  /// Months whose sections are in [sections].
  final Set<MonthKey> loaded;
}

/// The timeline: the full month list (cheap), and the merged sections of
/// only the months in the [timelineWindowProvider] plus this week's months.
final timelineSectionsProvider = Provider.autoDispose<AsyncValue<TimelineData>>((
  ref,
) {
  final months = ref.watch(timelineMonthsProvider);
  final list = months.value;
  if (list == null) {
    final error = months.error;
    return error != null
        ? AsyncError(error, months.stackTrace ?? StackTrace.empty)
        : const AsyncLoading();
  }
  final wanted = {
    ...weekMonths(ref.watch(clockProvider)()),
    ...ref.watch(timelineWindowProvider),
  };
  var loading = false;
  final out = <TimelineSection>[];
  final loaded = <MonthKey>{};
  for (final m in list) {
    if (!wanted.contains(m.month)) continue;
    final v = ref.watch(timelineMonthProvider(m.month)).value;
    if (v == null) {
      loading = true;
    } else {
      out.addAll(v);
      loaded.add(m.month);
    }
  }
  return AsyncData(
    TimelineData(out, loading: loading, months: list, loaded: loaded),
  );
});

/// The loaded items, flat, in the order the grid shows them.
List<TimelineItem> displayOrder(List<TimelineSection> sections) => [
  for (final s in buildDisplaySections(sections)) ...s.items,
];

/// The month before and after [month] in [months] (newest first), with it.
Set<MonthKey> neighbourMonths(List<MonthSummary> months, MonthKey month) {
  final i = months.indexWhere((m) => m.month == month);
  if (i < 0) return {month};
  return {
    for (var j = max(0, i - 1); j <= min(months.length - 1, i + 1); j++)
      months[j].month,
  };
}

/// Pull-to-refresh on the timeline: re-reads the phone index and asks the
/// engine to sync. The composition root adds the server mirror sync.
final timelineRefreshProvider = Provider<Future<void> Function()>(
  (ref) => () => refreshPhoneSide(ref),
);

/// The phone half of a refresh: rebuild the month counts, request a run.
Future<void> refreshPhoneSide(Ref ref) async {
  ref.invalidate(phoneMonthCountsProvider);
  try {
    await ref.read(engineProvider).runNow();
  } catch (e) {
    if (!isNotPaired(e)) rethrow;
  }
}
