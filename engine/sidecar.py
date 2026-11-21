#!/usr/bin/env python3
"""YuE2 Studio engine sidecar. Protocol: engine/PROTOCOL.md (single source of truth).

  sidecar.py --data-dir <dir> [--fake]

This file only does the protocol; the engine lives behind backends.Backend (engine/backends.py).
Fake mode uses only the standard library. torch/yue2 are imported only in real mode.
"""
import argparse
import json
import os
import queue
import random
import sys
import threading
import traceback
from pathlib import Path

from backends import Cancelled, FakeBackend, Yue2Backend

VERSION = 1

_write_lock = threading.Lock()
_proto = sys.stdout  # protocol channel; main() points sys.stdout at stderr so library prints cannot corrupt it
_state_lock = threading.Lock()
cancel = threading.Event()  # set by "cancel" for the running job, or by "shutdown"
stop = threading.Event()  # shutdown requested
jobs = queue.Queue()  # accepted requests; None = exit
current = None  # id of the accepted/running job (None = idle)
backend = None  # set in main(); one backend (and one loaded model) for the whole process


def emit(**event):
    line = json.dumps(event, ensure_ascii=False) + "\n"
    try:
        with _write_lock:
            _proto.write(line)
            _proto.flush()
    except (BrokenPipeError, ValueError):  # the app is gone
        os._exit(0)


# ---------------------------------------------------------------- job loop

def progress_for(job):
    # extra: additive fields, e.g. audio (PROTOCOL.md section 3)
    return lambda stage, done, total, **extra: emit(type="progress", job=job, stage=stage, done=done, total=total, **extra)


def run_job(req):
    job = req["job"]
    try:
        if req["type"] == "generate":
            if req.get("cot") not in ("full", "melody", "off"):
                raise ValueError("cot must be full, melody or off")
            seed = req.get("seed")
            seed = random.randrange(2**31) if not isinstance(seed, int) or seed < 0 else seed
            result = backend.generate({**req, "seed": seed}, progress_for(job), cancel)
        elif req["type"] == "stems":
            result = backend.stems(req, progress_for(job), cancel)
        else:
            result = backend.transcribe(req, progress_for(job), cancel)
        ev = dict(type="result", job=job, **result)
    except Cancelled:
        ev = dict(type="error", job=job, message="cancelled", cancelled=True)
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        ev = dict(type="error", job=job, message=str(exc) or type(exc).__name__, cancelled=False)
    finish()
    emit(**ev)


def finish():
    """Free the slot before the terminal event: the app may send the next request right after it."""
    global current
    with _state_lock:
        current = None
        if not stop.is_set():
            cancel.clear()


def handle(line):
    global current
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError("request must be a JSON object")
    except ValueError as exc:
        return emit(type="error", job=None, message=f"malformed request: {exc}", cancelled=False)
    kind, job = req.get("type"), req.get("job")
    if kind == "shutdown":
        stop.set()
        cancel.set()
        jobs.put(None)
    elif kind == "cancel":
        with _state_lock:
            if job is not None and job == current:
                cancel.set()
    elif kind in ("generate", "transcribe", "stems"):
        missing = [k for k in (("job", "out", "cot") if kind == "generate" else ("job", "out", "audio")) if req.get(k) in (None, "")]
        if missing:
            return emit(type="error", job=job, message="missing field: " + ", ".join(missing), cancelled=False)
        with _state_lock:
            busy = current is not None
            if not busy:
                current = job
        if busy:
            emit(type="error", job=job, message="busy", cancelled=False)
        else:
            jobs.put(req)
    else:
        emit(type="error", job=job, message=f"unknown request type: {kind!r}", cancelled=False)


def reader():
    for line in sys.stdin:
        if line.strip():
            handle(line)
    stop.set()  # stdin closed: the app is gone
    cancel.set()
    jobs.put(None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", type=Path, default=Path.home() / "Library" / "Application Support" / "YuE2 Studio")
    ap.add_argument("--fake", action="store_true")
    args = ap.parse_args()
    sys.stdin.reconfigure(encoding="utf-8")
    _proto.reconfigure(encoding="utf-8")
    sys.stdout = sys.stderr
    global backend
    backend = FakeBackend() if args.fake else Yue2Backend(args.data_dir)  # real: offline env set in its constructor
    emit(type="ready", version=VERSION, fake=args.fake)
    threading.Thread(target=reader, daemon=True).start()
    while (req := jobs.get()) is not None:
        run_job(req)
    os._exit(0)  # a daemon thread blocked on stdin can abort a normal interpreter exit


if __name__ == "__main__":
    main()
