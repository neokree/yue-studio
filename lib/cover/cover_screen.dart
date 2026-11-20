import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../artwork/artwork.dart';
import '../create/seed_field.dart';
import '../generation/format.dart';
import '../i18n/strings.g.dart';
import '../library/song.dart';
import '../queue/job_queue.dart';
import '../score/score_view.dart';
import '../theme/segmented.dart';
import '../theme/tokens.dart';

/// Cover tab: a recording is transcribed to an ABC score (or the user pastes one), then re-sung in a new style.
/// Wire it as `CoverScreen(queue: s.queue, estimate: s.estimator.estimate)`.
class CoverScreen extends StatefulWidget {
  const CoverScreen({super.key, required this.queue, required this.estimate, this.picker});

  final JobQueue queue;

  /// Replaces the file dialog (tests).
  final Future<String?> Function()? picker;
  final Duration Function({required String lyrics, double? sourceSeconds})
  estimate;

  @override
  State<CoverScreen> createState() => _CoverScreenState();
}

class _CoverScreenState extends State<CoverScreen> {
  final _score = TextEditingController();
  final _title = TextEditingController();
  final _style = TextEditingController();
  final _lyrics = TextEditingController();
  final _seed = TextEditingController();

  String? _file;
  int? _bytes;
  double? _seconds;
  String _mode = 'free'; // // Free is the default, as in reference/gradio_webui_working.py
  bool _transcribing = false;
  bool _scoreFromRecording = false;
  String? _transcribeError, _problem;
  bool _queued = false;

  @override
  void dispose() {
    _score.dispose();
    _title.dispose();
    _style.dispose();
    _lyrics.dispose();
    _seed.dispose();
    super.dispose();
  }

  // ---- file

  Future<void> _pick() async {
    var path = widget.picker != null ? await widget.picker!() : Platform.environment['YUE2_STUDIO_TEST_PICK_FILE'];
    if (widget.picker == null && (path == null || path.isEmpty)) {
      final f = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: t.cover.pickDialog,
            extensions: const ['wav', 'flac', 'mp3', 'ogg'],
          ),
        ],
      );
      path = f?.path;
    }
    if (path == null || !mounted) return;
    final size = await File(path).length().catchError((_) => 0);
    if (!mounted) return;
    setState(() {
      _file = path;
      _bytes = size;
      _seconds = null;
      _transcribeError = _problem = null;
      _queued = false;
      if (_scoreFromRecording) _clearScore();
    });
    final secs = await sourceSeconds(path);
    if (mounted && _file == path) setState(() => _seconds = secs);
  }

  void _remove() => setState(() {
    _file = _bytes = _seconds = null;
    _transcribeError = null;
    if (_scoreFromRecording) _clearScore();
  });

  void _clearScore() {
    _score.clear();
    _scoreFromRecording = false;
  }

  // ---- transcribe

  Future<void> _transcribe() async {
    final path = _file;
    if (path == null) return;
    setState(() {
      _transcribing = true;
      _transcribeError = _problem = null;
    });
    try {
      final abc = await widget.queue.transcribe(path, _mode == 'close' ? 'full' : 'melody');
      if (!mounted) return;
      _score.text = abc;
      _scoreFromRecording = true;
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst(
        RegExp(r'^(Exception|StateError): '),
        '',
      );
      _transcribeError = t.cover.transcribeFailed(message: msg);
    }
    if (mounted) setState(() => _transcribing = false);
  }

  void _setMode(String mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _clearScore(); // the score belongs to the mode that produced it
      _transcribeError = null;
    });
  }

  // ---- generate

  void _generate() {
    final String? problem = _file == null
        ? t.cover.needFile
        : _score.text.trim().isEmpty
        ? t.cover.needScore
        : _style.text.trim().isEmpty
        ? t.cover.needStyle
        : _lyrics.text.trim().isEmpty
        ? t.cover.needLyrics
        : null;
    if (problem != null) {
      setState(() {
        _problem = problem;
        _queued = false;
      });
      return;
    }
    widget.queue.enqueueGenerate(
      style: _style.text.trim(),
      lyrics: _lyrics.text.trim(),
      cot: _mode == 'close' ? 'full' : 'melody',
      seed: int.tryParse(_seed.text.trim()) ?? Random().nextInt(1 << 31),
      abc: _score.text.trim(),
      title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      kind: SongKind.cover,
      sourceSeconds: _seconds,
    );
    setState(() {
      _problem = null;
      _queued = true;
    });
  }

  // ---- ui

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final small = theme.textTheme.bodySmall;
    final err = TextStyle(fontSize: TypeSize.caption, color: c.error);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: Layout.contentPadding,
        child: SizedBox(
          height: max(box.maxHeight - Layout.contentPadding.vertical, 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.cover.title, style: theme.textTheme.titleLarge),
              const SizedBox(height: Space.md),
              _FileStrip(
                path: _file,
                bytes: _bytes,
                seconds: _seconds,
                state: _transcribing
                    ? t.cover.stateWorking
                    : _score.text.trim().isEmpty
                    ? t.cover.stateIdle
                    : t.cover.stateReady,
                busy: _transcribing,
                onPick: _pick,
                onRemove: _remove,
                onTranscribe: _transcribe,
              ),
              const SizedBox(height: Space.md),
              Container(height: 1, color: c.divider), // groups the strip apart from the form
              const SizedBox(height: Space.md),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ScoreView(
                              controller: _score,
                              textKey: const Key('cover.score'),
                              title: t.cover.scoreTitle,
                              hint: t.cover.scoreHint,
                              readOnly: _transcribing,
                            ),
                          ),
                          const SizedBox(height: Space.sm),
                          Row(
                            children: [
                              IgnorePointer(
                                ignoring: _transcribing,
                                child: Opacity(
                                  opacity: _transcribing ? 0.5 : 1,
                                  child: Segmented<String>(
                                    key: const ValueKey('cover.mode'), // segment keys: cover.mode.close, cover.mode.free
                                    segments: [('close', t.cover.modeClose), ('free', t.cover.modeFree)],
                                    selected: _mode,
                                    onChanged: _setMode,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  t.cover.modeHint, // one hint covering both options
                                  style: small,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (_transcribing)
                            Padding(
                              padding: const EdgeInsets.only(top: Space.sm),
                              child: Row(
                                children: [
                                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(t.cover.transcribing, style: small)),
                                ],
                              ),
                            )
                          else if (_transcribeError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: Space.sm),
                              child: Text(_transcribeError!, style: err, key: const Key('cover.error')),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Label(t.cover.titleLabel, t.cover.titleHint),
                          TextField(
                            key: const Key('cover.title'),
                            controller: _title,
                            decoration: InputDecoration(hintText: t.cover.titlePlaceholder),
                          ),
                          const SizedBox(height: Space.md),
                          _Label(t.cover.styleTitle, t.cover.styleHint),
                          TextField(
                            key: const Key('cover.style'),
                            controller: _style,
                            minLines: 3,
                            maxLines: 4, // room for the wrapped text without it touching the bottom edge
                            decoration: InputDecoration(hintText: t.cover.stylePlaceholder),
                            onChanged: (_) => setState(() => _problem = null),
                          ),
                          const SizedBox(height: Space.md),
                          _Label(t.cover.lyricsTitle, t.cover.lyricsHint),
                          Expanded(
                            child: TextField(
                              key: const Key('cover.lyrics'),
                              controller: _lyrics,
                              expands: true,
                              maxLines: null,
                              minLines: null,
                              textAlignVertical: TextAlignVertical.top,
                              decoration: InputDecoration(hintText: t.cover.lyricsPlaceholder),
                              onChanged: (_) => setState(() => _problem = null),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.md),
              // Bottom row as in Create, minus the plan: on Cover Close / Free already fixes it.
              Row(
                children: [
                  SeedField(key: const Key('cover.seed'), controller: _seed, label: t.cover.seed, hint: t.cover.seedHint),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _problem != null
                        ? Text(_problem!, style: err, key: const Key('cover.problem'), maxLines: 1, overflow: TextOverflow.ellipsis)
                        : _queued
                        ? Text(t.cover.queued, style: small, key: const Key('cover.queued'))
                        : const SizedBox.shrink(),
                  ),
                  ListenableBuilder(
                    listenable: _lyrics,
                    builder: (_, _) => Text(
                      _seconds == null
                          ? t.cover.estimateIdle
                          : t.cover.estimate(
                              time: formatDuration(widget.estimate(lyrics: _lyrics.text, sourceSeconds: _seconds)),
                            ),
                      key: const Key('cover.estimate'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: c.textTertiary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  FilledButton(
                    key: const Key('cover.generate'),
                    onPressed: _generate,
                    child: Text(t.cover.generate),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bold label with the quiet hint beside it, one line, as in Create.
class _Label extends StatelessWidget {
  const _Label(this.title, this.hint);
  final String title, hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title, style: Theme.of(context).textTheme.labelLarge),
          TextSpan(
            text: '  $hint',
            style: TextStyle(fontSize: TypeSize.caption, color: AppColors.of(context).textTertiary),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

class _FileStrip extends StatelessWidget {
  const _FileStrip({
    required this.path,
    required this.bytes,
    required this.seconds,
    required this.state,
    required this.busy,
    required this.onPick,
    required this.onRemove,
    required this.onTranscribe,
  });

  final String? path, state;
  final int? bytes;
  final double? seconds;
  final bool busy;
  final VoidCallback onPick, onRemove, onTranscribe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final tab = const [FontFeature.tabularFigures()];
    final has = path != null;
    return Row(
      children: [
        // The file has no song yet: derive a deterministic artwork from its path, or a quiet placeholder.
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.artwork),
          child: SizedBox(
            width: 40,
            height: 40,
            child: has
                ? RepaintBoundary(
                    key: const Key('cover.artwork'),
                    child: CustomPaint(painter: ArtworkPainter(ArtworkSpec.forId(path!))),
                  )
                : DecoratedBox(
                    key: const Key('cover.artwork'),
                    decoration: BoxDecoration(
                      color: c.field,
                      border: Border.all(color: c.divider),
                      borderRadius: BorderRadius.circular(Radii.artwork),
                    ),
                    child: Icon(Icons.music_note_outlined, color: c.textTertiary, size: 20),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                has ? path!.split(Platform.pathSeparator).last : t.cover.noFile,
                key: const Key('cover.filename'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                has
                    ? t.cover.meta(size: formatBytes(bytes ?? 0), length: formatLength(seconds), state: state!)
                    : t.cover.pickHint,
                key: const Key('cover.filemeta'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontFeatures: tab),
              ),
            ],
          ),
        ),
        if (has) ...[
          OutlinedButton(
            key: const Key('cover.transcribe'),
            onPressed: busy ? null : onTranscribe,
            child: Text(t.cover.transcribe),
          ),
          const SizedBox(width: Space.sm),
          OutlinedButton(
            key: const Key('cover.pick'),
            onPressed: busy ? null : onPick,
            child: Text(t.cover.replace),
          ),
          const SizedBox(width: Space.sm),
          OutlinedButton(
            key: const Key('cover.remove'),
            onPressed: busy ? null : onRemove,
            child: Text(t.cover.remove),
          ),
        ] else
          FilledButton(key: const Key('cover.pick'), onPressed: onPick, child: Text(t.cover.pick)),
      ],
    );
  }
}

// ---- helpers (public for the unit test)

String formatBytes(int b) => b < 1024 * 1024
    ? '${(b / 1024).round()} KB'
    : '${(b / 1048576).toStringAsFixed(1)} MB';

/// m:ss, or an em dash when the length is unknown.
String formatLength(double? s) {
  if (s == null || s.isNaN || s <= 0) return '—';
  final n = s.round();
  return '${n ~/ 60}:${(n % 60).toString().padLeft(2, '0')}';
}

/// Length in seconds: parsed from the header for wav (no plugin needed), audioplayers for the rest. Null when unknown.
Future<double?> sourceSeconds(String path) async {
  if (path.toLowerCase().endsWith('.wav')) {
    final w = await _wavSeconds(path);
    if (w != null) return w;
  }
  final p = AudioPlayer();
  try {
    await p.setSourceDeviceFile(path);
    final d = await p.getDuration().timeout(const Duration(seconds: 5));
    return d == null || d == Duration.zero ? null : d.inMilliseconds / 1000;
  } catch (_) {
    return null;
  } finally {
    p.dispose().catchError((_) {});
  }
}

Future<double?> _wavSeconds(String path) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    final len = await f.length();
    final head = await f.read(12);
    if (head.length < 12 || String.fromCharCodes(head.sublist(0, 4)) != 'RIFF') {
      return null;
    }
    int? byteRate;
    var pos = 12;
    while (pos + 8 <= len) {
      await f.setPosition(pos);
      final h = await f.read(8);
      if (h.length < 8) return null;
      final id = String.fromCharCodes(h.sublist(0, 4));
      var size = ByteData.sublistView(
        Uint8List.fromList(h),
      ).getUint32(4, Endian.little);
      if (id == 'fmt ') {
        final fmt = await f.read(12);
        if (fmt.length < 12) return null;
        byteRate = ByteData.sublistView(
          Uint8List.fromList(fmt),
        ).getUint32(8, Endian.little);
      } else if (id == 'data') {
        if (byteRate == null || byteRate == 0) return null;
        if (size == 0 || pos + 8 + size > len) {
          size = len - pos - 8; // streamed or truncated header
        }
        return size / byteRate;
      }
      pos += 8 + size + (size & 1);
    }
  } catch (_) {
    return null;
  } finally {
    await f?.close();
  }
  return null;
}
