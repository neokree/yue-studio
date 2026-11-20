import '../i18n/strings.g.dart';

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
