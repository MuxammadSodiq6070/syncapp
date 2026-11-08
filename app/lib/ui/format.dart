String twoDigits(int n) => n.toString().padLeft(2, '0');

String clockTime(DateTime t) => '${t.hour}:${twoDigits(t.minute)}';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// Chat list timestamp: time today, weekday this week, otherwise a date.
String shortTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  if (_sameDay(t, n)) return clockTime(t);
  final age = n.difference(t);
  if (age.inDays < 7 && !age.isNegative) return _days[t.weekday - 1];
  return '${_months[t.month - 1]} ${t.day}';
}

/// Separator inside a thread: just the time today, with the day otherwise.
String separatorTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  if (_sameDay(t, n)) return clockTime(t);
  return '${_months[t.month - 1]} ${t.day}, ${clockTime(t)}';
}

String lastSeenText(int ms, {DateTime? now}) {
  if (ms <= 0) return 'Offline';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final age = (now ?? DateTime.now()).difference(t);
  if (age.inMinutes < 1) return 'Active just now';
  if (age.inMinutes < 60) return 'Active ${age.inMinutes}m ago';
  if (age.inHours < 24) return 'Active ${age.inHours}h ago';
  return 'Active ${shortTime(t, now: now)}';
}

String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// True for a short message made only of emoji, shown large like the wave in the design.
bool isEmojiOnly(String text) {
  final t = text.trim();
  if (t.isEmpty || t.runes.length > 6) return false;
  return t.runes.every(
    (r) =>
        (r >= 0x1F000 && r <= 0x1FAFF) ||
        (r >= 0x2600 && r <= 0x27BF) ||
        r == 0x200D ||
        r == 0xFE0F ||
        r == 0x2764 ||
        (r >= 0x1F3FB && r <= 0x1F3FF),
  );
}
