#!/usr/bin/env python3
"""YuE2 Studio engine sidecar. Protocol: engine/PROTOCOL.md (single source of truth).

  sidecar.py --data-dir <dir> [--fake]

Fake mode uses only the standard library. torch/yue2 are imported only in real mode.
"""
import argparse
import json
import math
import os
import queue
import random
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import wave
from pathlib import Path

VERSION = 1
FAKE_STEP = float(os.environ.get("YUE2_FAKE_STEP_SECONDS", "0.3"))
ENGINE_DIR = Path(__file__).resolve().parent

_write_lock = threading.Lock()
_proto = sys.stdout  # protocol channel; main() points sys.stdout at stderr so library prints cannot corrupt it
_state_lock = threading.Lock()
cancel = threading.Event()  # set by "cancel" for the running job, or by "shutdown"
stop = threading.Event()  # shutdown requested
jobs = queue.Queue()  # accepted requests; None = exit
current = None  # id of the accepted/running job (None = idle)
_pipe = None  # real mode: YuE2Pipeline kept between jobs


class Cancelled(Exception):
    pass


def emit(**event):
    line = json.dumps(event, ensure_ascii=False) + "\n"
    try:
        with _write_lock:
            _proto.write(line)
            _proto.flush()
    except (BrokenPipeError, ValueError):  # the app is gone
        os._exit(0)


def nap(seconds):
    if cancel.wait(seconds):
        raise Cancelled()


def check():
    if cancel.is_set():
        raise Cancelled()


# ---------------------------------------------------------------- fake mode

FAKE_ABC = """X:1
T:Fake Song
M:4/4
L:1/8
Q:1/4=100
K:C
"Am"A2 c2 e2 c2 | "F"A2 c2 f2 c2 | "C"G2 c2 e2 c2 | "G"B2 d2 g4 |]
"""


def fake_stage(job, stage, ticks, total=None):
    """Token stages count up by 25 with total null; counted stages go 1..total."""
    for i in range(1, ticks + 1):
        nap(FAKE_STEP / ticks)
        emit(type="progress", job=job, stage=stage, done=25 * i if total is None else i, total=total)


def write_wav(path, seed):
    rate = 48000
    seconds = 1 + (seed % 5) / 4  # 1.0 .. 2.0 s, so songs differ
    freq = 220 * 2 ** ((seed % 12) / 12)
    n = int(rate * seconds)
    samples = (int(12000 * math.sin(2 * math.pi * freq * i / rate)) for i in range(n))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<hh", s, s) for s in samples))
    return n / rate


_fake_loaded = False


def fake_generate(req, seed):
    global _fake_loaded
    job, out = req["job"], Path(req["out"])
    out.mkdir(parents=True, exist_ok=True)
    if not _fake_loaded:
        emit(type="progress", job=job, stage="load", done=0, total=None)
        nap(FAKE_STEP)
        _fake_loaded = True
    abc = req.get("abc")
    if req["cot"] != "off" and not abc:
        fake_stage(job, "abc", 3)
    fake_stage(job, "semantic", 6)
    fake_stage(job, "nar", 5, total=5)
    fake_stage(job, "vae", 2, total=2)
    duration = write_wav(out / "audio.wav", seed)
    (out / "score.abc").write_text(abc or FAKE_ABC, encoding="utf-8")
    (out / "result.json").write_text(json.dumps(
        {"fake": True, "seed": seed, "duration": duration, "style": req.get("style"), "cot": req["cot"]}), encoding="utf-8")
    return dict(dir=str(out), audio="audio.wav", seed=seed, duration=duration)


def fake_transcribe(req):
    job, out = req["job"], Path(req["out"])
    out.mkdir(parents=True, exist_ok=True)
    emit(type="progress", job=job, stage="transcribe", done=0, total=None)
    nap(FAKE_STEP)
    (out / "score.abc").write_text(FAKE_ABC, encoding="utf-8")
    return dict(dir=str(out))


# ---------------------------------------------------------------- real mode

def real_generate(req, seed, data):
    global _pipe
    job, out = req["job"], Path(req["out"])
    if not str(req.get("style", "")).strip():
        raise ValueError("Style is required.")
    out.mkdir(parents=True, exist_ok=True)
    if _pipe is None:
        emit(type="progress", job=job, stage="load", done=0, total=None)
        from yue2 import YuE2Pipeline  # real mode only
        _pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="auto", cache_dir=str(data / "hf" / "hub"))
        check()
    counts = {}

    def on_token(phase, _token):
        stage = "abc" if phase == "abc" else "semantic"
        counts[stage] = counts.get(stage, 0) + 1
        if counts[stage] % 25 == 0:
            emit(type="progress", job=job, stage=stage, done=counts[stage], total=None)

    def on_progress(stage, done, total):
        emit(type="progress", job=job, stage="nar" if stage == "nar" else "vae", done=int(done), total=int(total))

    request = dict(style=req["style"], lyrics=req.get("lyrics", ""), cot=req["cot"], seed=seed)
    if req.get("abc"):
        request["abc"] = req["abc"]
    try:
        song = _pipe(**request, on_token=on_token, on_progress=on_progress, cancelled=cancel.is_set)
    except Exception:
        if cancel.is_set():  # the pipeline may raise when cancelled
            raise Cancelled()
        raise
    check()
    song.save_artifacts(out)
    return dict(dir=str(out), audio="audio.flac", seed=seed, duration=float(len(song.audio) / song.sample_rate))


def real_transcribe(req, data):
    job, out = req["job"], Path(req["out"])
    py = data / "venvs" / "sheetsage2" / "bin" / "python"
    if not py.exists():
        raise RuntimeError("SheetSage2 is not installed (run setup).")
    out.mkdir(parents=True, exist_ok=True)
    cmd = [str(py), str(ENGINE_DIR / "sheetsage_wrap.py"), req["audio"],
           "--model-dir", str(data / "models" / "SheetSage2"), "--output", str(out)]
    if req.get("mode") == "melody":
        cmd.append("--melody-only")
    env = dict(os.environ, PYTORCH_ENABLE_MPS_FALLBACK="1", HF_HOME=str(data / "hf"), PYTHONUNBUFFERED="1")
    env.pop("HF_TOKEN", None)
    started = time.monotonic()
    emit(type="progress", job=job, stage="transcribe", done=0, total=None)
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
        try:
            while True:
                try:
                    proc.wait(timeout=2)
                    break
                except subprocess.TimeoutExpired:
                    check()
                    emit(type="progress", job=job, stage="transcribe", done=int(time.monotonic() - started), total=None)
        except BaseException:
            proc.kill()
            proc.wait()
            raise
        if proc.returncode or not (out / "score.abc").exists():
            log.seek(0)
            raise RuntimeError("Transcription failed: " + log.read().decode("utf-8", "replace")[-600:])
    return dict(dir=str(out))


# ---------------------------------------------------------------- job loop

def run_job(req, args):
    job = req["job"]
    try:
        if req["type"] == "generate":
            if req.get("cot") not in ("full", "melody", "off"):
                raise ValueError("cot must be full, melody or off")
            seed = req.get("seed")
            seed = random.randrange(2**31) if not isinstance(seed, int) or seed < 0 else seed
            result = fake_generate(req, seed) if args.fake else real_generate(req, seed, args.data_dir)
        else:
            result = fake_transcribe(req) if args.fake else real_transcribe(req, args.data_dir)
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
    elif kind in ("generate", "transcribe"):
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
    if not args.fake:
        os.environ["HF_HOME"] = str(args.data_dir / "hf")
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        os.environ.pop("HF_TOKEN", None)
    emit(type="ready", version=VERSION, fake=args.fake)
    threading.Thread(target=reader, daemon=True).start()
    while (req := jobs.get()) is not None:
        run_job(req, args)
    os._exit(0)  # a daemon thread blocked on stdin can abort a normal interpreter exit


if __name__ == "__main__":
    main()
