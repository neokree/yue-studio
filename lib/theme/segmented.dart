import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

/// Segmented control as in the mock: field-coloured track, the selected segment lifts in window colour, semibold.
/// Use for every 2-3 way choice. Each segment gets Key('KEY.VALUE') when [key] is a ValueKey of String.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
  });

  /// (value, label) in display order.
  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final base = key is ValueKey<String> ? (key as ValueKey<String>).value : null;
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: c.field,
          borderRadius: BorderRadius.circular(Radii.segmented),
          border: Border.all(color: c.divider),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < segments.length; i++)
            _Segment(
              key: base == null ? null : Key('$base.${segments[i].$1}'),
              label: segments[i].$2,
              on: segments[i].$1 == selected,
              onTap: () => onChanged(segments[i].$1),
            ),
        ]),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({super.key, required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      selected: on,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => onTap())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Builder(builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return AnimatedContainer(
              duration: Motion.of(context, Motion.control),
              curve: Motion.curve,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              decoration: BoxDecoration(
                color: on ? c.background : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.segmented - 2),
                border: focused ? Border.fromBorderSide(focusRing(c)) : null,
                boxShadow: on ? const [BoxShadow(color: Color(0x29000000), blurRadius: 2, offset: Offset(0, 1))] : null,
              ),
              child: Text(label,
                  style: TextStyle(
                      fontSize: TypeSize.body, fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: c.text)),
            );
          }),
        ),
      ),
    );
  }
}
