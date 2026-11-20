import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n/strings.g.dart';
import '../theme/tokens.dart';
import 'installer.dart';
import 'requirements.dart';
import 'setup_screen.dart';

/// Remembers "Try anyway" in the data dir, so the page is not shown again.
File ackFile(String dataDir) => File(p.join(dataDir, 'requirements-ack.json'));

/// DESIGN.md screen 0, routing: Macs under 24 GB see the requirements page first; Macs with at least 16 GB can go on to [child]
/// (setup), and that choice is remembered. Unknown memory goes straight to [child].
class RequirementsGate extends StatefulWidget {
  const RequirementsGate({super.key, required this.installer, required this.child});
  final Installer installer;
  final Widget child;

  @override
  State<RequirementsGate> createState() => _RequirementsGateState();
}

class _RequirementsGateState extends State<RequirementsGate> {
  Hardware? _hw;
  bool _through = false;

  String get _dir => widget.installer.paths.dataDir;

  @override
  void initState() {
    super.initState();
    _through = ackFile(_dir).existsSync();
    widget.installer.probe.read(_dir).then((h) {
      if (mounted) setState(() => _hw = h);
    });
  }

  void _tryAnyway() {
    try {
      ackFile(_dir)
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'acknowledged': true}));
    } on FileSystemException {
      // can't remember: the page just shows again next launch
    }
    setState(() => _through = true);
  }

  @override
  Widget build(BuildContext context) {
    final hw = _hw;
    if (hw == null) return Scaffold(backgroundColor: AppColors.of(context).background); // the probe takes milliseconds
    final tier = memoryTier(hw);
    if (tier == MemoryTier.ok || (tier == MemoryTier.tryAnyway && _through)) return widget.child;
    return RequirementsScreen(memoryGb: hw.memoryGb!, onTryAnyway: tier == MemoryTier.tryAnyway ? _tryAnyway : null);
  }
}

String _gb(double v) => '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)} GB';

/// The page itself. [onTryAnyway] null = no button (under 16 GB).
class RequirementsScreen extends StatelessWidget {
  const RequirementsScreen({super.key, required this.memoryGb, this.onTryAnyway});
  final double memoryGb;
  final VoidCallback? onTryAnyway;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final r = t.requirements;
    TextStyle style(double size, Color color, FontWeight w, {double spacing = 0, bool tabular = false}) =>
        TextStyle(fontSize: size, fontWeight: w, color: color, letterSpacing: spacing, fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null);
    return Scaffold(
      backgroundColor: c.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                YueText(key: const Key('requirements.title'), pre: r.titlePre, post: r.titlePost, size: 13, weight: FontWeight.w400, color: c.textSecondary, accent: c.accent, align: TextAlign.center),
                const SizedBox(height: 28),
                YueText(
                  key: const Key('requirements.statement'),
                  pre: r.statementPre,
                  post: r.statementPost(gb: Requirements.recommendedMemoryGb),
                  size: 26,
                  weight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: c.text,
                  accent: c.accent,
                  align: TextAlign.center,
                ),
                const SizedBox(height: 56),
                Text(r.yourMac, style: style(14, c.textSecondary, FontWeight.w400), textAlign: TextAlign.center),
                const SizedBox(height: 6),
                Text(_gb(memoryGb), key: const Key('requirements.amount'), style: style(44, c.text, FontWeight.w700, spacing: -0.5, tabular: true), textAlign: TextAlign.center),
                if (onTryAnyway != null) ...[
                  const SizedBox(height: 40),
                  FilledButton(
                    key: const Key('requirements.tryAnyway'),
                    onPressed: onTryAnyway,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.onAccent,
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0),
                    ),
                    child: Text(r.tryAnyway),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
