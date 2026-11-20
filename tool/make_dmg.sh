#!/usr/bin/env bash
# Release build -> ad-hoc signed "YuE2 Studio.app" -> drag-and-drop dmg in dist/YuE2-Studio-<version>.dmg.
# Usage: tool/make_dmg.sh        (macOS only; publishes nothing)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS only" >&2; exit 2; }

VERSION="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' pubspec.yaml | head -1)"
[[ -n "$VERSION" ]] || { echo "cannot read version from pubspec.yaml" >&2; exit 1; }
NAME="YuE2 Studio"
DMG="dist/YuE2-Studio-$VERSION.dmg"

[[ -x assets/uv/uv ]] || tool/fetch_uv.sh   # the bundled uv is gitignored: the release needs it
fvm flutter pub get
fvm flutter build macos --release

# PRODUCT_NAME should give "YuE2 Studio.app"; fall back to whatever single .app the build produced.
PRODUCTS="build/macos/Build/Products/Release"
APP="$PRODUCTS/$NAME.app"
if [[ ! -d "$APP" ]]; then
  APP="$(find "$PRODUCTS" -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "$APP" ]] || { echo "no .app in $PRODUCTS" >&2; exit 1; }
  echo "warning: expected '$NAME.app', found '$(basename "$APP")' (check PRODUCT_NAME in macos/Runner/Configs/AppInfo.xcconfig)" >&2
fi

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
