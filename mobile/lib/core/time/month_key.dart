/// A calendar month in the phone's time zone: the bucket the timeline groups
/// by, for server rows (`sortAt`) and phone items (`takenAtMs`) alike.
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

  static MonthKey ofMs(int ms) =>
      of(DateTime.fromMillisecondsSinceEpoch(ms));

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
