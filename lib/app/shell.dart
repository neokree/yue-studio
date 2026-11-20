import 'package:flutter/material.dart';

import '../cover/cover_screen.dart';
import '../create/create_screen.dart';
import '../i18n/strings.g.dart';
import '../library/library_screen.dart';
import '../theme/tokens.dart';
import 'services.dart';

class Shell extends StatefulWidget {
  const Shell({super.key, required this.services});
  final Services services;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = widget.services;
    final items = [
      ('nav.create', t.nav.create, Icons.edit_note),
      ('nav.cover', t.nav.cover, Icons.mic_none),
      ('nav.library', t.nav.library, Icons.library_music_outlined),
    ];
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: Layout.sidebarWidth,
            color: c.sidebar,
            padding: const EdgeInsets.all(Space.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
                  child: Text(t.app.title, style: Theme.of(context).textTheme.titleMedium),
                ),
                const SizedBox(height: Space.sm),
                for (var i = 0; i < items.length; i++)
                  InkWell(
                    key: Key(items[i].$1),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    onTap: () => setState(() => _index = i),
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
                      decoration: BoxDecoration(
                        color: i == _index ? c.selection : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: Row(
                        children: [
                          Icon(items[i].$3, size: 18, color: i == _index ? c.accent : c.textSecondary),
                          const SizedBox(width: Space.sm),
                          Text(items[i].$2, style: TextStyle(fontSize: TypeSize.body, color: c.text)),
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(Space.sm),
                  child: Text(t.app.unofficial, style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: c.divider),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                CreateScreen(library: s.library, queue: s.queue),
                const CoverScreen(),
                LibraryScreen(library: s.library, queue: s.queue),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
