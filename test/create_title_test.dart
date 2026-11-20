import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yue2_studio/create/create_draft.dart';
import 'package:yue2_studio/theme/tokens.dart';

double _lum(Color c) {
  double f(double v) => v <= .03928 ? v / 12.92 : math.pow((v + .055) / 1.055, 2.4).toDouble();
  return .2126 * f(c.r) + .7152 * f(c.g) + .0722 * f(c.b);
}

double _contrast(Color a, Color b) {
  final l1 = _lum(a), l2 = _lum(b);
  return (math.max(l1, l2) + .05) / (math.min(l1, l2) + .05);
}

void main() {
  test('placeholder keeps 4.5:1 on the field colour in both themes', () {
    for (final c in [AppColors.light, AppColors.dark]) {
      expect(_contrast(c.placeholder, c.field), greaterThanOrEqualTo(4.5));
    }
  });

  test('prefill carries the title', () {
    final d = CreateDraft()..prefill(title: 'City Lights', style: 's');
    expect((d.title.text, d.style.text), ('City Lights', 's'));
  });
}
