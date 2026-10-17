import '../../core/db/app_db.dart';
import '../../core/engine/pigeon.g.dart';

/// Where a timeline item exists (M§7.1).
enum Presence { both, serverOnly, phoneOnly }

/// A calendar month, used as the family key of the per-month providers.
class MonthKey implements Comparable<MonthKey> {
  const MonthKey(this.year, this.month);

  final int year;
  final int month;

  /// First instant of this month, local time.
  DateTime get start => DateTime(year, month);

  /// First instant of the following month, local time.
  DateTime get end => DateTime(year, month + 1);

  static MonthKey of(DateTime t) {
    final l = t.toLocal();
    return MonthKey(l.year, l.month);
  }

  @override
  int compareTo(MonthKey other) =>
      year != other.year ? year - other.year : month - other.month;

  @override
  bool operator ==(Object other) =>
      other is MonthKey && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => 'MonthKey($year-$month)';
}

class TimelineItem {
  const TimelineItem({
    required this.key,
    required this.presence,
    required this.takenAt,
    required this.isVideo,
    required this.isLive,
    this.server,
    this.phone,
    this.phoneState,
  });

  /// sha256 if known, else `local:<localId>`.
  final String key;
  final Presence presence;
  final ServerAsset? server;
  final PhoneItem? phone;
  final DateTime takenAt;
  final bool isVideo;
  final bool isLive;
  final ItemState? phoneState;

  @override
  String toString() => 'TimelineItem($key, $presence, $takenAt)';
}

class TimelineSection {
  const TimelineSection({
    required this.label,
    required this.isThisWeek,
    required this.month,
    required this.items,
  });

  /// "This week" or a "October 2026" style month label.
  final String label;
  final bool isThisWeek;

  /// Null for the "This week" section.
  final MonthKey? month;
  final List<TimelineItem> items;
}
