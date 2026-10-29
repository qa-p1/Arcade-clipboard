// Sizes, counts, durations and relative times, worded the same in every app
// (STANDARD.md §8.1). Same cases as the Rust, TypeScript and QML copies:
// design/format-cases.json. Pure Dart, no Flutter import.

const List<String> _units = <String>['kB', 'MB', 'GB', 'TB', 'PB'];
const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
];

String _two(int value) => value.toString().padLeft(2, '0');

/// Decimal units, one decimal place below 100: "940 kB", "12.4 MB", "3.1 GB".
String formatSize(int bytes) {
  final b = bytes < 0 ? 0 : bytes;
  if (b < 1000) return '$b B';
  var divisor = 1.0;
  for (var i = 0; i < _units.length; i++) {
    divisor *= 1000;
    final tenths = (b * 10 / divisor + 0.5).floor();
    if (tenths < 1000) return '${tenths ~/ 10}.${tenths % 10} ${_units[i]}';
    final whole = (b / divisor + 0.5).floor();
    if (whole < 1000 || i == _units.length - 1) return '$whole ${_units[i]}';
  }
  return '$b B';
}

/// Thousands grouped with commas: "1,234,567".
String formatCount(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// How a duration reads: media positions ("1:05:09") or jobs ("2 min").
enum DurationStyle { media, job }

/// A duration in seconds; fractions are dropped.
String formatDuration(double seconds, [DurationStyle style = DurationStyle.media]) {
  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = total ~/ 3600;
  final m = total ~/ 60 % 60;
  final s = total % 60;
  if (style == DurationStyle.media) return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '$m:${_two(s)}';
  if (total < 60) return '$total s';
  if (total < 3600) return '${total ~/ 60} min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// "Just now", "5 min ago", "2 h ago", "Yesterday 14:05", "12 Oct", "12 Oct 2025".
/// Times are Unix milliseconds; [offsetMinutes] defaults to this machine's offset.
String formatRelative(int timeMs, {int? nowMs, int? offsetMinutes}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final offset = (offsetMinutes ?? DateTime.fromMillisecondsSinceEpoch(timeMs).timeZoneOffset.inMinutes) * 60000;
  final delta = now - timeMs;
  final local = timeMs + offset;
  final day = (local / 86400000).floor();
  final today = ((now + offset) / 86400000).floor();
  if (delta < 60000 && delta > -60000) return 'Just now';
  if (delta > 0 && delta < 3600000) return '${delta ~/ 60000} min ago';
  if (delta > 0 && day == today) return '${delta ~/ 3600000} h ago';
  final date = DateTime.fromMillisecondsSinceEpoch(local, isUtc: true);
  if (day == today - 1) return 'Yesterday ${_two(date.hour)}:${_two(date.minute)}';
  final label = '${date.day} ${_months[date.month - 1]}';
  final thisYear = DateTime.fromMillisecondsSinceEpoch(now + offset, isUtc: true).year;
  return date.year == thisYear ? label : '$label ${date.year}';
}
