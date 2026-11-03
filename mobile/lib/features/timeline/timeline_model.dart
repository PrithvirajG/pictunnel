import '../../core/db/app_db.dart';
import '../../core/engine/pigeon.g.dart';
import '../../core/time/month_key.dart';

export '../../core/time/month_key.dart';

/// Where a timeline item exists (M§7.1).
enum Presence { both, serverOnly, phoneOnly }

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
