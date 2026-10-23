import 'package:intl/intl.dart';

final _count = NumberFormat('#,##0');

String formatCount(int n) => _count.format(n);

String _num(double v) => v.toStringAsFixed(1);

/// "3.2 MB" style size; KB below 1 MB, GB from 1 GiB.
String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${_num(bytes / (1 << 30))} GB';
  if (bytes >= 1 << 20) return '${_num(bytes / (1 << 20))} MB';
  return '${(bytes / 1024).round()} KB';
}

/// "2.0 of 3.2 MB": both numbers in the unit of the total.
String formatSentOfTotal(int sent, int total) {
  if (total >= 1 << 30) {
    return '${_num(sent / (1 << 30))} of ${_num(total / (1 << 30))} GB';
  }
  if (total >= 1 << 20) {
    return '${_num(sent / (1 << 20))} of ${_num(total / (1 << 20))} MB';
  }
  return '${(sent / 1024).round()} of ${(total / 1024).round()} KB';
}

String formatSpeed(double bytesPerSecond) =>
    '${formatBytes(bytesPerSecond.round())}/s';

/// "about 4 min"; null when the speed is unknown.
String? formatEta(int remainingBytes, double bytesPerSecond) {
  if (bytesPerSecond <= 0 || remainingBytes <= 0) return null;
  final secs = remainingBytes / bytesPerSecond;
  if (secs < 60) return 'less than a minute';
  final mins = (secs / 60).round();
  if (mins < 90) return 'about $mins min';
  final hours = (mins / 60).round();
  return 'about $hours h';
}
