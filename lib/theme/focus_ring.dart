import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

/// macOS-style outer focus ring around a text field: 3 px, drawn outside the field box, only while the field
/// (or a descendant) really holds keyboard focus. The field keeps its own border.
class FocusRing extends StatelessWidget {
  const FocusRing({super.key, required this.child, this.radius = Radii.field});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    child: Builder(
      builder: (context) {
        final on = Focus.of(context).hasFocus;
        return AnimatedContainer(
          duration: Motion.of(context, Motion.control),
          curve: Motion.curve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            // spread paints outside the box; the field's own fill covers the inside.
            boxShadow: on ? [BoxShadow(color: focusRing(AppColors.of(context)).color, spreadRadius: 3)] : const [],
          ),
          child: child,
        );
      },
    ),
  );
}
