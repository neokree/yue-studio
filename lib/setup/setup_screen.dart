import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../brand/yue_logo.dart';
import '../i18n/strings.g.dart';
import '../theme/tokens.dart';
import 'installer.dart';
import 'manifest.dart';
import 'requirements.dart';

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

/// Setup text: no tracking (the Material body styles carry some), explicit size and weight.
TextStyle _t(double size, Color color, {FontWeight weight = FontWeight.w400, bool tabular = false}) =>
    TextStyle(fontSize: size, fontWeight: weight, color: color, letterSpacing: 0, fontFeatures: tabular ? _tabular : null);

/// Height the column can grow to (error text, preflight lines): its top is pinned so nothing above moves when it does.
const _reservedHeight = 640.0;

/// First run (DESIGN.md screen 1): no sidebar, one 520 wide column.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.installer});
  final Installer installer;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  @override
  void initState() {
    super.initState();
    // Preflight on app start, before the user can press Install.
    if (!widget.installer.complete && widget.installer.preflight == null) unawaited(widget.installer.runPreflight());
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, box) => Align(
              alignment: Alignment.topCenter,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(30, math.max(30, (box.maxHeight - _reservedHeight) / 2), 30, 48),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: ListenableBuilder(listenable: widget.installer, builder: (context, _) => _Column(installer: widget.installer)),
                ),
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
              style: TextStyle(fontSize: 8.5, color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

String _gb(double v) => '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)} GB';

String _problemText(Problem p, Hardware h) => switch (p) {
      Problem.intel => t.setup.preflight.intel,
      Problem.macos => t.setup.preflight.macos(have: h.macos ?? '', need: '${Requirements.minMacOS}'),
      Problem.memory => t.setup.preflight.memory(have: _gb(h.memoryGb ?? 0), need: _gb(Requirements.minMemoryGb.toDouble())),
      Problem.disk => t.setup.preflight.disk(have: formatBytes(h.freeDiskBytes ?? 0), need: '${Requirements.minFreeDiskGb} GB'),
    };

class _Column extends StatelessWidget {
  const _Column({required this.installer});
  final Installer installer;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final steps = installer.manifest.steps;
    final pre = installer.preflight;
    final label = installer.blocked
        ? t.setup.recheck
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
        Text(installer.complete ? t.setup.ready : t.setup.subtitle, style: _t(14, c.textSecondary)),
        if (pre != null && !installer.complete && (pre.blocks.isNotEmpty || pre.warnMemory))
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in pre.blocks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(_problemText(p, pre.hardware), key: ValueKey('setup.preflight.${p.name}'), style: _t(13, c.error, weight: FontWeight.w600)),
                  ),
                if (pre.warnMemory)
                  Text(
                    t.setup.preflight.warnMemory(have: _gb(pre.hardware.memoryGb ?? 0)),
                    key: const Key('setup.preflight.warn'),
                    style: _t(13, c.textSecondary),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 22),
        for (final s in steps) _StepRow(key: ValueKey('setup.step.${s.id}'), step: s, installer: installer),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(t.setup.totalDownload, style: _t(13, c.text, weight: FontWeight.w600)),
            Text(
              formatProgress(installer.downloadedBytes, installer.totalBytes),
              key: const Key('setup.total'),
              style: _t(13, c.text, tabular: true),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Bar(value: installer.overall, accent: c.accent, track: Theme.of(context).brightness == Brightness.dark ? const Color(0x29FFFFFF) : c.divider),
        const SizedBox(height: 16),
        if (installer.diskShort case final d?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              t.setup.noDisk(need: formatBytes(d.need), free: formatBytes(d.free)),
              key: const Key('setup.error'),
              style: _t(13, c.error),
            ),
          ),
        // Hidden while installing: the bar and the rows are the status, a disabled button is just noise.
        if (!installer.complete && !installer.running)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('setup.install'),
              onPressed: installer.install,
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0),
              ),
              child: Text(label),
            ),
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
    // Right column: the size, or "x of y" while the step reports bytes. textSecondary, not tertiary: it must stay readable (4.5:1).
    final right = switch (st.status) {
      StepStatus.running when st.doneBytes != null && st.totalBytes != null => formatProgress(st.doneBytes!, st.totalBytes!),
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
              SizedBox(width: 22, child: Align(alignment: Alignment.centerLeft, child: _Dot(status: st.status, accent: c.accent, error: c.error, idle: c.textTertiary, onAccent: c.onAccent))),
              const SizedBox(width: 10),
              Expanded(child: Text(step.label, style: _t(13, c.text, weight: running ? FontWeight.w600 : FontWeight.w400))),
              SizedBox(
                width: 112,
                child: Text(right, key: Key('setup.step.size.${step.id}'), textAlign: TextAlign.right, style: _t(12, c.textSecondary, tabular: true)),
              ),
            ],
          ),
          if (phase != null)
            Padding(padding: const EdgeInsets.only(left: 32, top: 4), child: Text(phase, key: const Key('setup.step.detail'), style: _t(12, c.textSecondary))),
          // One red headline (the dot is its ring), the cause when there is one, and the way out.
          if (failed)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.setup.stepFailed(step: step.label), key: const Key('setup.step.failed'), style: _t(12, c.error, weight: FontWeight.w600)),
                  if (st.error case final e? when e.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(e, key: const Key('setup.step.error'), maxLines: 4, overflow: TextOverflow.ellipsis, style: _t(12, c.textSecondary)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(t.setup.recovery, key: const Key('setup.step.recovery'), style: _t(12, c.textSecondary)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The one overall bar: fills from the left with the downloaded bytes, the same number the Total row shows.
class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.accent, required this.track});
  final double value;
  final Color accent, track;

  @override
  Widget build(BuildContext context) => Semantics(
        value: '${(value * 100).round()}%',
        child: ClipRRect(
          key: const Key('setup.bar'),
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(key: const Key('setup.bar.track'), color: track),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedFractionallySizedBox(
                    key: const Key('setup.bar.fill'),
                    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 450),
                    curve: const Cubic(.16, 1, .3, 1),
                    widthFactor: value.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: ColoredBox(color: accent),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// 16 px state dot: empty ring (pending), faint ring with a spinning accent arc (running), filled (done), error ring (failed).
class _Dot extends StatefulWidget {
  const _Dot({required this.status, required this.accent, required this.error, required this.idle, required this.onAccent});
  final StepStatus status;
  final Color accent, error, idle, onAccent;

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
            painter: _DotPainter(widget.status, widget.accent, widget.error, widget.idle, widget.onAccent, _spin.value),
          ),
        ),
      );
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.status, this.accent, this.error, this.idle, this.onAccent, this.turn);
  final StepStatus status;
  final Color accent, error, idle, onAccent;
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
        final w = size.width;
        canvas.drawPath(
          Path()
            ..moveTo(w * .28, w * .52)
            ..lineTo(w * .44, w * .67)
            ..lineTo(w * .73, w * .35),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true
            ..color = onAccent,
        );
      case StepStatus.failed:
        canvas.drawCircle(center, r, stroke..color = error);
      case StepStatus.running:
        // Same ring as the empty dot, so the diameter never changes; the arc rides on a faint full track.
        canvas.drawCircle(center, r, stroke..color = accent.withValues(alpha: 0.22));
        canvas.drawArc(Rect.fromCircle(center: center, radius: r), turn * 2 * math.pi - math.pi / 2, math.pi * 0.75, false, stroke..color = accent);
    }
  }

  @override
  bool shouldRepaint(_DotPainter o) => o.status != status || o.turn != turn || o.accent != accent || o.idle != idle || o.error != error || o.onAccent != onAccent;
}