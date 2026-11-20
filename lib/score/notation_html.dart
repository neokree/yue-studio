import 'dart:convert';

/// Self-contained page for the notation WebView: abcjs inlined, theme text colour, transparent background.
/// The page exposes render(abc); the app calls it through runJavaScript, it never reloads the page.
String notationHtml({
  required String abcjs,
  required String textColor,
  String background = 'transparent',
  String abc = '',
}) =>
    '''
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;padding:0;background:$background;color:$textColor;overflow-x:hidden;
  font:12px -apple-system,BlinkMacSystemFont,sans-serif}
#paper{padding:8px 10px;color:$textColor}
#paper svg{display:block;color:$textColor}
#paper svg path,#paper svg text,#paper svg tspan{fill:currentColor}
#paper svg path[fill="none"]{fill:none}
</style>
<script>${abcjs.replaceAll('</script', '<\\/script')}</script>
</head><body><div id="paper"></div>
<script>
function render(abc){
  try { ABCJS.renderAbc('paper', abc, {responsive:'resize', add_classes:false}); }
  catch(e) { document.getElementById('paper').textContent = String(e); }
}
window.render = render;
render(${jsonEncode(abc).replaceAll('</', '<\\/')});
</script></body></html>''';
