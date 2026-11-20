#!/usr/bin/env bash
# Release build -> ad-hoc signed "YuE² Studio.app" -> drag-and-drop dmg in dist/YuE2-Studio-<version>.dmg.
# Usage: tool/make_dmg.sh                 (macOS only; publishes nothing)
#        tool/make_dmg.sh --arm64 <app>   only thin and check an existing .app in place (for testing the arm64 logic)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS only" >&2; exit 2; }

# The app is arm64 only (the bundled uv is arm64 only; macOS keeps Intel Macs out through the binary).
# Flutter copies prebuilt universal frameworks (FlutterMacOS, objective_c, ...): thin them, then refuse any x86_64 left.
# Both steps run on the executable and on every Mach-O under Frameworks, BEFORE codesign (thinning breaks signatures).
arm64_only() {
  local app="$1" f archs bad=0
  while IFS= read -r -d '' f; do
    archs="$(lipo -archs "$f" 2>/dev/null)" || continue   # not a Mach-O
    if [[ " $archs " == *" x86_64 "* && " $archs " == *" arm64 "* && "$f" == */Contents/Frameworks/* ]]; then
      lipo -thin arm64 "$f" -output "$f.thin" && mv "$f.thin" "$f"
      archs="$(lipo -archs "$f")"
    fi
    if [[ " $archs " == *" x86_64 "* ]]; then
      echo "error: $f still has x86_64 ($archs); the app must be arm64 only (check ARCHS in macos/Runner/Configs/Release.xcconfig)" >&2
      bad=1
    fi
  done < <(find "$app/Contents/MacOS" "$app/Contents/Frameworks" -type f -print0 2>/dev/null)
  return $bad
}
if [[ "${1:-}" == --arm64 ]]; then
  arm64_only "${2:?usage: tool/make_dmg.sh --arm64 <app>}" && echo "arm64 only: ok"
  exit
fi

VERSION="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' pubspec.yaml | head -1)"
[[ -n "$VERSION" ]] || { echo "cannot read version from pubspec.yaml" >&2; exit 1; }
NAME="YuE² Studio"
DMG="dist/YuE2-Studio-$VERSION.dmg"

[[ -x assets/uv/uv ]] || tool/fetch_uv.sh   # the bundled uv is gitignored: the release needs it
fvm flutter pub get
fvm flutter build macos --release

# PRODUCT_NAME should give "YuE² Studio.app"; fall back to whatever single .app the build produced.
PRODUCTS="build/macos/Build/Products/Release"
APP="$PRODUCTS/$NAME.app"
if [[ ! -d "$APP" ]]; then
  APP="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "$APP" ]] || { echo "no .app in $PRODUCTS" >&2; exit 1; }
  echo "warning: expected '$NAME.app', found '$(basename "$APP")' (check PRODUCT_NAME in macos/Runner/Configs/AppInfo.xcconfig)" >&2
fi

arm64_only "$APP" || exit 1
xattr -cr "$APP"
codesign --deep --force -s - "$APP"
codesign --verify --deep --strict "$APP"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/yue2-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"   # ditto keeps the signature and symlinks
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
