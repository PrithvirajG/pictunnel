import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/server_assets_dao.dart';
import '../../core/engine/engine.dart';
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
/// changed, used to re-merge their month.
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

const phonePageSize = 500;

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

/// Months that hold phone items, found by walking the whole index once.
Future<Set<MonthKey>> loadPhoneMonths(PhoneIndexSource source) async {
  final months = <MonthKey>{};
  String? after;
  do {
    final page = await source.page(
      PageRequest(afterKey: after, limit: phonePageSize),
    );
    for (final p in page.items) {
      months.add(MonthKey.of(DateTime.fromMillisecondsSinceEpoch(p.takenAtMs)));
    }
    after = page.items.isEmpty ? null : page.nextKey;
  } while (after != null);
  return months;
}

final serverAssetsDaoProvider = Provider<ServerAssetsDao>(
  (ref) => throw UnimplementedError('override serverAssetsDaoProvider'),
);

final phoneIndexSourceProvider = Provider<PhoneIndexSource>(
  (ref) => EnginePhoneIndexSource(ref.watch(engineProvider)),
);

/// Ticks (debounced) when a phone item taken in [month] changes state.
final phoneMonthRevisionProvider = StreamProvider.family<int, MonthKey>((
  ref,
  month,
) {
  final source = ref.watch(phoneIndexSourceProvider);
  final out = StreamController<int>();
  var n = 0;
  Timer? timer;
  final sub =
      (source is ChangingPhoneIndex
              ? (source as ChangingPhoneIndex).changes
              : const Stream<PhoneItem>.empty())
          .where(
            (p) =>
                MonthKey.of(DateTime.fromMillisecondsSinceEpoch(p.takenAtMs)) ==
                month,
          )
          .listen((_) {
            timer?.cancel();
            timer = Timer(
              const Duration(milliseconds: 300),
              () => out.add(++n),
            );
          });
  ref.onDispose(() {
    timer?.cancel();
    sub.cancel();
    out.close();
  });
  return out.stream;
});

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Months with content on the server or the phone, newest first.
final timelineMonthsProvider = StreamProvider<List<MonthKey>>((ref) async* {
  final dao = ref.watch(serverAssetsDaoProvider);
  final source = ref.watch(phoneIndexSourceProvider);
  final phoneMonths = await loadPhoneMonths(source);
  await for (final counts in dao.monthsWithCounts()) {
    final all = {
      ...phoneMonths,
      for (final c in counts) MonthKey(c.year, c.month),
    }.toList()..sort((a, b) => b.compareTo(a));
    yield all;
  }
});

/// The merged sections for one month; reads only that month on both sides.
final timelineMonthProvider =
    StreamProvider.family<List<TimelineSection>, MonthKey>((ref, month) async* {
      final dao = ref.watch(serverAssetsDaoProvider);
      final source = ref.watch(phoneIndexSourceProvider);
      final now = ref.watch(clockProvider);
      ref.watch(phoneMonthRevisionProvider(month));
      await for (final server in dao.watchMonth(month.year, month.month)) {
        final phone = await loadPhoneMonth(source, month);
        yield mergeMonth(server, phone, now: now());
      }
    });

/// All loaded sections across months, plus whether more are still loading.
class TimelineData {
  const TimelineData(this.sections, {required this.loading});
  final List<TimelineSection> sections;
  final bool loading;
}

/// Every month's sections, newest first. Months that are still loading are
/// skipped (and flagged) so the screen can show what is ready.
final timelineSectionsProvider = Provider<AsyncValue<TimelineData>>((ref) {
  final months = ref.watch(timelineMonthsProvider);
  final list = months.value;
  if (list == null) {
    final error = months.error;
    return error != null
        ? AsyncError(error, months.stackTrace ?? StackTrace.empty)
        : const AsyncLoading();
  }
  var loading = false;
  final out = <TimelineSection>[];
  for (final m in list) {
    final v = ref.watch(timelineMonthProvider(m)).value;
    if (v == null) {
      loading = true;
    } else {
      out.addAll(v);
    }
  }
  return AsyncData(TimelineData(out, loading: loading));
});
