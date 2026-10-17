import 'package:intl/intl.dart';

import '../../core/db/app_db.dart';
import '../../core/engine/pigeon.g.dart';
import 'timeline_model.dart';

const thisWeekLabel = 'This week';

/// Merges the server mirror with the phone index, keyed by sha256 (M§7.1).
///
/// Trashed (non-`active`) server assets are dropped. A phone item whose sha
/// matches an active server asset becomes one `both` item. Phone items
/// without a sha, or with an unknown sha, are `phoneOnly` (key
/// `local:<localId>`, or the sha when known). Within one sha at most one item
/// takes the sha as its key; any further duplicate falls back to a
/// `local:`/`server:` key so that every input appears exactly once.
List<TimelineSection> mergeMonth(
  List<ServerAsset> server,
  List<PhoneItem> phone, {
  required DateTime now,
}) {
  final items = mergeItems(server, phone);
  items.sort(compareItems);

  final weekStart = now.subtract(const Duration(days: 7));
  final sections = <TimelineSection>[];
  final week = <TimelineItem>[];
  final byMonth = <MonthKey, List<TimelineItem>>{};
  for (final it in items) {
    if (!it.takenAt.isBefore(weekStart)) {
      week.add(it);
    } else {
      byMonth.putIfAbsent(MonthKey.of(it.takenAt), () => []).add(it);
    }
  }
  if (week.isNotEmpty) {
    sections.add(TimelineSection(
        label: thisWeekLabel, isThisWeek: true, month: null, items: week));
  }
  final months = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));
  for (final m in months) {
    sections.add(TimelineSection(
      label: DateFormat('MMMM yyyy').format(m.start),
      isThisWeek: false,
      month: m,
      items: byMonth[m]!,
    ));
  }
  return sections;
}

/// `takenAt` descending, then key ascending, then presence (total order).
int compareItems(TimelineItem a, TimelineItem b) {
  final t = b.takenAt.compareTo(a.takenAt);
  if (t != 0) return t;
  final k = a.key.compareTo(b.key);
  if (k != 0) return k;
  return a.presence.index - b.presence.index;
}

List<TimelineItem> mergeItems(List<ServerAsset> server, List<PhoneItem> phone) {
  final out = <TimelineItem>[];
  final bySha = <String, ServerAsset>{};
  final sortedServer = [...server]..sort((a, b) => a.id.compareTo(b.id));
  for (final s in sortedServer) {
    if (s.state != 'active') continue;
    if (bySha.containsKey(s.sha256)) {
      out.add(_serverOnly(s, 'server:${s.id}'));
    } else {
      bySha[s.sha256] = s;
    }
  }
  final claimed = <String>{};
  // Deterministic claim order regardless of input order.
  final sortedPhone = [...phone]
    ..sort((a, b) => a.localId.compareTo(b.localId));
  for (final p in sortedPhone) {
    final sha = p.sha256;
    if (sha == null || sha.isEmpty || claimed.contains(sha)) {
      out.add(_phoneOnly(p, 'local:${p.localId}'));
      continue;
    }
    claimed.add(sha);
    final s = bySha[sha];
    out.add(s == null
        ? _phoneOnly(p, sha)
        : TimelineItem(
            key: sha,
            presence: Presence.both,
            server: s,
            phone: p,
            takenAt: _phoneTime(p),
            isVideo: s.kind == 'video' || p.mime.startsWith('video/'),
            isLive: p.isLivePhoto,
            phoneState: p.state,
          ));
  }
  for (final e in bySha.entries) {
    if (!claimed.contains(e.key)) out.add(_serverOnly(e.value, e.key));
  }
  return out;
}

DateTime _phoneTime(PhoneItem p) =>
    DateTime.fromMillisecondsSinceEpoch(p.takenAtMs, isUtc: true);

TimelineItem _phoneOnly(PhoneItem p, String key) => TimelineItem(
      key: key,
      presence: Presence.phoneOnly,
      phone: p,
      takenAt: _phoneTime(p),
      isVideo: p.mime.startsWith('video/'),
      isLive: p.isLivePhoto,
      phoneState: p.state,
    );

TimelineItem _serverOnly(ServerAsset s, String key) => TimelineItem(
      key: key,
      presence: Presence.serverOnly,
      server: s,
      takenAt: s.sortAt.toUtc(),
      isVideo: s.kind == 'video',
      isLive: false,
    );
