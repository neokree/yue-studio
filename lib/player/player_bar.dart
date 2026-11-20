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

  /// Whole seconds, rounded, so the label and the thumb describe the same moment (floor showed 0:00 at 38%).
  static String _clock(Duration d) => formatClock(Duration(seconds: (d.inMilliseconds / 1000).round()));

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final pl = widget.player;
        final song = pl.current;
        final total = pl.duration;
        final frac = _drag ?? (total.inMilliseconds == 0 ? 0.0 : (pl.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0));
        // One fraction drives both the thumb and the elapsed label.
        final shown = Duration(milliseconds: (total.inMilliseconds * frac).round());
        final timeStyle = TextStyle(fontSize: TypeSize.caption, color: song == null ? c.textTertiary : c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]);
        final sub = song == null ? '' : [shortStyle(song.request.style), if (total > Duration.zero) _clock(total)].where((e) => e.isNotEmpty).join(' · ');
        const box = BoxConstraints.tightFor(width: 36, height: 36);
        // The global iconButtonTheme ignores the disabled state, so the transport sets its own colours.
        final ink = c.text, off = c.text.withValues(alpha: .3);
        return Container(
          key: const Key('player.bar'),
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          // Persistent chrome: field tone plus the full separator line on top.
          decoration: BoxDecoration(color: c.field, border: Border(top: BorderSide(color: theme.dividerColor))),
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
                flex: 1,
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
              const SizedBox(width: 16),
              // Transport and scrubber read as one group; every button sits in the same 36 px box so the centres line up.
              IconButton(tooltip: t.player.previous, padding: EdgeInsets.zero, constraints: box, color: ink, disabledColor: off, iconSize: 22, onPressed: song == null ? null : pl.previous, icon: const Icon(Icons.skip_previous_rounded)),
              IconButton(
                key: const Key('player.toggle'),
                tooltip: pl.playing ? t.player.pause : t.player.play,
                padding: EdgeInsets.zero,
                constraints: box,
                color: ink,
                disabledColor: off,
                iconSize: 26,
                onPressed: song == null ? null : pl.toggle,
                icon: Icon(pl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              IconButton(tooltip: t.player.next, padding: EdgeInsets.zero, constraints: box, color: ink, disabledColor: off, iconSize: 22, onPressed: pl.hasNext ? pl.next : null, icon: const Icon(Icons.skip_next_rounded)),
              const SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: Row(children: [
                  SizedBox(width: 44, child: Text(song == null ? '–:––' : _clock(shown), key: const Key('player.elapsed'), maxLines: 1, softWrap: false, textAlign: TextAlign.right, style: timeStyle)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        activeTrackColor: c.accent,
                        inactiveTrackColor: c.text.withValues(alpha: .14),
                        disabledActiveTrackColor: c.text.withValues(alpha: .14),
                        disabledInactiveTrackColor: c.text.withValues(alpha: .14),
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
                  SizedBox(width: 44, child: Text(song == null ? '–:––' : _clock(total), key: const Key('player.total'), maxLines: 1, softWrap: false, style: timeStyle)),
                ]),
              ),
              IconButton(
                key: const Key('player.like'),
                tooltip: song?.liked == true ? t.player.unlike : t.player.like,
                iconSize: 20,
                color: song?.liked == true ? c.accent : c.textSecondary,
                disabledColor: off,
                onPressed: song == null ? null : () => widget.library.toggleLike(song.id),
                icon: Icon(song?.liked == true ? Icons.favorite : Icons.favorite_border),
              ),
            ],
          ),
        );
      },
    );
  }
}
