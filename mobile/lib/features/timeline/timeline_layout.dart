import 'package:intl/intl.dart';

import 'timeline_merge.dart';
import 'timeline_model.dart';

/// A section as displayed: week sections of all months folded into one,
/// optionally restricted to items that are not on the phone.
class DisplaySection {
  const DisplaySection(this.label, this.caption, this.items);

  final String label;
  final String caption;
  final List<TimelineItem> items;
}

final _count = NumberFormat.decimalPattern('en');
final _day = DateFormat('d MMM');

/// Folds the per-month sections into the sections the grid shows.
///
/// "This week" items from different months become one section placed first.
/// With [notOnPhoneOnly], only `serverOnly` items remain, empty sections go,
/// and each caption reads "On server only · n".
List<DisplaySection> buildDisplaySections(
  List<TimelineSection> raw, {
  bool notOnPhoneOnly = false,
}) {
  List<TimelineItem> keep(List<TimelineItem> xs) => notOnPhoneOnly
      ? [
          for (final x in xs)
            if (x.presence == Presence.serverOnly) x,
        ]
      : xs;

  final out = <DisplaySection>[];
  final week = <TimelineItem>[];
  for (final s in raw) {
    if (s.isThisWeek) week.addAll(keep(s.items));
  }
  String caption(List<TimelineItem> xs, {required bool isWeek}) {
    if (notOnPhoneOnly) return 'On server only · ${_count.format(xs.length)}';
    return isWeek
        ? _day.format(xs.first.takenAt.toLocal())
        : _count.format(xs.length);
  }

  if (week.isNotEmpty) {
    week.sort(compareItems);
    out.add(DisplaySection(thisWeekLabel, caption(week, isWeek: true), week));
  }
  final months = raw.where((s) => !s.isThisWeek).toList()
    ..sort((a, b) => b.month!.compareTo(a.month!));
  for (final s in months) {
    final items = keep(s.items);
    if (items.isEmpty) continue;
    out.add(DisplaySection(s.label, caption(items, isWeek: false), items));
  }
  return out;
}

sealed class TimelineRow {
  const TimelineRow();
}

class HeaderRow extends TimelineRow {
  const HeaderRow(this.label, this.caption);
  final String label;
  final String caption;
}

class TilesRow extends TimelineRow {
  const TilesRow(this.items);
  final List<TimelineItem> items;
}

/// Flattens sections into header rows and rows of [columns] tiles, so a
/// single lazy list with fixed extents can show the whole timeline.
List<TimelineRow> layoutRows(List<DisplaySection> sections, int columns) {
  final rows = <TimelineRow>[];
  for (final s in sections) {
    rows.add(HeaderRow(s.label, s.caption));
    for (var i = 0; i < s.items.length; i += columns) {
      final end = i + columns < s.items.length ? i + columns : s.items.length;
      rows.add(TilesRow(s.items.sublist(i, end)));
    }
  }
  return rows;
}
