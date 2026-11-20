import '../i18n/strings.g.dart';

/// "4:20", rounded to 5 s like [formatDuration]; for the small estimate next to the Add to Queue buttons.
String formatClock(Duration d) {
  final s = ((d.inSeconds + 2) ~/ 5) * 5;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// "1 min 10 s", rounded to 5 s so the number does not jitter.
String formatDuration(Duration d) {
  var s = d.inSeconds;
  if (s < 5) return t.generation.fewSeconds;
  s = ((s + 2) ~/ 5) * 5;
  final m = s ~/ 60, r = s % 60;
  if (m == 0) return t.generation.durSec(s: s);
  if (r == 0) return t.generation.durMin(m: m);
  return t.generation.durMinSec(m: m, s: r);
}
