import 'package:flutter/material.dart';

import '../artwork/artwork_view.dart';
import '../i18n/strings.g.dart';
import '../library/library_store.dart';
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final tertiary = c.textSecondary.withValues(alpha: .85);
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final pl = widget.player;
        final song = pl.current;
        final total = pl.duration;
        final frac = _drag ?? (total.inMilliseconds == 0 ? 0.0 : (pl.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0));
        final shown = _drag == null ? pl.position : Duration(milliseconds: (total.inMilliseconds * _drag!).round());
        final timeStyle = TextStyle(fontSize: 12, color: tertiary, fontFeatures: const [FontFeature.tabularFigures()]);
        return Container(
          key: const Key('player.bar'),
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(color: theme.scaffoldBackgroundColor, border: Border(top: BorderSide(color: theme.dividerColor))),
          child: Row(
            children: [
              if (song != null)
                ArtworkView(song: song, size: 40)
              else
                Container(width: 40, height: 40, decoration: BoxDecoration(color: c.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(6))),
              const SizedBox(width: 12),
              SizedBox(
                width: 220,
                child: song == null
                    ? Text(t.player.empty, style: TextStyle(fontSize: 13, color: tertiary))
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(song.title, key: const Key('player.title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          Text(
                            [if (song.request.style.isNotEmpty) song.request.style, if (total > Duration.zero) formatClock(total)].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: tertiary),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 12),
              IconButton(tooltip: t.player.previous, iconSize: 20, onPressed: song == null ? null : pl.previous, icon: const Icon(Icons.skip_previous_rounded)),
              IconButton(
                key: const Key('player.toggle'),
                tooltip: pl.playing ? t.player.pause : t.player.play,
                iconSize: 30,
                onPressed: song == null ? null : pl.toggle,
                icon: Icon(pl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              IconButton(tooltip: t.player.next, iconSize: 20, onPressed: pl.hasNext ? pl.next : null, icon: const Icon(Icons.skip_next_rounded)),
              const SizedBox(width: 12),
              SizedBox(width: 44, child: Text(formatClock(shown), maxLines: 1, softWrap: false, textAlign: TextAlign.right, style: timeStyle)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    activeTrackColor: c.textSecondary,
                    inactiveTrackColor: theme.dividerColor,
                    thumbColor: c.text,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5, elevation: 0, pressedElevation: 0),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: frac,
                    onChanged: song == null || total == Duration.zero ? null : (v) => setState(() => _drag = v),
                    onChangeEnd: (v) {
                      setState(() => _drag = null);
                      pl.seek(Duration(milliseconds: (total.inMilliseconds * v).round()));
                    },
                  ),
                ),
              ),
              SizedBox(width: 44, child: Text(formatClock(total), maxLines: 1, softWrap: false, style: timeStyle)),
              IconButton(
                key: const Key('player.like'),
                tooltip: song?.liked == true ? t.player.unlike : t.player.like,
                iconSize: 20,
                color: song?.liked == true ? c.accent : tertiary,
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
