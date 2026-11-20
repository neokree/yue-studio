#!/usr/bin/env bash
# Real engine run, macOS host, headless (no GUI). Downloads about 11 GB into a data dir, then runs
# real setup -> real generation (reference/song.json) -> real Free transcription -> cover generation.
# Usage: tool/real_engine.sh [--fresh] [data dir]     (default data dir: .scratch/real-data)
#   --fresh  wipe the data dir first; without it a previous run resumes (finished setup steps are skipped)
# Log: .scratch/real-engine.log (also streamed to the terminal). Prints per-step timings and output paths at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRESH=0
if [[ "${1:-}" == "--fresh" ]]; then FRESH=1; shift; fi
DATA="${1:-$ROOT/.scratch/real-data}"
LOG="$ROOT/.scratch/real-engine.log"

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "macOS Apple Silicon only" >&2; exit 2; }
cd "$ROOT"
[[ -x assets/uv/uv ]] || { echo "bundled uv missing: run tool/fetch_uv.sh first" >&2; exit 2; }
mkdir -p "$(dirname "$LOG")"
if (( FRESH )); then rm -rf "$DATA"; fi
mkdir -p "$DATA"
: > "$LOG"

# The test builds its own Paths (bundled uv, engine/ in place, real manifest); these are only the inputs.
export REAL_ENGINE_DATA="$DATA" REAL_ENGINE_LOG="$LOG"
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN
fvm flutter test tool/real_engine/real_engine_test.dart -r expanded --timeout=none
