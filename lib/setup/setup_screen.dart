import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../brand/yue_logo.dart';
import '../i18n/strings.g.dart';
import '../theme/tokens.dart';
import 'installer.dart';
import 'manifest.dart';

/// "507 MB", "6.8 GB" (decimal units, as the manifest and Hugging Face count them).
String formatBytes(int bytes) => bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB';

/// "3.1 of 6.8 GB": both numbers in the unit of the total.
String formatProgress(int done, int total) {
  if (total >= 1e9) return t.setup.progress(done: (done / 1e9).toStringAsFixed(1), total: formatBytes(total));
  return t.setup.progress(done: (done / 1e6).round().toString(), total: formatBytes(total));
}

const _tabular = [FontFeature.tabularFigures()];

String _phaseLabel(String? phase) => switch (phase) {
      'python' => t.setup.phase.python,
      'venv' => t.setup.phase.venv,
      'packages' => t.setup.phase.packages,
      _ => t.setup.phase.connecting,
    };

/// First run (DESIGN.md screen 1): no sidebar, one 520 wide column.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, required this.installer});
  final Installer installer;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tertiary = c.textTertiary;
    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(30, 30, 30, 48),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ListenableBuilder(listenable: installer, builder: (context, _) => _Column(installer: installer)),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Text(
              t.setup.fine,
              key: const Key('setup.fine'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 8.5, color: tertiary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Column extends StatelessWidget {
  const _Column({required this.installer});
  final Installer installer;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final steps = installer.manifest.steps;
    final label = installer.running
        ? t.setup.installing
        : installer.failed
            ? t.setup.retry
            : t.setup.install;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        YueLogo(size: 64, color: c.accent),
        const SizedBox(height: 14),
        _Title(color: c.text, accent: c.accent),
        const SizedBox(height: 6),
        Text(installer.complete ? t.setup.ready : t.setup.subtitle, style: TextStyle(fontSize: 14, color: c.textSecondary)),
        const SizedBox(height: 22),
        for (final s in steps) _StepRow(key: ValueKey('setup.step.${s.id}'), step: s, installer: installer),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(t.setup.totalDownload, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text)),
            Text(
              formatProgress(installer.downloadedBytes, installer.totalBytes),
              key: const Key('setup.total'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text, fontFeatures: _tabular),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Bar(value: installer.overall, indeterminate: installer.indeterminate, accent: c.accent, track: c.divider),
        const SizedBox(height: 20),
        if (installer.diskShort case final d?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              t.setup.noDisk(need: formatBytes(d.need), free: formatBytes(d.free)),
              key: const Key('setup.error'),
              style: TextStyle(fontSize: 13, color: c.error),
            ),
          ),
        if (!installer.complete)
          FilledButton(
            key: const Key('setup.install'),
            onPressed: installer.running ? null : installer.install,
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: c.onAccent,
              // Quiet field-coloured disabled style: textSecondary on field is above 4.5:1 in both themes.
              disabledBackgroundColor: c.field,
              disabledForegroundColor: c.textSecondary,
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            child: Text(label),
          ),
      ],
    );
  }
}

/// "Setting up YuE² Studio": the 2 is a superscript at ~62%, bold, in the accent colour.
class _Title extends StatelessWidget {
  const _Title({required this.color, required this.accent});
  final Color color, accent;

  @override
  Widget build(BuildContext context) {
    const size = 26.0;
    final base = TextStyle(fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: color);
    return Semantics(
      header: true,
      label: '${t.setup.titlePre}2${t.setup.titlePost}',
      excludeSemantics: true,
      child: Text.rich(
        key: const Key('setup.title'),
        TextSpan(style: base, children: [
          TextSpan(text: t.setup.titlePre),
          WidgetSpan(
            alignment: PlaceholderAlignment.top,
            child: Text('2', style: base.copyWith(fontSize: size * 0.62, color: accent, height: 1.0)),
          ),
          TextSpan(text: t.setup.titlePost),
        ]),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({super.key, required this.step, required this.installer});
  final SetupStep step;
  final Installer installer;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final st = installer.states[step.id]!;
    final running = st.status == StepStatus.running;
    final failed = st.status == StepStatus.failed;
    final bytes = installer.weightOf(step);
    // Right column: the size, or "x of y GB" while a download reports bytes. textSecondary, not tertiary: it must stay readable (4.5:1).
    final right = switch (st.status) {
      StepStatus.running when st.doneBytes != null && st.totalBytes != null => formatProgress(st.doneBytes!, st.totalBytes!),
      StepStatus.failed => t.setup.failed,
      _ => bytes > 0 ? formatBytes(bytes) : '',
    };
    // Human phase line under a running step (never the raw uv/pip output): not for Python, the row already says it.
    final phase = running && step.kind != 'python' && st.doneBytes == null ? _phaseLabel(st.phase) : null;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.divider))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: 22, child: Align(alignment: Alignment.centerLeft, child: _Dot(status: st.status, accent: c.accent, error: c.error, idle: c.textTertiary))),
              const SizedBox(width: 10),
              Expanded(
                child: Text(step.label, style: TextStyle(fontSize: 13, fontWeight: running ? FontWeight.w600 : FontWeight.w400, color: c.text)),
              ),
              SizedBox(
                width: 112,
                child: Text(
                  right,
                  key: Key('setup.step.size.${step.id}'),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: failed ? c.error : c.textSecondary, fontFeatures: _tabular),
                ),
              ),
            ],
          ),
          if (phase != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4),
              child: Text(phase, key: const Key('setup.step.detail'), style: TextStyle(fontSize: 12, color: c.textSecondary)),
            ),
          if (failed)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.setup.stepFailed(step: step.label), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.error)),
                  if (st.error case final e? when e.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(e, key: const Key('setup.step.error'), maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(t.setup.recovery, key: const Key('setup.step.recovery'), style: TextStyle(fontSize: 12, color: c.textSecondary)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The one overall bar. While a uv step runs (no byte counts) a soft segment sweeps over the unfilled part;
/// Reduce Motion leaves it still.
class _Bar extends StatefulWidget {
  const _Bar({required this.value, required this.indeterminate, required this.accent, required this.track});
  final double value;
  final bool indeterminate;
  final Color accent, track;

  @override
  State<_Bar> createState() => _BarState();
}

class _BarState extends State<_Bar> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Bar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final go = widget.indeterminate && !MediaQuery.disableAnimationsOf(context);
    if (go && !_sweep.isAnimating) {
      _sweep.repeat();
    } else if (!go && _sweep.isAnimating) {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              LinearProgressIndicator(key: const Key('setup.bar'), value: widget.value, minHeight: 4, color: widget.accent, backgroundColor: widget.track),
              if (widget.indeterminate)
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _sweep,
                    builder: (_, _) => CustomPaint(painter: _SweepPainter(widget.value, _sweep.value, widget.accent)),
                  ),
                ),
            ],
          ),
        ),
      );
}

class _SweepPainter extends CustomPainter {
  _SweepPainter(this.value, this.turn, this.color);
  final double value, turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final from = size.width * value;
    final seg = size.width * 0.2;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(from, 0, size.width, size.height));
    final x = from - seg + (size.width - from + seg) * Curves.easeInOut.transform(turn);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, seg, size.height), const Radius.circular(2)), Paint()..color = color.withValues(alpha: 0.55));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepPainter o) => o.value != value || o.turn != turn || o.color != color;
}

/// 16 px state dot: empty ring (pending), spinning arc (running), filled (done), error ring (failed).
class _Dot extends StatefulWidget {
  const _Dot({required this.status, required this.accent, required this.error, required this.idle});
  final StepStatus status;
  final Color accent, error, idle;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  // Reduce Motion: a static arc, no spin.
  void _sync() {
    final spin = widget.status == StepStatus.running && !MediaQuery.disableAnimationsOf(context);
    if (spin && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!spin && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: _spin,
          builder: (_, _) => CustomPaint(
            size: const Size.square(16),
            painter: _DotPainter(widget.status, widget.accent, widget.error, widget.idle, _spin.value),
          ),
        ),
      );
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.status, this.accent, this.error, this.idle, this.turn);
  final StepStatus status;
  final Color accent, error, idle;
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final r = size.width / 2 - 0.75;
    switch (status) {
      case StepStatus.pending:
        canvas.drawCircle(center, r, stroke..color = idle);
      case StepStatus.done:
        canvas.drawCircle(center, size.width / 2, Paint()..color = accent);
      case StepStatus.failed:
        canvas.drawCircle(center, r, stroke..color = error);
      case StepStatus.running:
        canvas.drawArc(Rect.fromCircle(center: center, radius: r), turn * 2 * math.pi, math.pi * 1.5, false, stroke..color = accent);
    }
  }

  @override
  bool shouldRepaint(_DotPainter o) => o.status != status || o.turn != turn || o.accent != accent || o.idle != idle || o.error != error;
}
