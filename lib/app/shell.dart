import 'dart:io';

import 'package:flutter/material.dart';

import '../brand/nav_icons.dart';
import '../brand/yue_logo.dart';
import '../cover/cover_screen.dart';
import '../create/create_screen.dart';
import '../i18n/strings.g.dart';
import '../library/library_screen.dart';
import '../library/song.dart';
import '../player/player_bar.dart';
import '../queue/job_queue.dart';
import '../queue/stage_label.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'services.dart';
import 'window.dart';

/// Window: sidebar on the left (translucent on macOS), content on the right, player bar under the content.
class Shell extends StatelessWidget {
  const Shell({super.key, required this.services});
  final Services services;

  void _reuse(Song s) =>
      services.createDraft.prefill(style: s.request.style, lyrics: s.request.lyrics, cot: s.request.cot);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = services;
    return Scaffold(
      // With vibrancy the window itself is the blur: nothing opaque may sit behind the sidebar.
      backgroundColor: Chrome.vibrancy ? Colors.transparent : c.background,
      body: Stack(
        children: [
          Positioned.fill(child: _body(s, c)),
          // Drag / double-click zone over the title bar. Sidebar: above its 38 px inset; content: above its padding.
          const Positioned(top: 0, left: 0, width: Layout.sidebarWidth, child: TitleBarStrip(height: 38)),
          const Positioned(top: 0, left: Layout.sidebarWidth, right: 0, child: TitleBarStrip(height: Space.padV)),
        ],
      ),
    );
  }

  Widget _body(Services s, AppColors c) => Row(
        children: [
          _Sidebar(services: s),
          Expanded(
            child: ColoredBox(
              color: c.background,
              child: Column(
                children: [
                  Expanded(
                    child: _Panes(
                      nav: s.nav,
                      children: {
                        Section.create: CreateScreen(services: s),
                        Section.cover: CoverScreen(queue: s.queue, estimate: s.estimator.estimate),
                        Section.library: LibraryScreen(
                          library: s.library,
                          queue: s.queue,
                          player: s.player,
                          onReuse: _reuse,
                          onGoCreate: () {
                            s.createDraft.showForm();
                            s.nav.value = Section.create;
                          },
                        ),
                      },
                    ),
                  ),
                  PlayerBar(player: s.player, library: s.library),
                ],
              ),
            ),
          ),
        ],
      );
}

/// Keeps every screen alive (an uploaded file or a half-written score must survive a tab switch) and cross-fades
/// the active one in 450 ms with the DESIGN curve. Hidden screens are Offstage, unfocusable and have paused tickers.
class _Panes extends StatelessWidget {
  const _Panes({required this.nav, required this.children});
  final ValueNotifier<Section> nav;
  final Map<Section, Widget> children;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Section>(
    valueListenable: nav,
    builder: (context, current, _) => Stack(
      fit: StackFit.expand,
      children: [for (final e in children.entries) _Pane(active: e.key == current, child: e.value)],
    ),
  );
}

class _Pane extends StatefulWidget {
  const _Pane({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_Pane> createState() => _PaneState();
}

class _PaneState extends State<_Pane> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.screen,
    value: widget.active ? 1 : 0,
  );
  late final Animation<double> _curve = CurvedAnimation(parent: _c, curve: Motion.curve);

  @override
  void didUpdateWidget(_Pane old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    _c.duration = Motion.of(context, Motion.screen);
    widget.active ? _c.forward() : _c.value = 0; // the outgoing screen just disappears under the incoming fade
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) {
      final hidden = !widget.active && _c.isDismissed;
      return ExcludeFocus(
        excluding: hidden,
        child: TickerMode(
          enabled: !hidden,
          child: Offstage(
            offstage: hidden,
            child: IgnorePointer(
              ignoring: !widget.active,
              child: FadeTransition(
                opacity: _curve,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, .02), end: Offset.zero).animate(_curve),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.services});
  final Services services;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = services;
    // Room for the traffic lights: the content runs under the title bar on macOS (38), 28 elsewhere keeps the same rhythm.
    final top = Platform.isMacOS ? 38.0 : 28.0;
    return Container(
      width: Layout.sidebarWidth,
      padding: EdgeInsets.fromLTRB(0, top, 0, 14),
      decoration: BoxDecoration(
        color: Chrome.vibrancy ? c.sidebar : c.sidebarOpaque,
        border: Border(right: BorderSide(color: c.divider)),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([s.nav, s.library]),
        builder: (context, _) {
          final nav = s.nav.value;
          final inLibrary = nav == Section.library;
          final liked = s.library.likedOnly;
          // The nav keeps its 10 px inset; the queue block below spans the full sidebar width.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      child: Row(
                        children: [
                          const YueLogo(size: 26),
                          const SizedBox(width: 9),
                          Expanded(child: YueWordmark(fontSize: TypeSize.brand)),
                        ],
                      ),
                    ),
                    _NavItem(
                      key: const Key('nav.create'),
                      label: t.shell.nav.create,
                      glyph: NavGlyph.create,
                      selected: nav == Section.create,
                      onTap: () {
                        s.createDraft.showForm();
                        s.nav.value = Section.create;
                      },
                    ),
                    _NavItem(
                      key: const Key('nav.cover'),
                      label: t.shell.nav.cover,
                      glyph: NavGlyph.cover,
                      selected: nav == Section.cover,
                      onTap: () => s.nav.value = Section.cover,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
                      child: Text(t.shell.nav.libraryGroup, style: Theme.of(context).textTheme.labelMedium),
                    ),
                    _NavItem(
                      key: const Key('nav.library'),
                      label: t.shell.nav.allSongs,
                      glyph: NavGlyph.library,
                      count: s.library.count,
                      selected: inLibrary && !liked,
                      onTap: () {
                        s.library.setLikedOnly(false);
                        s.nav.value = Section.library;
                      },
                    ),
                    _NavItem(
                      key: const Key('nav.liked'),
                      label: t.shell.nav.liked,
                      glyph: NavGlyph.heart,
                      count: s.library.likedCount,
                      selected: inLibrary && liked,
                      onTap: () {
                        s.library.setLikedOnly(true);
                        s.nav.value = Section.library;
                      },
                    ),
                  ],
                ),
              ),
              const Spacer(),
              _QueueStatus(services: s),
            ],
          );
        },
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.label,
    required this.glyph,
    required this.selected,
    required this.onTap,
    this.count,
  });
  final String label;
  final NavGlyph glyph;
  final bool selected;
  final int? count;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.of(context, Motion.control),
            curve: Motion.curve,
            margin: const EdgeInsets.only(bottom: 1),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: widget.selected ? c.accentSoft : (_hover ? c.divider : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.artwork),
              border: _focus ? Border.fromBorderSide(focusRing(c)) : null,
            ),
            child: Row(
              children: [
                NavIcon(widget.glyph, color: c.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TypeSize.body,
                      color: c.text,
                      fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (widget.count != null)
                  Text(
                    '${widget.count}',
                    style: TextStyle(
                      fontSize: TypeSize.body,
                      color: c.textTertiary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom of the sidebar: the running song, its stage and step, how many wait, a thin progress bar.
/// While a song is generating the whole block is a button that reopens the generation page.
class _QueueStatus extends StatefulWidget {
  const _QueueStatus({required this.services});
  final Services services;

  @override
  State<_QueueStatus> createState() => _QueueStatusState();
}

class _QueueStatusState extends State<_QueueStatus> {
  bool _hover = false, _focus = false;

  void _open(Song song) {
    widget.services.createDraft.watch(song.id);
    widget.services.nav.value = Section.create;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final q = widget.services.queue;
    final small = TextStyle(
      fontSize: TypeSize.caption,
      color: c.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      key: const Key('queue.status'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.divider)),
      ),
      child: ListenableBuilder(
        listenable: q,
        builder: (context, _) {
          // A transcription has no song to show: only a running generation is clickable.
          final song = q.running;
          final content = !q.busy ? _idle(small, c) : _busy(q, small, c, context);
          final box = AnimatedContainer(
            duration: Motion.of(context, Motion.control),
            curve: Motion.curve,
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
            decoration: BoxDecoration(
              color: song != null && _hover ? c.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.artwork),
              border: song != null && _focus ? Border.fromBorderSide(focusRing(c)) : null,
            ),
            child: content,
          );
          if (song == null) return box;
          return Semantics(
            button: true,
            label: t.shell.queue.show,
            excludeSemantics: true,
            child: FocusableActionDetector(
              key: const Key('queue.open'),
              mouseCursor: SystemMouseCursors.click,
              onShowHoverHighlight: (v) => setState(() => _hover = v),
              onShowFocusHighlight: (v) => setState(() => _focus = v),
              actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _open(song))},
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _open(song), child: box),
            ),
          );
        },
      ),
    );
  }

  Widget _idle(TextStyle small, AppColors c) =>
      Text(t.shell.queue.idle, style: small.copyWith(color: c.textTertiary));

  Widget _busy(JobQueue q, TextStyle small, AppColors c, BuildContext context) {
    final stage = q.stage;
    final line = stage == null
        ? t.shell.queue.starting
        : q.stageTotal != null
        ? t.shell.queue.step(stage: stageShort(stage), done: q.stageDone, total: q.stageTotal!)
        : stageShort(stage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          q.running?.title ?? t.shell.stage.transcribe,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: TypeSize.caption, fontWeight: FontWeight.w600, color: c.text),
        ),
        Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
        if (q.queuedCount > 0) Text(t.shell.queue.queued(n: q.queuedCount), style: small),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: q.transcribing
              ? LinearProgressIndicator(minHeight: 4, color: c.accent, backgroundColor: c.divider)
              : TweenAnimationBuilder<double>(
                  tween: Tween(end: q.progress),
                  duration: Motion.of(context, Motion.screen),
                  curve: Motion.curve,
                  builder: (_, v, _) => LinearProgressIndicator(
                    value: v,
                    minHeight: 4,
                    color: c.accent,
                    backgroundColor: c.divider,
                  ),
                ),
        ),
      ],
    );
  }
}
