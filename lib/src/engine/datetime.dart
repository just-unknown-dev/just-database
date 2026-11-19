part of 'engine.dart';

/// What a date/time function returns.
enum _DateOut { date, time, datetime, julian, unix }

const _usPerDay = 86400000000;
const _unixEpochJulian = 2440587.5;

final _dateTimeText = RegExp(
  r'^\s*(-?\d{4})-(\d{2})-(\d{2})'
  r'(?:[Tt ]+(\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?)?'
  r'\s*([Zz]|[+-]\d{2}:?\d{2})?\s*$',
);
final _timeText = RegExp(
  r'^\s*(\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?\s*([Zz]|[+-]\d{2}:?\d{2})?\s*$',
);
final _unitModifier = RegExp(
  r'^([+-]?\d+(?:\.\d*)?|[+-]?\.\d+)\s*'
  r'(day|hour|minute|second|month|year)s?$',
);
final _shiftModifier = RegExp(r'^([+-])(\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?$');

/// The moment a time value and its modifiers name, as microseconds since
/// the Unix epoch (UTC), and whether `subsec` was given. Null when the
/// value or a modifier is not understood.
(int, bool)? _moment(Engine e, Object? value, List<Object?> modifiers) {
  if (value == null) return null;
  final mods = <String>[];
  for (final m in modifiers) {
    if (m == null) return null;
    mods.add(textOf(m).trim().toLowerCase());
  }
  int? us;
  var start = 0;
  num? number;
  if (value is num) {
    number = value;
  } else if (value is String) {
    final t = value.trim().toLowerCase();
    if (t == 'now') {
      us = e._now.microsecondsSinceEpoch;
    } else {
      number = parseNumericText(value);
      if (number == null) {
        us = _parseDateText(value);
        if (us == null) return null;
      }
    }
  } else {
    return null;
  }
  if (number != null) {
    final first = mods.isEmpty ? null : mods.first;
    if (first == 'unixepoch') {
      us = (number * 1000000).round();
      start = 1;
    } else if (first == 'auto') {
      final d = number.toDouble();
      us = (d >= 0 && d < 5373484.5)
          ? ((d - _unixEpochJulian) * _usPerDay).round()
          : (d * 1000000).round();
      start = 1;
    } else {
      if (first == 'julianday') start = 1;
      us = ((number.toDouble() - _unixEpochJulian) * _usPerDay).round();
    }
  }
  var subsec = false;
  var t = us!;
  for (var i = start; i < mods.length; i++) {
    final m = mods[i];
    final unit = _unitModifier.firstMatch(m);
    if (unit != null) {
      final n = double.parse(unit[1]!);
      switch (unit[2]) {
        case 'day':
          t += (n * _usPerDay).round();
        case 'hour':
          t += (n * 3600000000).round();
        case 'minute':
          t += (n * 60000000).round();
        case 'second':
          t += (n * 1000000).round();
        case 'month':
        case 'year':
          final d = DateTime.fromMicrosecondsSinceEpoch(t, isUtc: true);
          final whole = n.truncate();
          final months = unit[2] == 'month' ? whole : whole * 12;
          final moved = DateTime.utc(
            d.year,
            d.month + months,
            d.day,
            d.hour,
            d.minute,
            d.second,
            d.millisecond,
            d.microsecond,
          );
          t = moved.microsecondsSinceEpoch;
          final frac = n - whole;
          if (frac != 0) {
            t += (frac * (unit[2] == 'month' ? 30 : 365) * _usPerDay).round();
          }
      }
      continue;
    }
    final shift = _shiftModifier.firstMatch(m);
    if (shift != null) {
      final sign = shift[1] == '-' ? -1 : 1;
      final secs = double.parse(
        '${int.parse(shift[2]!) * 3600 + int.parse(shift[3]!) * 60 + int.parse(shift[4] ?? '0')}'
        '${shift[5] ?? ''}',
      );
      t += sign * (secs * 1000000).round();
      continue;
    }
    switch (m) {
      case 'start of day':
        t -= t % _usPerDay;
      case 'start of month':
        final d = DateTime.fromMicrosecondsSinceEpoch(t, isUtc: true);
        t = DateTime.utc(d.year, d.month).microsecondsSinceEpoch;
      case 'start of year':
        final d = DateTime.fromMicrosecondsSinceEpoch(t, isUtc: true);
        t = DateTime.utc(d.year).microsecondsSinceEpoch;
      case 'localtime':
        final local = DateTime.fromMicrosecondsSinceEpoch(t);
        t += local.timeZoneOffset.inMicroseconds;
      case 'utc':
        final guess = DateTime.fromMicrosecondsSinceEpoch(t);
        t -= guess.timeZoneOffset.inMicroseconds;
      case 'subsec':
      case 'subsecond':
        subsec = true;
      default:
        if (m.startsWith('weekday ')) {
          final n = int.tryParse(m.substring(8).trim());
          if (n == null || n < 0 || n > 6) return null;
          final d = DateTime.fromMicrosecondsSinceEpoch(t, isUtc: true);
          final dow = d.weekday % 7; // Sunday = 0
          t += ((n - dow + 7) % 7) * _usPerDay;
          continue;
        }
        return null;
    }
  }
  // SQLite only handles years 0000-9999.
  final year = DateTime.fromMicrosecondsSinceEpoch(t, isUtc: true).year;
  if (year < 0 || year > 9999) return null;
  return (t, subsec);
}

int? _parseDateText(String s) {
  var m = _dateTimeText.firstMatch(s);
  int y, mo, d, h = 0, mi = 0, sec = 0, us = 0;
  String? zone;
  if (m != null) {
    y = int.parse(m[1]!);
    mo = int.parse(m[2]!);
    d = int.parse(m[3]!);
    if (m[4] != null) {
      h = int.parse(m[4]!);
      mi = int.parse(m[5]!);
      sec = int.parse(m[6] ?? '0');
      us = _fractionMicros(m[7]);
    }
    zone = m[8];
  } else {
    m = _timeText.firstMatch(s);
    if (m == null) return null;
    y = 2000;
    mo = 1;
    d = 1;
    h = int.parse(m[1]!);
    mi = int.parse(m[2]!);
    sec = int.parse(m[3] ?? '0');
    us = _fractionMicros(m[4]);
    zone = m[5];
  }
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 24 || mi > 59 || sec > 59) {
    return null;
  }
  var t = DateTime.utc(y, mo, d, h, mi, sec).microsecondsSinceEpoch + us;
  if (zone != null && zone.toUpperCase() != 'Z') {
    final sign = zone.startsWith('-') ? -1 : 1;
    final digits = zone.substring(1).replaceAll(':', '');
    final offset =
        int.parse(digits.substring(0, 2)) * 3600 +
        int.parse(digits.substring(2, 4)) * 60;
    t -= sign * offset * 1000000;
  }
  return t;
}

int _fractionMicros(String? frac) {
  if (frac == null || frac.length < 2) return 0;
  final digits = frac.substring(1).padRight(6, '0').substring(0, 6);
  return int.parse(digits);
}

String _two(int n) => n.toString().padLeft(2, '0');

String _dateText(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

String _timeTextOf(DateTime d, bool subsec) {
  final base = '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  if (!subsec) return base;
  return '$base.${d.millisecond.toString().padLeft(3, '0')}';
}

Object? _dateFunction(Engine e, List<Object?> a, _DateOut out) {
  final m = _moment(
    e,
    a.isEmpty ? 'now' : a[0],
    a.length > 1 ? a.sublist(1) : const [],
  );
  if (m == null) return null;
  final (us, subsec) = m;
  final d = DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true);
  switch (out) {
    case _DateOut.date:
      return _dateText(d);
    case _DateOut.time:
      return _timeTextOf(d, subsec);
    case _DateOut.datetime:
      return '${_dateText(d)} ${_timeTextOf(d, subsec)}';
    case _DateOut.julian:
      return us / _usPerDay + _unixEpochJulian;
    case _DateOut.unix:
      if (subsec) return (us ~/ 1000) / 1000.0;
      return (us / 1000000).floor();
  }
}

int _isoWeekYear(DateTime d) {
  final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
  return thursday.year;
}

int _isoWeek(DateTime d) {
  final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
  final firstThursday = DateTime.utc(thursday.year, 1, 4);
  final weekStart = firstThursday.subtract(
    Duration(days: (firstThursday.weekday + 6) % 7),
  );
  return thursday.difference(weekStart).inDays ~/ 7 + 1;
}

Object? _strftime(Engine e, List<Object?> a) {
  if (a[0] == null) return null;
  final fmt = textOf(a[0]!);
  final m = _moment(
    e,
    a.length > 1 ? a[1] : 'now',
    a.length > 2 ? a.sublist(2) : const [],
  );
  if (m == null) return null;
  final (us, _) = m;
  final d = DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true);
  final dayOfYear = d.difference(DateTime.utc(d.year)).inDays + 1;
  final out = StringBuffer();
  for (var i = 0; i < fmt.length; i++) {
    final c = fmt[i];
    if (c != '%' || i + 1 >= fmt.length) {
      out.write(c);
      continue;
    }
    final f = fmt[++i];
    final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    switch (f) {
      case 'd':
        out.write(_two(d.day));
      case 'e':
        out.write(d.day.toString().padLeft(2));
      case 'f':
        final s = d.second + d.millisecond / 1000;
        out.write(s.toStringAsFixed(3).padLeft(6, '0'));
      case 'F':
        out.write(_dateText(d));
      case 'G':
        out.write(_isoWeekYear(d).toString().padLeft(4, '0'));
      case 'g':
        out.write(_two(_isoWeekYear(d) % 100));
      case 'H':
        out.write(_two(d.hour));
      case 'I':
        out.write(_two(hour12));
      case 'j':
        out.write(dayOfYear.toString().padLeft(3, '0'));
      case 'J':
        out.write(formatReal(us / _usPerDay + _unixEpochJulian));
      case 'k':
        out.write(d.hour.toString().padLeft(2));
      case 'l':
        out.write(hour12.toString().padLeft(2));
      case 'm':
        out.write(_two(d.month));
      case 'M':
        out.write(_two(d.minute));
      case 'p':
        out.write(d.hour < 12 ? 'AM' : 'PM');
      case 'P':
        out.write(d.hour < 12 ? 'am' : 'pm');
      case 'R':
        out.write('${_two(d.hour)}:${_two(d.minute)}');
      case 's':
        out.write((us / 1000000).floor());
      case 'S':
        out.write(_two(d.second));
      case 'T':
        out.write(_timeTextOf(d, false));
      case 'u':
        out.write(d.weekday);
      case 'w':
        out.write(d.weekday % 7);
      case 'U':
        final sundayDow = d.weekday % 7;
        out.write(_two((dayOfYear - 1 - sundayDow + 7) ~/ 7));
      case 'W':
        final mondayDow = (d.weekday + 6) % 7;
        out.write(_two((dayOfYear - 1 - mondayDow + 7) ~/ 7));
      case 'V':
        out.write(_two(_isoWeek(d)));
      case 'Y':
        out.write(d.year.toString().padLeft(4, '0'));
      case '%':
        out.write('%');
      default:
        return null;
    }
  }
  return out.toString();
}
