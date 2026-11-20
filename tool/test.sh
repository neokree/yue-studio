#!/usr/bin/env bash
# YuE2 Studio test runner. Layers: unit (flutter test, 60 s), py (pytest, 20 s), e2e (Docker + Xvfb, 3 min budget; ~50 s warm, ~1 min with an empty build volume).
# Usage: tool/test.sh [--only unit|py|e2e]
set -euo pipefail
set -m   # each layer runs in its own process group so the budget watchdog can kill all of it

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=yue2-studio-test:3.44.3
SHOTS="$ROOT/build/e2e-shots"
BUDGET_UNIT=60
BUDGET_PY=20
BUDGET_E2E=180

ONLY=all
if [[ "${1:-}" == "--only" ]]; then ONLY="${2:-}"; fi
case "$ONLY" in all|unit|py|e2e) ;; *) echo "usage: $0 [--only unit|py|e2e]" >&2; exit 2;; esac

CONTAINER="yue2-e2e-$$"
SUMMARY=()
FAILED=0
cd "$ROOT"

# run_layer <name> <budget seconds> <function>: runs the function, enforces the wall-time budget.
run_layer() {
  local name=$1 budget=$2 fn=$3 t0=$SECONDS rc=0 timedout="$(mktemp)"
  rm -f "$timedout"
  echo "== $name (budget ${budget}s)"
  "$fn" &
  local pid=$!
  ( sleep "$budget"; : > "$timedout"; kill -TERM -- "-$pid" 2>/dev/null; sleep 2; kill -KILL -- "-$pid" 2>/dev/null
    docker rm -f "$CONTAINER" >/dev/null 2>&1 ) >/dev/null 2>&1 &
  local wd=$!
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  local dt=$((SECONDS - t0)) verdict=PASS
  if [[ -e "$timedout" ]]; then verdict="FAIL (over budget, killed)"; rm -f "$timedout"
  elif (( rc != 0 )); then verdict="FAIL (exit $rc)"
  elif (( dt > budget )); then verdict="FAIL (over budget)"; fi
  [[ "$verdict" == PASS ]] || FAILED=1
  SUMMARY+=("$(printf '%-6s %4ss / %ss  %s' "$name" "$dt" "$budget" "$verdict")")
}

layer_unit() { fvm flutter test; }

layer_py() { uv run --no-project --with pytest pytest engine/tests -q; }

# The named volume yue2-studio-build holds the whole /work copy (so .dart_tool, build/ and linux/flutter/ephemeral survive).
# rsync --checksum keeps the mtime of every unchanged file, so ninja/cmake and flutter's hash store rebuild only what changed.
layer_e2e() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE missing: docker build -t $IMAGE $ROOT/docker" >&2; return 1; }
  [[ -f pubspec.yaml && -f integration_test/app_e2e_test.dart ]] || { echo "pubspec.yaml / e2e test missing" >&2; return 1; }
  rm -rf "$SHOTS"; mkdir -p "$SHOTS"
  docker run --rm --name "$CONTAINER" \
    -v "$ROOT":/src:ro \
    -v yue2-pub-cache:/pub-cache \
    -v yue2-studio-build:/work \
    -v "$SHOTS":/shots \
    -e YUE2_STUDIO_UV=/work/tool/e2e-uv.sh \
    -e YUE2_STUDIO_ENGINE_DIR=/work/engine \
    -e YUE2_STUDIO_MANIFEST=/work/engine/manifests/fake.json \
    -e YUE2_STUDIO_FAKE=1 \
    -e YUE2_FAKE_STEP_SECONDS=0.5 \
    -e YUE2_STUDIO_TEST_FAIL_STEP=python-3.12 \
    -e YUE2_STUDIO_TEST_PICK_FILE=/tmp/e2e-pick.wav \
    -e E2E_SHOTS_DIR=/shots \
    -e E2E_SONG_JSON=/work/reference/song.json \
    "$IMAGE" bash -c '
      set -euo pipefail
      SECONDS=0
      rsync -a --checksum --delete \
        --exclude=/build --exclude=/.dart_tool --exclude=/.git --exclude=/.fvm --exclude=/.scratch --exclude=/dist --exclude=/design --exclude=/macos --exclude=/assets/uv/uv \
        --exclude=/.flutter-plugins-dependencies --exclude=/linux/flutter/ephemeral --exclude='/linux/flutter/generated_*' /src/ /work/
      echo "rsync ${SECONDS}s"
      cd /work
      # 4 s silent 48 kHz stereo wav for the Cover step (no python in the image: perl ships with ubuntu)
      perl tool/make_pick_wav.pl > /tmp/e2e-pick.wav
      export YUE2_STUDIO_DATA_DIR="$(mktemp -d /tmp/yue-data.XXXXXX)"
      # Python 3.12 baked into the image: the setup step finds it already installed (no network); everything else is installed from zero.
      # Symlinks, not a copy: the installer measures growth of uv-python by listing it file by file, which is ~10 s for the 3.5k real files in debug under Xvfb.
      mkdir -p "$YUE2_STUDIO_DATA_DIR/uv-python"
      for n in cpython-3.12.16-linux-aarch64-gnu cpython-3.12-linux-aarch64-gnu; do ln -s /opt/seed/uv-python/cpython-3.12.16-linux-aarch64-gnu "$YUE2_STUDIO_DATA_DIR/uv-python/$n"; done
      xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/app_e2e_test.dart -d linux
    ' 2>&1 | tee "$ROOT/build/e2e.log"
}

mkdir -p "$ROOT/build"

[[ $ONLY == all || $ONLY == unit ]] && run_layer unit $BUDGET_UNIT layer_unit
[[ $ONLY == all || $ONLY == py ]] && run_layer py $BUDGET_PY layer_py
[[ $ONLY == all || $ONLY == e2e ]] && run_layer e2e $BUDGET_E2E layer_e2e

echo; echo "== summary"; printf '%s\n' "${SUMMARY[@]}"
[[ $FAILED == 0 ]] && echo "ALL PASS" || { echo "FAILED"; exit 1; }