#!/usr/bin/env bash
# Regenerates macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png from lib/brand/yue_logo.dart.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fvm flutter test tool/make_icon/make_icon_test.dart
