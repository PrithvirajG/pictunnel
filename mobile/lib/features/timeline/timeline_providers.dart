import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/server_assets_dao.dart';
import '../../core/engine/pigeon.g.dart';
import 'timeline_merge.dart';
import 'timeline_model.dart';

/// The phone index, backed by the engine (`listPhoneItems`) in a later task.
///
/// Paging contract: items are ordered `takenAtMs` descending, then `localId`
/// descending. `PageRequest.afterKey` is exclusive and has the form
/// `<takenAtMs>|<localId>`; a client may synthesize `<ms>|` to seek to the
/// first item strictly older than `ms`.
abstract class PhoneIndexSource {
  Future<PhoneItemPage> page(PageRequest req);
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
    final page =
        await source.page(PageRequest(afterKey: after, limit: phonePageSize));
    for (final p in page.items) {
      months.add(MonthKey.of(DateTime.fromMillisecondsSinceEpoch(p.takenAtMs)));
    }
    after = page.items.isEmpty ? null : page.nextKey;
  } while (after != null);
  return months;
}

final serverAssetsDaoProvider = Provider<ServerAssetsDao>(
    (ref) => throw UnimplementedError('override serverAssetsDaoProvider'));

final phoneIndexSourceProvider = Provider<PhoneIndexSource>(
    (ref) => throw UnimplementedError('override phoneIndexSourceProvider'));

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
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    yield all;
  }
});

/// The merged sections for one month; reads only that month on both sides.
final timelineMonthProvider =
    StreamProvider.family<List<TimelineSection>, MonthKey>((ref, month) async* {
  final dao = ref.watch(serverAssetsDaoProvider);
  final source = ref.watch(phoneIndexSourceProvider);
  final now = ref.watch(clockProvider);
  await for (final server in dao.watchMonth(month.year, month.month)) {
    final phone = await loadPhoneMonth(source, month);
    yield mergeMonth(server, phone, now: now());
  }
});
