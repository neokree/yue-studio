import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../artwork/artwork_view.dart';
import '../brand/yue_logo.dart';
import '../i18n/strings.g.dart';
import '../library/library_store.dart';
import '../library/song.dart';
import '../queue/job_queue.dart';
import '../theme/tokens.dart';
import 'format.dart';
import 'waveform_painter.dart';

const _ease = Cubic(.16, 1, .3, 1);
const _stages = ['abc', 'semantic', 'nar', 'vae'];

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// The whole content area while a job runs (design/DESIGN.md, "Generating").
/// Follows [JobQueue.running]; when a job ends it settles the ring, shows the artwork, then calls [onFinished]
/// (the shell switches to the Library). A job that starts meanwhile is followed instead.
class GenerationView extends StatefulWidget {
  const GenerationView({super.key, required this.queue, required this.library, this.onFinished});

  final JobQueue queue;
  final LibraryStore library;
  final VoidCallback? onFinished;

  @override
  State<GenerationView> createState() => _GenerationViewState();
}

class _GenerationViewState extends State<GenerationView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _frame = WaveFrame();
  Duration _last = Duration.zero;
  String? _shown; // id of the job on screen
  Song? _song;
  bool _finished = false, _success = false, _reduce = false;
  double _target = 0;
  Timer? _handoff;

  JobQueue get _q => widget.queue;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _q.addListener(_onQueue);
    _onQueue();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = MediaQuery.disableAnimationsOf(context);
    if (r != _reduce) {
      _reduce = r;
      _frame.time = 0;
      _sync();
    }
  }

  @override
  void dispose() {
    _q.removeListener(_onQueue);
    _handoff?.cancel();
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _onQueue() {
    final r = _q.running;
    if (r != null) {
      if (r.id != _shown) {
        _shown = r.id;
        _finished = false;
        _handoff?.cancel();
        _frame
          ..progress = 0
          ..settle = 0;
      }
      _song = r;
      _target = _q.progress.clamp(0.0, 1.0);
    } else if (_shown != null && !_finished) {
      _finished = true;
      _song = widget.library.byId(_shown!) ?? _song;
      _success = _song?.status == SongStatus.done;
      _target = _success ? 1 : _target;
      _handoff = Timer(_success ? const Duration(milliseconds: 2200) : const Duration(milliseconds: 400), () => widget.onFinished?.call());
    }
    if (mounted) setState(() {});
    _sync();
  }

  void _tick(Duration elapsed) {
    final dt = math.min(0.1, (elapsed - _last).inMicroseconds / 1e6);
    _last = elapsed;
    _frame.time += dt;
    // Ease toward the real progress; never backwards.
    _frame.progress = math.max(_frame.progress, _frame.progress + (_target - _frame.progress) * (1 - math.exp(-dt * 4)));
    if (_target - _frame.progress < 0.0005) _frame.progress = _target;
    if (_finished && _success) _frame.settle = math.min(1, _frame.settle + dt / 0.8);
    _frame.bump();
    if (!_wantsTicks) _ticker.stop();
  }

  bool get _wantsTicks =>
      _shown != null && !(_finished && (!_success || _frame.settle >= 1) && _frame.progress >= _target);

  void _sync() {
    if (_reduce) {
      _frame.progress = _target;
      _frame.settle = _finished && _success ? 1 : 0;
      _frame.bump();
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (_wantsTicks && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  int get _stageIndex => _finished && _success ? _stages.length : _stages.indexOf(_q.stage ?? '');

  /// Whole percent of the current token stage against the estimate; never 100 until the stage is over.
  int _pct(String stage) {
    final f = _q.estimator.stageFractionFor(
        stage: stage, done: _q.stageDone, total: _q.stageTotal, lyrics: _song?.request.lyrics ?? '');
    return (f * 100).floor().clamp(0, 99);
  }

  /// The one status line: `Rendering sound, step 15 of 32` or `Composing melody, 38%`, then `· about 2 min left`.
  String _status(Duration? remaining) {
    if (_finished) return _success ? t.generation.done : '';
    final s = _stageText();
    if (remaining == null) return s;
    return remaining.inSeconds < 5 ? t.generation.timeLeftFew(status: s) : t.generation.timeLeft(status: s, time: formatDuration(remaining));
  }

  String _stageText() {
    final done = _q.stageDone, total = _q.stageTotal;
    return switch (_q.stage) {
      'load' => t.generation.loading,
      'abc' => t.generation.planning(pct: _pct('abc')),
      'semantic' => t.generation.composing(pct: _pct('semantic')),
      'nar' when total != null => t.generation.rendering(done: done, total: total),
      'vae' when total != null && total > 0 => t.generation.mastering(done: done, total: total),
      'vae' => t.generation.masteringNoStep,
      _ => t.generation.starting,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    if (_shown == null) {
      return Center(key: const Key('generation.view'), child: Text(t.generation.idle, style: TextStyle(color: c.textSecondary)));
    }
    final labels = [t.generation.stageScore, t.generation.stageMelody, t.generation.stageSound, t.generation.stageMaster];
    final cur = _stageIndex;
    const tab = [FontFeature.tabularFigures()];
    // Tertiary is 4.45:1 on the light window (DESIGN token), just under 4.5: fall back to secondary there.
    final upcoming = _contrast(c.textTertiary, c.background) >= 4.5 ? c.textTertiary : c.textSecondary;
    final remaining = _finished ? null : _q.remaining;
    final song = _song;
    return Center(
      key: const Key('generation.view'),
      child: LayoutBuilder(builder: (context, box) {
        // 280-320 px at a 1280x720 window; below that the ring gives way to the text under it.
        final side = box.maxHeight.isFinite ? (box.maxHeight - 200).clamp(120.0, 320.0) : 320.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: side,
              height: side,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ExcludeSemantics(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        size: Size.square(side),
                        painter: WaveformPainter(_frame, accent: c.accent, idle: c.textTertiary, pulse: !_reduce),
                      ),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: _finished && _success ? 0 : 1,
                    duration: const Duration(milliseconds: 450),
                    curve: _ease,
                    child: YueLogo(size: side * 0.27, color: c.accent),
                  ),
                  if (song != null)
                    AnimatedOpacity(
                      opacity: _finished && _success ? 1 : 0,
                      duration: const Duration(milliseconds: 450),
                      curve: _ease,
                      child: ArtworkView(song: song, size: side * 0.27),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Text(song?.title ?? '', style: theme.textTheme.titleMedium?.copyWith(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 18),
            // done: secondary + check; current: bold; upcoming: tertiary (secondary where tertiary is under 4.5:1).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < labels.length; i++) ...[
                  if (i > 0) const SizedBox(width: 22),
                  Semantics(
                    label: i < cur ? t.generation.stageDoneLabel(stage: labels[i]) : labels[i],
                    excludeSemantics: true,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(width: 15, child: i < cur ? Icon(Icons.check_rounded, size: 12, color: c.textSecondary) : null),
                      Text(
                        labels[i],
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: i == cur ? FontWeight.w700 : FontWeight.w400,
                          color: i == cur ? c.text : (i < cur ? c.textSecondary : upcoming),
                        ),
                      ),
                    ]),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            Text(_status(remaining), style: TextStyle(fontSize: 13, color: c.textSecondary, fontFeatures: tab)),
            const SizedBox(height: 16),
            OutlinedButton(
              key: const Key('generation.cancel'),
              onPressed: _finished ? null : () => _q.cancel(_shown!),
              child: Text(t.generation.cancel),
            ),
          ],
        );
      }),
    );
  }
}
