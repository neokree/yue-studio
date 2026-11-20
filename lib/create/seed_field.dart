import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.g.dart';
import '../theme/focus_ring.dart';
import '../theme/tokens.dart';

/// Quiet seed input shared by Create and Cover: small, borderless until focused, "random" as placeholder.
/// [key] goes on the inner TextField so tests can `enterText` by it.
class SeedField extends StatelessWidget {
  const SeedField({Key? key, required this.controller, this.label, this.hint}) : _fieldKey = key, super(key: null);

  final TextEditingController controller;

  /// Default to the Create strings.
  final String? label, hint;
  final Key? _fieldKey;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    OutlineInputBorder b(BorderSide s) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.button), borderSide: s);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label ?? t.create.seed,
          style: TextStyle(fontSize: TypeSize.caption, color: c.textSecondary),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 72,
          child: FocusRing(
            radius: Radii.button,
            child: TextField(
              key: _fieldKey,
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: TextStyle(fontSize: TypeSize.caption, fontWeight: FontWeight.w400, color: c.text),
              decoration: InputDecoration(
                hintText: hint ?? t.create.seedHint,
                hintStyle: TextStyle(fontSize: TypeSize.caption, color: c.placeholder),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                fillColor: WidgetStateColor.resolveWith(
                  (s) => s.contains(WidgetState.focused) ? c.field : Colors.transparent,
                ),
                border: b(BorderSide.none),
                enabledBorder: b(BorderSide.none),
                focusedBorder: b(BorderSide(color: c.divider)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
