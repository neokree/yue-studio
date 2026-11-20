import 'dart:math';

import 'package:flutter/material.dart';

import '../engine/protocol.dart';
import '../i18n/strings.g.dart';
import '../library/library_store.dart';
import '../library/song.dart';
import '../queue/job_queue.dart';
import '../queue/stage_label.dart';
import '../theme/tokens.dart';

class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key, required this.library, required this.queue});
  final LibraryStore library;
  final JobQueue queue;

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  final _style = TextEditingController();
  final _lyrics = TextEditingController();
  final _seed = TextEditingController();
  CotMode _cot = CotMode.full;
  bool _added = false;

  @override
  void dispose() {
    _style.dispose();
    _lyrics.dispose();
    _seed.dispose();
    super.dispose();
  }

  String _title() {
    for (final l in _lyrics.text.split('\n')) {
      final s = l.trim();
      if (s.isNotEmpty && !s.startsWith('[')) return s.length > 48 ? s.substring(0, 48) : s;
    }
    final s = _style.text.trim();
    return s.isEmpty ? t.create.untitled : (s.length > 48 ? s.substring(0, 48) : s);
  }

  void _generate() {
    final seed = int.tryParse(_seed.text.trim()) ?? Random().nextInt(1 << 31);
    final song = widget.library.create(
      title: _title(),
      request: SongRequest(style: _style.text.trim(), lyrics: _lyrics.text.trim(), cot: _cot, seed: seed),
    );
    widget.queue.enqueue(song);
    setState(() => _added = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Layout.contentMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(t.create.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: Space.lg),
            TextField(
              key: const Key('create.style'),
              controller: _style,
              decoration: InputDecoration(labelText: t.create.style, hintText: t.create.styleHint),
              onChanged: (_) => setState(() => _added = false),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const Key('create.lyrics'),
              controller: _lyrics,
              minLines: 8,
              maxLines: 16,
              decoration: InputDecoration(
                labelText: t.create.lyrics,
                hintText: t.create.lyricsHint,
                alignLabelWithHint: true,
              ),
              onChanged: (_) => setState(() => _added = false),
            ),
            const SizedBox(height: Space.md),
            Row(
              children: [
                Text(t.create.plan, style: theme.textTheme.bodyMedium),
                const SizedBox(width: Space.md),
                SegmentedButton<CotMode>(
                  key: const Key('create.cot'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: CotMode.full, label: Text(t.create.planFull)),
                    ButtonSegment(value: CotMode.melody, label: Text(t.create.planMelody)),
                    ButtonSegment(value: CotMode.off, label: Text(t.create.planOff)),
                  ],
                  selected: {_cot},
                  onSelectionChanged: (s) => setState(() => _cot = s.first),
                ),
                const Spacer(),
                SizedBox(
                  width: 140,
                  child: TextField(
                    key: const Key('create.seed'),
                    controller: _seed,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: t.create.seed, hintText: t.create.seedHint),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([_style, _lyrics]),
                  builder: (_, _) => FilledButton(
                    key: const Key('create.generate'),
                    onPressed: _style.text.trim().isEmpty || _lyrics.text.trim().isEmpty ? null : _generate,
                    child: Text(t.create.generate),
                  ),
                ),
                const SizedBox(width: Space.md),
                if (_added) Text(t.create.queued, style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: Space.md),
            ListenableBuilder(
              listenable: widget.queue,
              builder: (_, _) {
                final id = widget.queue.current;
                if (id == null) return const SizedBox.shrink();
                final pr = widget.queue.progress;
                final value = pr?.total != null && pr!.total! > 0 ? pr.done / pr.total! : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pr == null ? t.library.status.generating : stageLabel(pr.stage), style: theme.textTheme.bodySmall),
                    const SizedBox(height: Space.xs),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.sm),
                      child: LinearProgressIndicator(value: value, color: c.accent, backgroundColor: c.selection),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
