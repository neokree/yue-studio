#!/usr/bin/env bash
# YuE2 Studio test runner. Layers: unit (flutter test, 60 s), py (pytest, 20 s), e2e (Docker + Xvfb, 3 min).
# Usage: tool/test.sh [--only unit|py|e2e]
set -euo pipefail
set -m   # each layer runs in its own process group so the budget watchdog can kill all of it

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=yue2-studio-test:3.44.3
SHOTS="$ROOT/build/e2e-shots"
BUDGET_UNIT=60
BUDGET_PY=20
BUDGET_E2E=180
BUDGET_E2E_COLD=600   # first run builds the Linux app into empty volumes; later runs use BUDGET_E2E

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

layer_e2e() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE missing: docker build -t $IMAGE $ROOT/docker" >&2; return 1; }
  [[ -f pubspec.yaml && -f integration_test/app_e2e_test.dart ]] || { echo "pubspec.yaml / e2e test missing" >&2; return 1; }
  rm -rf "$SHOTS"; mkdir -p "$SHOTS"
  docker run --rm --name "$CONTAINER" \
    -v "$ROOT":/src:ro \
    -v yue2-pub-cache:/pub-cache \
    -v yue2-studio-build:/work/build \
    -v "$SHOTS":/shots \
    -e YUE2_STUDIO_UV=/usr/local/bin/uv \
    -e YUE2_STUDIO_ENGINE_DIR=/work/engine \
    -e YUE2_STUDIO_MANIFEST=/work/engine/manifests/fake.json \
    -e YUE2_STUDIO_FAKE=1 \
    -e YUE2_FAKE_STEP_SECONDS=0.2 \
    -e E2E_SHOTS_DIR=/shots \
    -e E2E_SONG_JSON=/work/reference/song.json \
    "$IMAGE" bash -c '
      set -euo pipefail
      rsync -a --delete --exclude=/build --exclude=/.dart_tool --exclude=/.git --exclude=/.fvm --exclude=/dist /src/ /work/
      cd /work
      export YUE2_STUDIO_DATA_DIR="$(mktemp -d /tmp/yue-data.XXXXXX)"
      flutter pub get
      xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/app_e2e_test.dart -d linux
    ' 2>&1 | tee "$ROOT/build/e2e.log"
}

cold=0
if [[ $ONLY == all || $ONLY == e2e ]]; then
  docker volume inspect yue2-studio-build >/dev/null 2>&1 || cold=1
fi
mkdir -p "$ROOT/build"

[[ $ONLY == all || $ONLY == unit ]] && run_layer unit $BUDGET_UNIT layer_unit
[[ $ONLY == all || $ONLY == py ]] && run_layer py $BUDGET_PY layer_py
if [[ $ONLY == all || $ONLY == e2e ]]; then
  if (( cold )); then echo "(cold e2e: empty build volume, budget ${BUDGET_E2E_COLD}s this once)"; run_layer e2e $BUDGET_E2E_COLD layer_e2e
  else run_layer e2e $BUDGET_E2E layer_e2e; fi
fi

echo; echo "== summary"; printf '%s\n' "${SUMMARY[@]}"
[[ $FAILED == 0 ]] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
