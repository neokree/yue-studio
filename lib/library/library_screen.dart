import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../queue/job_queue.dart';
import '../queue/stage_label.dart';
import '../theme/tokens.dart';
import 'library_store.dart';
import 'song.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String formatDate(DateTime d) {
  final l = d.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
}

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.library, required this.queue});
  final LibraryStore library;
  final JobQueue queue;

  String _status(Song s) {
    switch (s.status) {
      case SongStatus.queued:
        return t.library.status.queued;
      case SongStatus.generating:
        final p = queue.current == s.id ? queue.progress : null;
        return p == null ? t.library.status.generating : '${t.library.status.generating}: ${stageLabel(p.stage)}';
      case SongStatus.done:
        return t.library.status.done;
      case SongStatus.failed:
        return t.library.status.failed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([library, queue]),
      builder: (context, _) {
        final songs = library.songs;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Layout.contentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.all(Space.lg),
              children: [
                Text(t.library.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: Space.lg),
                if (songs.isEmpty) Text(t.library.empty, style: theme.textTheme.bodySmall),
                for (final s in songs)
                  Container(
                    key: ValueKey('library.item.${s.id}'),
                    margin: const EdgeInsets.only(bottom: Space.sm),
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Radii.md)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.title, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: Space.xs),
                              Text(formatDate(s.createdAt), style: theme.textTheme.bodySmall),
                              if (s.status == SongStatus.failed && s.error != null)
                                Text(s.error!, style: theme.textTheme.bodySmall?.copyWith(color: c.error), maxLines: 2, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        Text(
                          _status(s),
                          key: const Key('library.status'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: switch (s.status) {
                              SongStatus.done => c.success,
                              SongStatus.failed => c.error,
                              _ => c.textSecondary,
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
