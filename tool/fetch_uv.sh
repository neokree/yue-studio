#!/usr/bin/env bash
# Downloads the pinned uv (aarch64-apple-darwin) from the astral-sh/uv GitHub release, verifies the published
# sha256 and writes assets/uv/uv (gitignored). The app copies it to <data>/bin/uv on first run.
# Usage: tool/fetch_uv.sh [--force]
set -euo pipefail

UV_VERSION=0.13.7
ASSET="uv-aarch64-apple-darwin.tar.gz"
BASE="https://github.com/astral-sh/uv/releases/download/$UV_VERSION"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/assets/uv/uv"

if [[ -x "$DEST" && "${1:-}" != "--force" ]] && [[ "$("$DEST" --version 2>/dev/null || true)" == "uv $UV_VERSION"* ]]; then
  echo "uv $UV_VERSION already at $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/$ASSET" "$BASE/$ASSET"
curl -fsSL --retry 3 -o "$TMP/$ASSET.sha256" "$BASE/$ASSET.sha256"

# The .sha256 file reads "<hash>  <name>" (or "<hash> *<name>"): compare only the hash.
EXPECTED="$(awk '{print $1}' "$TMP/$ASSET.sha256")"
ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
  echo "sha256 mismatch for $ASSET: expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"
mkdir -p "$(dirname "$DEST")"
install -m 755 "$TMP/uv-aarch64-apple-darwin/uv" "$DEST"
echo "uv $("$DEST" --version | awk '{print $2}') (sha256 ok) -> $DEST"
