import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../artwork/artwork_view.dart';
import '../i18n/strings.g.dart';
import '../player/player_bar.dart' show formatClock;
import '../player/player_controller.dart';
import '../queue/job_queue.dart';
import '../queue/stage_label.dart';
import '../score/score_view.dart';
import '../theme/segmented.dart';
import '../theme/tokens.dart';
import 'library_store.dart';
import 'song.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// Today, 14:31 / Yesterday / Tue / 2026-11-02.
String formatDate(DateTime d, [DateTime? now]) {
  final l = d.toLocal(), n = (now ?? DateTime.now()).toLocal();
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(l.year, l.month, l.day)).inDays;
  if (days == 0) return t.library.today(time: '${_two(l.hour)}:${_two(l.minute)}');
  if (days == 1) return t.library.yesterday;
  if (days > 1 && days < 7) return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][l.weekday - 1];
  return '${l.year}-${_two(l.month)}-${_two(l.day)}';
}

enum _Act { rename, reuse, export, score, delete, cancel }

// Column proportions Title 45 / Created 22 / Length 12 (flex), fixed art, like and menu cells, 20 px gutter before Created.
const _fTitle = 45, _fCreated = 22, _fLength = 12;
const _wArt = 52.0, _wGutter = 20.0, _wAction = 40.0, _wMore = 32.0;

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.library,
    required this.queue,
    required this.player,
    this.onReuse,
    this.onGoCreate,
  });
  final LibraryStore library;
  final JobQueue queue;
  final PlayerController player;

  /// Prefill Create with this song's style and lyrics and switch to it (the shell wires services.createDraft + nav).
  final void Function(Song song)? onReuse;
  final VoidCallback? onGoCreate;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String? _editing;

  LibraryStore get lib => widget.library;

  @override
  void initState() {
    super.initState();
    widget.player.attach(lib);
  }

  String _status(Song s) => switch (s.status) {
        SongStatus.queued => t.library.status.queued,
        SongStatus.generating => widget.queue.running?.id == s.id && widget.queue.stage != null
            ? '${t.library.status.generating}: ${stageLabel(widget.queue.stage!)}'
            : t.library.status.generating,
        SongStatus.done => t.library.status.done,
        SongStatus.failed => t.library.status.failed,
      };

  /// Running first, then queued in run order, then everything else newest first.
  List<Song> _rows() {
    final v = lib.visible;
    final gen = v.where((s) => s.status == SongStatus.generating);
    final queued = v.where((s) => s.status == SongStatus.queued).toList().reversed;
    final rest = v.where((s) => s.status != SongStatus.generating && s.status != SongStatus.queued);
    return [...gen, ...queued, ...rest];
  }

  List<PopupMenuEntry<_Act>> _menu(Song s) {
    final live = s.status == SongStatus.queued || s.status == SongStatus.generating;
    final done = s.status == SongStatus.done;
    return [
      PopupMenuItem(value: _Act.rename, child: Text(t.library.menu.rename)),
      PopupMenuItem(value: _Act.reuse, child: Text(t.library.menu.reuse)),
      if (done) PopupMenuItem(value: _Act.export, child: Text(t.library.menu.export)),
      if (done) PopupMenuItem(value: _Act.score, child: Text(t.library.menu.score)),
      const PopupMenuDivider(),
      if (live) PopupMenuItem(value: _Act.cancel, child: Text(t.library.menu.cancel)),
      if (!live) PopupMenuItem(value: _Act.delete, child: Text(t.library.menu.delete)),
    ];
  }

  Future<void> _act(_Act a, Song s) async {
    switch (a) {
      case _Act.rename:
        setState(() => _editing = s.id);
      case _Act.reuse:
        widget.onReuse?.call(s);
      case _Act.export:
        await _export(s);
      case _Act.score:
        await _showScore(s);
      case _Act.delete:
        await _confirmDelete(s);
      case _Act.cancel:
        widget.queue.cancel(s.id);
    }
  }

  Future<void> _export(Song s) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = s.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final loc = await getSaveLocation(suggestedName: '${name.isEmpty ? 'song' : name}${p.extension(s.audio ?? '')}');
    if (loc == null) return;
    try {
      await lib.exportAudio(s, loc.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(t.library.exportFailed(message: '$e'))));
    }
  }

  Future<void> _showScore(Song s) async {
    final f = File(p.join(lib.dirOf(s.id), 'score.abc'));
    final abc = f.existsSync() ? f.readAsStringSync() : (s.request.abc ?? '');
    final c = TextEditingController(text: abc);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 720,
          height: 520,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.title, style: Theme.of(ctx).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
                Expanded(child: abc.trim().isEmpty ? Center(child: Text(t.library.noScore)) : ScoreView(controller: c, readOnly: true)),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text(t.library.close))),
              ],
            ),
          ),
        ),
      ),
    );
    c.dispose();
  }

  Future<void> _confirmDelete(Song s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('library.delete.dialog'),
        title: Text(t.library.deleteTitle(title: s.title)),
        content: Text(t.library.deleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.library.dismiss)),
          TextButton(
            key: const Key('library.delete.confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(t.library.deleteConfirm),
          ),
        ],
      ),
    );
    if (ok == true) lib.delete(s.id);
  }

  void _contextMenu(Song s, Offset at) async {
    final a = await showMenu<_Act>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: _menu(s),
    );
    if (a != null) await _act(a, s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([lib, widget.queue, widget.player]),
      builder: (context, _) {
        final rows = _rows();
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(t.library.title, style: theme.textTheme.titleLarge?.copyWith(fontSize: 22)),
                  const Spacer(),
                  Segmented<String>(
                    key: const ValueKey('library.filter'),
                    segments: [('all', t.library.filter.all), ('liked', t.library.filter.liked)],
                    selected: lib.likedOnly ? 'liked' : 'all',
                    onChanged: (v) => lib.setLikedOnly(v == 'liked'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (lib.count > 0 && (rows.isNotEmpty || lib.likedOnly)) _Header(),
              Expanded(
                child: rows.isEmpty
                    ? _Empty(likedOnly: lib.likedOnly, onGoCreate: widget.onGoCreate, onShowAll: () => lib.setLikedOnly(false))
                    : ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final s = rows[i];
                          final current = widget.player.current?.id == s.id;
                          return _SongRow(
                            key: ValueKey('library.item.${s.id}'),
                            song: s,
                            status: _status(s),
                            isCurrent: current,
                            playing: current && widget.player.playing,
                            editing: _editing == s.id,
                            onPlay: () => current ? widget.player.toggle() : widget.player.play(s),
                            onLike: () => lib.toggleLike(s.id),
                            onRenameStart: () => setState(() => _editing = s.id),
                            onRenameDone: (title) {
                              if (title != null) lib.rename(s.id, title);
                              setState(() => _editing = null);
                            },
                            onMenu: (a) => _act(a, s),
                            menuItems: () => _menu(s),
                            onContext: (at) => _contextMenu(s, at),
                            onDelete: () => _confirmDelete(s),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: TypeSize.label, fontWeight: FontWeight.w600, color: AppColors.of(context).textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(children: [
        const SizedBox(width: _wArt),
        Expanded(flex: _fTitle, child: Text(t.library.col.title, style: style)),
        const SizedBox(width: _wGutter),
        Expanded(flex: _fCreated, child: Text(t.library.col.created, style: style)),
        Expanded(flex: _fLength, child: Padding(padding: const EdgeInsets.only(right: 8), child: Text(t.library.col.length, maxLines: 1, softWrap: false, textAlign: TextAlign.right, style: style))),
        const SizedBox(width: _wAction + _wMore),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.likedOnly, this.onGoCreate, required this.onShowAll});
  final bool likedOnly;
  final VoidCallback? onGoCreate;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(likedOnly ? Icons.favorite_border : Icons.library_music_outlined, size: 36, color: c.textSecondary),
          const SizedBox(height: 12),
          Text(likedOnly ? t.library.emptyLiked : t.library.empty, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(likedOnly ? t.library.emptyLikedHint : t.library.emptyHint, style: TextStyle(fontSize: 13, color: c.textSecondary)),
          const SizedBox(height: 16),
          if (!likedOnly)
            FilledButton(key: const Key('library.empty.create'), onPressed: onGoCreate, child: Text(t.library.goCreate))
          else
            OutlinedButton(onPressed: onShowAll, child: Text(t.library.filter.all)),
        ],
      ),
    );
  }
}

class _SongRow extends StatefulWidget {
  const _SongRow({
    super.key,
    required this.song,
    required this.status,
    required this.isCurrent,
    required this.playing,
    required this.editing,
    required this.onPlay,
    required this.onLike,
    required this.onRenameStart,
    required this.onRenameDone,
    required this.onMenu,
    required this.menuItems,
    required this.onContext,
    required this.onDelete,
  });
  final Song song;
  final String status;
  final bool isCurrent, playing, editing;
  final VoidCallback onPlay, onLike, onRenameStart, onDelete;
  final void Function(String? title) onRenameDone;
  final void Function(_Act) onMenu;
  final List<PopupMenuEntry<_Act>> Function() menuItems;
  final void Function(Offset) onContext;

  @override
  State<_SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<_SongRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.song;
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final err = theme.colorScheme.error;
    final live = s.status == SongStatus.queued || s.status == SongStatus.generating;
    final failed = s.status == SongStatus.failed;
    final done = s.status == SongStatus.done;
    final sub = failed && s.error != null
        ? s.error!
        : [if (s.kind == SongKind.cover) t.library.cover, shortStyle(s.request.style)].where((e) => e.isNotEmpty).join(' · ');
    final tab = const [FontFeature.tabularFigures()];
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (d) => widget.onContext(d.globalPosition),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: widget.isCurrent ? c.accent.withValues(alpha: .12) : Colors.transparent,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Stack(children: [
                  ArtworkView(song: s, size: 40),
                  if (done)
                    Positioned.fill(
                      child: AnimatedOpacity(
                        duration: Motion.fast,
                        opacity: _hover || widget.isCurrent ? 1 : 0,
                        child: Material(
                          color: const Color(0x73000000),
                          borderRadius: BorderRadius.circular(6),
                          child: IconButton(
                            key: const Key('library.play'),
                            padding: EdgeInsets.zero,
                            iconSize: 24,
                            color: Colors.white,
                            tooltip: widget.playing ? t.library.pause : t.library.play,
                            onPressed: widget.onPlay,
                            icon: Icon(widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: _fTitle,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.editing)
                      _RenameField(initial: s.title, onDone: widget.onRenameDone)
                    else
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: widget.onRenameStart,
                        child: Text(s.title, key: const Key('library.title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                    if (sub.isNotEmpty)
                      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: TypeSize.caption, color: failed ? err : c.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: _wGutter),
              Expanded(
                flex: _fCreated,
                child: live
                    // Running and queued: status in accent instead of a date.
                    ? Text(widget.status, key: const Key('library.status'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.accent))
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Stack(children: [
                            Text(formatDate(s.createdAt), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary, fontFeatures: tab)),
                            // ponytail: a finished row prints no status; this invisible label keeps Key('library.status') (e2e + screen readers).
                            if (done) Positioned(left: 0, top: 0, child: IgnorePointer(child: Opacity(opacity: 0, child: Text(widget.status, key: const Key('library.status'))))),
                          ]),
                          if (failed) Text(widget.status, key: const Key('library.status'), style: TextStyle(fontSize: TypeSize.caption, color: err)),
                        ],
                      ),
              ),
              Expanded(
                flex: _fLength,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(s.duration == null ? '' : formatClock(Duration(milliseconds: (s.duration! * 1000).round())), maxLines: 1, textAlign: TextAlign.right, style: TextStyle(fontSize: TypeSize.body, color: c.textSecondary, fontFeatures: tab)),
                ),
              ),
              SizedBox(
                width: _wAction,
                child: failed
                    ? IconButton(key: const Key('library.delete'), iconSize: 18, tooltip: t.library.menu.delete, color: err, onPressed: widget.onDelete, icon: const Icon(Icons.delete_outline))
                    : IconButton(
                        key: const Key('library.like'),
                        iconSize: 18,
                        tooltip: s.liked ? t.library.unlike : t.library.like,
                        color: s.liked ? c.accent : c.textSecondary,
                        onPressed: widget.onLike,
                        icon: Icon(s.liked ? Icons.favorite : Icons.favorite_border),
                      ),
              ),
              SizedBox(
                width: _wMore,
                child: PopupMenuButton<_Act>(
                  key: const Key('library.more'),
                  tooltip: t.library.menu.more,
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(Icons.more_horiz, color: c.textSecondary),
                  itemBuilder: (_) => widget.menuItems(),
                  onSelected: widget.onMenu,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline rename: Enter or losing focus commits, Esc cancels.
class _RenameField extends StatefulWidget {
  const _RenameField({required this.initial, required this.onDone});
  final String initial;
  final void Function(String? title) onDone;

  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  late final _c = TextEditingController(text: widget.initial)..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  final _focus = FocusNode();
  bool _finished = false;

  void _finish(String? title) {
    if (_finished) return;
    _finished = true;
    widget.onDone(title);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _finish(_c.text);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
            _finish(null);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SizedBox(
          height: 24,
          child: TextField(
            key: const Key('library.rename.field'),
            controller: _c,
            focusNode: _focus,
            autofocus: true,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            ),
            onSubmitted: _finish,
          ),
        ),
      );
}
