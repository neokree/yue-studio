import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../i18n/strings.g.dart';
import '../theme/segmented.dart';
import '../theme/tokens.dart';
import 'notation_html.dart';

/// ABC score with a Notation / Text switch. Notation is an abcjs WebView on macOS; anywhere a
/// WebView plugin is not registered (flutter test, Linux) it falls back to the text editor.
class ScoreView extends StatefulWidget {
  const ScoreView({
    super.key,
    required this.controller,
    this.readOnly = false,
    this.textKey,
    this.title,
    this.hint,
  });

  final TextEditingController controller;
  final bool readOnly;

  /// Key for the text editor (Cover passes Key('cover.score')).
  final Key? textKey;

  /// Optional label shown on the left of the Notation / Text switch.
  final String? title, hint;

  @override
  State<ScoreView> createState() => _ScoreViewState();
}

class _ScoreViewState extends State<ScoreView> {
  static const _mono = TextStyle(
    fontFamily: 'SF Mono',
    fontFamilyFallback: ['Menlo', 'Monaco', 'monospace'],
    fontSize: 12,
    height: 1.4,
  );

  final _focus = FocusNode();
  WebViewController? _web;
  Timer? _debounce;
  bool _pageReady = false, _notation = false;
  String _last = '';
  Color? _htmlColor;

  bool get _hasWeb => _web != null;

  @override
  void initState() {
    super.initState();
    _last = widget.controller.text;
    widget.controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Platform.isMacOS) return;
    final color = _textColor(context);
    if (_htmlColor == color) return;
    _htmlColor =
        color; // first build, or the theme flipped (light / dark): (re)load the page with the new colour
    _startWeb(color, AppColors.of(context).field);
  }

  @override
  void didUpdateWidget(ScoreView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  Color _textColor(BuildContext c) => AppColors.of(c).text;

  String _hex(Color c) {
    String h(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${h(c.r)}${h(c.g)}${h(c.b)}';
  }

  Future<void> _startWeb(Color color, Color field) async {
    final bg = _hex(field);
    WebViewController ctl;
    try {
      ctl =
          WebViewController(); // asserts when no platform implementation is registered (tests)
    } catch (_) {
      return;
    }
    _pageReady = false;
    try {
      await ctl.setJavaScriptMode(JavaScriptMode.unrestricted);
      try {
        await ctl.setBackgroundColor(
          const Color(0x00000000),
        ); // not supported everywhere; the page is transparent anyway
      } catch (_) {}
      await ctl.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageReady = true;
            _push();
          },
        ),
      );
      final js = await rootBundle.loadString('assets/abcjs/abcjs-basic-min.js');
      await ctl.loadHtmlString(
        notationHtml(
          abcjs: js,
          textColor: _hex(color),
          background: bg,
          abc: widget.controller.text,
        ),
      );
    } catch (_) {
      return; // stay on the text view
    }
    if (!mounted) return;
    setState(() {
      _web = ctl;
      if (widget.controller.text.trim().isNotEmpty && !_focus.hasFocus) {
        _notation = true;
      }
    });
  }

  void _push() {
    final w = _web;
    if (w == null || !_pageReady) return;
    w
        .runJavaScript('render(${jsonEncode(widget.controller.text)})')
        .catchError((_) {});
  }

  void _changed() {
    final text = widget.controller.text;
    if (text == _last) return;
    final wasEmpty = _last.trim().isEmpty;
    _last = text;
    // A score that arrives while the editor is not being typed in (a transcription) shows as notation.
    if (_hasWeb &&
        wasEmpty &&
        text.trim().isNotEmpty &&
        !_focus.hasFocus &&
        !_notation &&
        mounted) {
      setState(() => _notation = true);
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _push);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final fill = c.field;
    final line = c.divider;
    final showNotation = _notation && _hasWeb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (widget.title != null)
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: widget.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (widget.hint != null)
                        TextSpan(
                          text: '  ${widget.hint}',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            if (_hasWeb)
              Segmented<String>(
                key: const ValueKey('score.view'),
                segments: [
                  ('notation', t.score.notation),
                  ('text', t.score.text),
                ],
                selected: showNotation ? 'notation' : 'text',
                onChanged: (v) => setState(() => _notation = v == 'notation'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Stack(
            children: [
              // The editor stays mounted under the notation so its state and focus survive the switch.
              Positioned.fill(
                child: Offstage(
                  offstage: showNotation,
                  child: TextField(
                    key: widget.textKey,
                    focusNode: _focus,
                    controller: widget.controller,
                    readOnly: widget.readOnly,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: _mono,
                    decoration: InputDecoration(
                      hintText: widget.readOnly ? null : t.score.placeholder,
                    ),
                  ),
                ),
              ),
              if (showNotation)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: line),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: ListenableBuilder(
                        listenable: widget.controller,
                        builder: (_, _) => widget.controller.text.trim().isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    t.score.empty,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              )
                            : WebViewWidget(controller: _web!),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (!_hasWeb && !Platform.isMacOS)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(t.score.unavailable, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}
