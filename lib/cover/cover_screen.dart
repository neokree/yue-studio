import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../theme/tokens.dart';

/// Placeholder until M3.
class CoverScreen extends StatelessWidget {
  const CoverScreen({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.cover.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Space.lg),
            Text(t.cover.soon, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
}
