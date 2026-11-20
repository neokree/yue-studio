import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../theme/tokens.dart';
import 'installer.dart';

String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, required this.installer});
  final Installer installer;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Layout.contentMaxWidth),
          child: ListenableBuilder(
            listenable: installer,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(Space.xl),
              children: [
                Text(t.setup.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: Space.sm),
                Text(t.setup.intro, style: theme.textTheme.bodyMedium),
                const SizedBox(height: Space.lg),
                for (final step in installer.manifest.steps) _StepRow(label: step.label, state: installer.states[step.id]!),
                const SizedBox(height: Space.lg),
                if (installer.diskShort case final d?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: Text(t.setup.noDisk(need: _gb(d.need), free: _gb(d.free)), style: TextStyle(color: c.error)),
                  )
                else if (installer.manifest.bytes > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: Text(t.setup.disk(size: _gb(installer.manifest.bytes)), style: theme.textTheme.bodySmall),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    key: const Key('setup.install'),
                    onPressed: installer.running ? null : installer.install,
                    child: Text(installer.running
                        ? t.setup.installing
                        : installer.failed
                            ? t.setup.retry
                            : installer.started
                                ? t.setup.resume
                                : t.setup.install),
                  ),
                ),
                const SizedBox(height: Space.xl),
                Text(t.setup.licence, style: theme.textTheme.bodySmall),
                const SizedBox(height: Space.sm),
                Text(t.app.unofficial, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});
  final String label;
  final SetupStepState state;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final (icon, color) = switch (state.status) {
      StepStatus.pending => (Icons.circle_outlined, c.textSecondary),
      StepStatus.running => (Icons.downloading, c.accent),
      StepStatus.done => (Icons.check_circle, c.success),
      StepStatus.failed => (Icons.error, c.error),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: Space.sm),
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(switch (state.status) {
                StepStatus.pending => t.setup.step.pending,
                StepStatus.running => state.progress == null ? t.setup.step.running : '${(state.progress! * 100).round()}%',
                StepStatus.done => t.setup.step.done,
                StepStatus.failed => t.setup.step.failed,
              }, style: theme.textTheme.bodySmall),
            ],
          ),
          if (state.status == StepStatus.running) ...[
            const SizedBox(height: Space.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: LinearProgressIndicator(value: state.progress, color: c.accent, backgroundColor: c.selection),
            ),
          ],
          if (state.status == StepStatus.failed && state.error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(t.setup.failed(message: state.error!), style: theme.textTheme.bodySmall?.copyWith(color: c.error), maxLines: 6, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }
}
