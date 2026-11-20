import 'package:flutter/material.dart';

import '../artwork/artwork_view.dart';
import '../i18n/strings.g.dart';
import '../library/library_store.dart';
import '../library/song.dart' show shortStyle;
import '../theme/tokens.dart';
import 'player_controller.dart';

/// m:ss (h:mm:ss from one hour).
String formatClock(Duration d) {
  final s = d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s % 3600 ~/ 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

/// Persistent player under the content (DESIGN.md): artwork, title + style/length, transport, scrubber, like.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key, required this.player, required this.library});
  final PlayerController player;
  final LibraryStore library;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  double? _drag; // fraction while scrubbing

  @override
  void initState() {
    super.initState();
    widget.player.attach(widget.library);
  }

  /// Whole seconds, rounded, so the label and the thumb describe the same moment. A clip under 10 s shows tenths
  /// instead: at whole seconds "0:01 / 0:01" sits next to a thumb at 80%.
  static String _clock(Duration d, {bool precise = false}) {
    if (!precise) return formatClock(Duration(seconds: (d.inMilliseconds / 1000).round()));
    final tenths = (d.inMilliseconds / 100).round();
    return '${formatClock(Duration(seconds: tenths ~/ 10))}.${tenths % 10}';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final pl = widget.player;
        final song = pl.current;
        final total = pl.duration;
        final frac = _drag ?? (total.inMilliseconds == 0 ? 0.0 : (pl.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0));
        // One fraction drives both the thumb and the elapsed label.
        final shown = Duration(milliseconds: (total.inMilliseconds * frac).round());
        final precise = total > Duration.zero && total < const Duration(seconds: 10);
        final timeStyle = TextStyle(fontSize: TypeSize.caption, color: song == null ? c.textTertiary : c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]);
        // Short style only (first 3 terms); the length has its own place after the scrubber.
        final sub = song == null ? '' : shortStyle(song.request.style);
        // Every transport button sits in a box of the same height so the centres line up; the play button is the heavy one.
        const box = BoxConstraints.tightFor(width: 36, height: 36);
        const playBox = BoxConstraints.tightFor(width: 44, height: 44);
        // The global iconButtonTheme ignores the disabled state, so the transport sets its own colours.
        final ink = c.text, off = c.text.withValues(alpha: .3);
        final track = c.textTertiary.withValues(alpha: .5);
        return Container(
          key: const Key('player.bar'),
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          // Persistent chrome: field tone plus a separator stronger than the hairlines (dark mode kept it invisible).
          decoration: BoxDecoration(color: c.field, border: Border(top: BorderSide(color: c.text.withValues(alpha: .18)))),
          // Left half: what is playing. Centre: transport, exactly on the bar's axis. Right half: scrubber and like.
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (song != null)
                      ArtworkView(song: song, size: 40)
                    else
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: c.divider, borderRadius: BorderRadius.circular(Radii.artwork)),
                        child: Icon(Icons.music_note_rounded, size: 20, color: c.textTertiary),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: song == null
                          ? Text(t.player.empty, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary))
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(song.title, key: const Key('player.title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600)),
                                Text(sub, key: const Key('player.subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary)),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
              // Nothing loaded: previous, next and like are hidden, play stays as a disabled anchor.
              if (song != null) IconButton(tooltip: t.player.previous, padding: EdgeInsets.zero, constraints: box, color: ink, disabledColor: off, iconSize: 20, onPressed: pl.hasPrevious ? pl.previous : null, icon: const Icon(Icons.skip_previous_rounded)),
              IconButton(
                key: const Key('player.toggle'),
                tooltip: pl.playing ? t.player.pause : t.player.play,
                padding: EdgeInsets.zero,
                constraints: playBox,
                color: ink,
                disabledColor: off,
                iconSize: 34,
                onPressed: song == null ? null : pl.toggle,
                icon: Icon(pl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              if (song != null) IconButton(tooltip: t.player.next, padding: EdgeInsets.zero, constraints: box, color: ink, disabledColor: off, iconSize: 20, onPressed: pl.hasNext ? pl.next : null, icon: const Icon(Icons.skip_next_rounded)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Row(children: [
                    SizedBox(width: precise ? 52 : 44, child: Text(song == null ? '–:––' : _clock(shown, precise: precise), key: const Key('player.elapsed'), maxLines: 1, softWrap: false, textAlign: TextAlign.right, style: timeStyle)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          activeTrackColor: c.accent,
                          inactiveTrackColor: track,
                          disabledActiveTrackColor: track,
                          disabledInactiveTrackColor: track,
                          thumbColor: c.accent,
                          disabledThumbColor: Colors.transparent,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5, disabledThumbRadius: 0, elevation: 0, pressedElevation: 0),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          key: const Key('player.scrubber'),
                          value: frac,
                          onChanged: song == null || total == Duration.zero ? null : (v) => setState(() => _drag = v),
                          onChangeEnd: (v) {
                            setState(() => _drag = null);
                            pl.seek(Duration(milliseconds: (total.inMilliseconds * v).round()));
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(width: precise ? 52 : 44, child: Text(song == null ? '–:––' : _clock(total, precise: precise), key: const Key('player.total'), maxLines: 1, softWrap: false, style: timeStyle)),
                    if (song != null)
                      // Same 20 px glyph and 36 px box as the transport, so it sits on the same line as the scrubber.
                      IconButton(
                        key: const Key('player.like'),
                        tooltip: song.liked ? t.player.unlike : t.player.like,
                        padding: EdgeInsets.zero,
                        constraints: box,
                        iconSize: 20,
                        color: song.liked ? c.accent : c.textSecondary,
                        onPressed: () => widget.library.toggleLike(song.id),
                        icon: Icon(song.liked ? Icons.favorite : Icons.favorite_border),
                      ),
                  ]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
