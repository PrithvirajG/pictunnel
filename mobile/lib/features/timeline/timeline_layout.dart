import 'package:intl/intl.dart';

import 'timeline_merge.dart';
import 'timeline_model.dart';
import 'timeline_providers.dart' show MonthSummary;

/// A section as displayed: week sections of all months folded into one,
/// optionally restricted to items that are not on the phone. A month that is
/// not loaded yet is a placeholder of [placeholder] estimated items.
class DisplaySection {
  const DisplaySection(
    this.label,
    this.caption,
    this.items, {
    this.month,
    this.placeholder = 0,
  });

  final String label;
  final String caption;
  final List<TimelineItem> items;

  /// Null for "This week".
  final MonthKey? month;

  /// Estimated item count of a month that is not loaded ([items] is empty).
  final int placeholder;

  bool get isPlaceholder => placeholder > 0;
}

final _count = NumberFormat.decimalPattern('en');
final _day = DateFormat('d MMM');
final _monthLabel = DateFormat('MMMM yyyy');

/// Folds the per-month sections into the sections the grid shows.
///
/// "This week" items from different months become one section placed first.
/// Month sections are keyed by their month, so two sections of one month
/// (say, from overlapping loads) become one, never two equal labels.
/// With [notOnPhoneOnly], only `serverOnly` items remain, empty sections go,
/// and each caption reads "On server only · n".
///
/// [months] (the full month list) adds a placeholder for every month that is
/// not in [loaded]; its size is [knownCounts] (what it held when it was last
/// loaded) or else an estimate from the month's counts.
List<DisplaySection> buildDisplaySections(
  List<TimelineSection> raw, {
  bool notOnPhoneOnly = false,
  List<MonthSummary> months = const [],
  Set<MonthKey> loaded = const {},
  Map<MonthKey, int> knownCounts = const {},
}) {
  List<TimelineItem> keep(List<TimelineItem> xs) => notOnPhoneOnly
      ? [
          for (final x in xs)
            if (x.presence == Presence.serverOnly) x,
        ]
      : xs;

  final out = <DisplaySection>[];
  final week = <TimelineItem>[];
  final byMonth = <MonthKey, List<TimelineItem>>{};
  final duplicated = <MonthKey>{};
  for (final s in raw) {
    if (s.isThisWeek) {
      week.addAll(keep(s.items));
      continue;
    }
    final m = s.month!;
    final items = keep(s.items);
    final have = byMonth[m];
    if (have == null) {
      byMonth[m] = items;
    } else {
      byMonth[m] = [...have, ...items];
      duplicated.add(m);
    }
  }
  for (final m in duplicated) {
    byMonth[m]!.sort(compareItems);
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

  final estimates = <MonthKey, int>{};
  for (final s in months) {
    if (loaded.contains(s.month) || byMonth.containsKey(s.month)) continue;
    final known = knownCounts[s.month];
    final n =
        known ?? (notOnPhoneOnly ? s.server : (s.server > s.phone ? s.server : s.phone));
    if (n > 0) estimates[s.month] = n;
  }
  final keys = {...byMonth.keys, ...estimates.keys}.toList()
    ..sort((a, b) => b.compareTo(a));
  for (final m in keys) {
    final label = _monthLabel.format(m.start);
    final items = byMonth[m];
    if (items != null) {
      if (items.isEmpty) continue;
      out.add(
        DisplaySection(label, caption(items, isWeek: false), items, month: m),
      );
    } else {
      final n = estimates[m]!;
      final known = knownCounts.containsKey(m);
      out.add(
        DisplaySection(
          label,
          !known
              ? ''
              : notOnPhoneOnly
              ? 'On server only · ${_count.format(n)}'
              : _count.format(n),
          const [],
          month: m,
          placeholder: n,
        ),
      );
    }
  }
  return out;
}

sealed class TimelineRow {
  const TimelineRow(this.month);

  /// The month this row belongs to; null for "This week".
  final MonthKey? month;
}

class HeaderRow extends TimelineRow {
  const HeaderRow(this.label, this.caption, [super.month]);
  final String label;
  final String caption;
}

class TilesRow extends TimelineRow {
  const TilesRow(this.items, [super.month]);
  final List<TimelineItem> items;
}

/// Grey tiles standing in for [count] items of a month that is loading.
class PlaceholderRow extends TimelineRow {
  const PlaceholderRow(this.count, MonthKey super.month);
  final int count;
}

/// Flattens sections into header rows and rows of [columns] tiles, so a
/// single lazy list with fixed extents can show the whole timeline.
List<TimelineRow> layoutRows(List<DisplaySection> sections, int columns) {
  final rows = <TimelineRow>[];
  for (final s in sections) {
    rows.add(HeaderRow(s.label, s.caption, s.month));
    if (s.isPlaceholder) {
      for (var i = 0; i < s.placeholder; i += columns) {
        final n = s.placeholder - i < columns ? s.placeholder - i : columns;
        rows.add(PlaceholderRow(n, s.month!));
      }
      continue;
    }
    for (var i = 0; i < s.items.length; i += columns) {
      final end = i + columns < s.items.length ? i + columns : s.items.length;
      rows.add(TilesRow(s.items.sublist(i, end), s.month));
    }
  }
  return rows;
}
