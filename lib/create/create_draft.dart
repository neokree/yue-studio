import 'package:flutter/widgets.dart';

import '../engine/protocol.dart';

/// The Create form's state, kept outside the widget so it survives screen switches and can be prefilled
/// (Library "Reuse Style and Lyrics") from anywhere.
class CreateDraft extends ChangeNotifier {
  final style = TextEditingController();
  final lyrics = TextEditingController();
  final seed = TextEditingController();
  CotMode cot = CotMode.full;

  /// Song whose generation the Create pane is showing instead of the form, null for the form.
  String? watching;

  /// Set by Services: called after [prefill] so the app can switch to Create.
  VoidCallback? onPrefill;

  /// [cot] is a [CotMode] or its name; null fields keep their value.
  void prefill({String? style, String? lyrics, Object? cot, int? seed}) {
    if (style != null) this.style.text = style;
    if (lyrics != null) this.lyrics.text = lyrics;
    if (cot != null) this.cot = cot is CotMode ? cot : CotMode.parse('$cot');
    if (seed != null) this.seed.text = '$seed';
    watching = null;
    notifyListeners();
    onPrefill?.call();
  }

  void setCot(CotMode m) {
    cot = m;
    notifyListeners();
  }

  void watch(String songId) {
    watching = songId;
    notifyListeners();
  }

  /// Back to the form (sidebar "Create", or when the job ended).
  void showForm() {
    if (watching == null) return;
    watching = null;
    notifyListeners();
  }

  @override
  void dispose() {
    style.dispose();
    lyrics.dispose();
    seed.dispose();
    super.dispose();
  }
}
