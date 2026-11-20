import 'package:flutter/material.dart';

import '../app/services.dart';
import '../engine/protocol.dart';
import '../generation/format.dart';
import '../generation/generation_view.dart';
import '../i18n/strings.g.dart';
import '../library/song.dart';
import '../theme/segmented.dart';
import '../theme/tokens.dart';
import 'create_draft.dart';
import 'seed_field.dart';

/// Create (design/DESIGN.md screen 2). After "Add to Queue" the whole pane shows the generation (screen 3) until the
/// job ends or the user clicks Create in the sidebar, which returns to the form to queue more.
class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key, required this.services});
  final Services services;

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  Services get services => widget.services;
  CreateDraft get _draft => services.createDraft;

  /// Bumped every time the pane flips between form and generation, so each child of the AnimatedSwitcher has a key of
  /// its own (a form, generation, form flip inside one transition used to throw "Duplicate keys").
  bool? _wasGeneration;
  int _epoch = 0;

  /// The generation replaces the form only while the watched song is still alive (queued, running or just done).
  bool _showGeneration() {
    final id = _draft.watching;
    if (id == null) return false;
    final s = services.library.byId(id);
    return s != null && s.status != SongStatus.failed;
  }

  void _finished() {
    _draft.showForm();
    // Only pull the user to the Library if they are still looking at the generation.
    if (services.nav.value == Section.create) {
      services.library.setLikedOnly(false);
      services.nav.value = Section.library;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_draft, services.library]),
    builder: (context, _) {
      final generation = _showGeneration();
      if (generation != _wasGeneration) {
        _wasGeneration = generation;
        _epoch++;
      }
      return AnimatedSwitcher(
        duration: Motion.of(context, Motion.screen),
        // The outgoing pane just disappears under the incoming fade (as the sidebar panes do), so a quick
        // form, generation, form never leaves two live forms (two Key('create.style')) in the tree.
        reverseDuration: Duration.zero,
        switchInCurve: Motion.curve,
        switchOutCurve: Motion.curve,
        child: generation
            ? GenerationView(
                key: ValueKey('generation.$_epoch'),
                queue: services.queue,
                library: services.library,
                onFinished: _finished,
              )
            : _Form(key: ValueKey('form.$_epoch'), services: services),
      );
    },
  );
}

const _value = TextStyle(fontWeight: FontWeight.w400);

class _Form extends StatelessWidget {
  const _Form({super.key, required this.services});
  final Services services;

  CreateDraft get d => services.createDraft;

  void _add() {
    final title = d.title.text.trim();
    final id = services.queue.enqueueGenerate(
      title: title.isEmpty ? null : title,
      style: d.style.text,
      lyrics: d.lyrics.text,
      cot: d.cot.name,
      seed: int.tryParse(d.seed.text.trim()),
    );
    d.watch(id);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: Layout.contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.create.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: Space.md),
          _FieldLabel(t.create.titleLabel, '', tag: t.create.optional),
          TextField(key: const Key('create.title'), controller: d.title, style: _value),
          const SizedBox(height: Space.md),
          _FieldLabel(t.create.style, t.create.styleHint),
          TextField(
            key: const Key('create.style'),
            controller: d.style,
            style: _value,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: t.create.stylePlaceholder,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          const SizedBox(height: Space.md),
          _FieldLabel(t.create.lyrics, t.create.lyricsHint),
          Expanded(
            child: TextField(
              key: const Key('create.lyrics'),
              controller: d.lyrics,
              style: _value,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                hintText: t.create.lyricsPlaceholder,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          ListenableBuilder(
            listenable: Listenable.merge([d, d.style, d.lyrics]), // d.title does not move the estimate
            builder: (context, _) {
              final estimate = services.estimator.estimate(lyrics: d.lyrics.text, plan: d.cot != CotMode.off);
              // Empty lyrics are an instrumental (the Lyrics hint says so), so only the style is required.
              final ready = d.style.text.trim().isNotEmpty;
              // Plan + seed stay tight on the left; the estimate hugs the button on the right.
              final left = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t.create.plan, style: theme.textTheme.labelLarge),
                  const SizedBox(width: 10),
                  Segmented<CotMode>(
                    key: const Key('create.cot'),
                    segments: [
                      (CotMode.full, t.create.planFull),
                      (CotMode.melody, t.create.planMelody),
                      (CotMode.off, t.create.planOff),
                    ],
                    selected: d.cot,
                    onChanged: d.setCot,
                  ),
                  const SizedBox(width: 8),
                  SeedField(key: const Key('create.seed'), controller: d.seed),
                ],
              );
              final right = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Tooltip(
                      message: t.create.estimateTip,
                      child: Text(
                        t.create.estimate(time: formatClock(estimate)),
                        key: const Key('create.estimate'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TypeSize.caption,
                          color: c.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const Key('create.generate'),
                    onPressed: ready ? _add : null,
                    child: Text(t.create.generate),
                  ),
                ],
              );
              return LayoutBuilder(
                builder: (context, box) => box.maxWidth >= 710
                    ? Row(
                        children: [
                          left,
                          const SizedBox(width: 14),
                          Expanded(
                            child: Align(alignment: Alignment.centerRight, child: right),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Align(alignment: Alignment.centerLeft, child: left),
                          const SizedBox(height: 10),
                          right,
                        ],
                      ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Bold label with the quiet hint beside it, above the field (as in the mock).
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label, this.hint, {this.tag});
  final String label, hint;
  final String? tag; // "(Optional)": same line as the label, regular weight

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: label, style: Theme.of(context).textTheme.labelLarge),
            if (tag != null)
              TextSpan(
                text: ' $tag',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: c.textSecondary, fontWeight: FontWeight.w400),
              ),
            TextSpan(
              text: '  $hint',
              style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}