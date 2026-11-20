"""Engine backends. sidecar.py only speaks the protocol; everything that makes audio lives here.

A Backend has three methods (swap the class to swap the engine, e.g. YuE2-Turbo later):

  load(on_progress)                                  load weights (idempotent, lazy)
  generate(request, on_progress, cancelled) -> dict  result fields: dir, audio, seed, duration, timings
  transcribe(request, on_progress, cancelled) -> dict  result fields: dir

on_progress(stage, done, total) reports a protocol stage (PROTOCOL.md section 3).
cancelled is a threading.Event; a backend raises Cancelled promptly once it is set.
request is the protocol request dict; for generate, "seed" is already resolved to an int.
timings (generate) is {load, abc, semantic, nar, vae} in seconds; 0 for a stage that did not run.
"""
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parent
FAKE_STEP = float(os.environ.get("YUE2_FAKE_STEP_SECONDS", "0.3"))
STAGES = ("load", "abc", "semantic", "nar", "vae")


class Cancelled(Exception):
    pass


class Backend:
    fake = False

    def load(self, on_progress=None):
        raise NotImplementedError

    def generate(self, request, on_progress, cancelled):
        raise NotImplementedError

    def transcribe(self, request, on_progress, cancelled):
        raise NotImplementedError

    def unload(self):
        """Drop the loaded pipeline; the next generate loads it again (stage `load`). Called before transcribe on < 24 GB."""


def memory_gb():
    """Physical memory in GB (sysctl hw.memsize); env YUE2_STUDIO_MEM_GB overrides it (tests). inf if unknown."""
    env = os.environ.get("YUE2_STUDIO_MEM_GB")
    try:
        if env:
            return float(env)
        return int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)) / 2**30
    except (OSError, ValueError, subprocess.SubprocessError):
        return float("inf")  # unknown: do not unload


def low_memory():
    return memory_gb() < 24


def nap(cancelled, seconds):
    if cancelled.wait(seconds):
        raise Cancelled()


# ---------------------------------------------------------------- fake (standard library only)

FAKE_ABC = """X:1
T:Fake Song
M:4/4
L:1/8
Q:1/4=100
K:C
"Am"A2 c2 e2 c2 | "F"A2 c2 f2 c2 | "C"G2 c2 e2 c2 | "G"B2 d2 g4 |]
"""


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


class FakeBackend(Backend):
    fake = True

    def __init__(self):
        self.loaded = False

    def unload(self):
        self.loaded = False

    def load(self, on_progress=None):
        if not self.loaded:
            if on_progress:
                on_progress("load", 0, None)
            time.sleep(FAKE_STEP)
            self.loaded = True

    def _stage(self, req_cancelled, on_progress, stage, ticks, total=None):
        """Token stages count up by 25 with total null; counted stages go 1..total."""
        started = time.monotonic()
        for i in range(1, ticks + 1):
            nap(req_cancelled, FAKE_STEP / ticks)
            on_progress(stage, 25 * i if total is None else i, total)
        return time.monotonic() - started

    def generate(self, req, on_progress, cancelled):
        out, seed = Path(req["out"]), req["seed"]
        out.mkdir(parents=True, exist_ok=True)
        t = dict.fromkeys(STAGES, 0.0)
        if not self.loaded:
            started = time.monotonic()
            on_progress("load", 0, None)
            nap(cancelled, FAKE_STEP)
            self.loaded = True
            t["load"] = time.monotonic() - started
        abc = req.get("abc")
        if req["cot"] != "off" and not abc:
            t["abc"] = self._stage(cancelled, on_progress, "abc", 3)
        t["semantic"] = self._stage(cancelled, on_progress, "semantic", 6)
        t["nar"] = self._stage(cancelled, on_progress, "nar", 5, total=5)
        t["vae"] = self._stage(cancelled, on_progress, "vae", 2, total=2)
        duration = write_wav(out / "audio.wav", seed)
        (out / "score.abc").write_text(abc or FAKE_ABC, encoding="utf-8")
        (out / "result.json").write_text(json.dumps(
            {"fake": True, "seed": seed, "duration": duration, "style": req.get("style"), "cot": req["cot"]}),
            encoding="utf-8")
        return dict(dir=str(out), audio="audio.wav", seed=seed, duration=duration, timings=t)

    def transcribe(self, req, on_progress, cancelled):
        out = Path(req["out"])
        out.mkdir(parents=True, exist_ok=True)
        if low_memory():
            self.unload()
        on_progress("transcribe", 0, None)
        nap(cancelled, FAKE_STEP)
        (out / "score.abc").write_text(FAKE_ABC, encoding="utf-8")
        return dict(dir=str(out))


# ---------------------------------------------------------------- real: YuE2 (torch) + SheetSage2 (subprocess)

def pinned_revisions():
    """{repo: sha} from the setup manifest, so generation loads exactly the snapshots setup fetched."""
    path = Path(os.environ.get("YUE2_STUDIO_MANIFEST") or ENGINE_DIR / "manifests" / "real.json")
    try:
        steps = json.loads(path.read_text(encoding="utf-8"))["steps"]
    except (OSError, ValueError, KeyError):
        return {}
    return {s["repo"]: s["revision"] for s in steps if s.get("kind") == "hf"}


class Yue2Backend(Backend):
    """Offline by construction: HF_HUB_OFFLINE=1 plus local_files_only, so nothing is ever downloaded here."""

    def __init__(self, data_dir):
        self.data = Path(data_dir)
        self.pipe = None
        os.environ["HF_HOME"] = str(self.data / "hf")
        os.environ["HF_HUB_OFFLINE"] = "1"  # before huggingface_hub is imported
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        os.environ.pop("HF_TOKEN", None)

    def load(self, on_progress=None):
        if self.pipe is not None:
            return
        if on_progress:
            on_progress("load", 0, None)
        pins = pinned_revisions()
        try:
            from yue2 import YuE2Pipeline
            self.pipe = YuE2Pipeline.from_pretrained(
                "m-a-p/YuE2-3B", vae="m-a-p/YuE2-Vae", device="auto", progress=False,
                revision=pins.get("m-a-p/YuE2-3B"), vae_revision=pins.get("m-a-p/YuE2-Vae"),
                cache_dir=str(self.data / "hf" / "hub"), local_files_only=True)
            # Weights load lazily inside the first call; do it now so stage `load` is the load and abc/semantic are not.
            self.pipe._load_model()
        except Exception as exc:
            raise RuntimeError(f"Could not load the YuE2 model from the local install ({type(exc).__name__}: {exc}). "
                               "Run setup again.") from exc

    def unload(self):
        if self.pipe is None:
            return
        self.pipe = None
        import gc
        gc.collect()
        try:
            import torch
            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception:  # torch missing or no MPS: nothing more to free
            pass

    def generate(self, req, on_progress, cancelled):
        out, seed = Path(req["out"]), req["seed"]
        if not str(req.get("style", "")).strip():
            raise ValueError("Style is required.")
        out.mkdir(parents=True, exist_ok=True)
        t = dict.fromkeys(STAGES, 0.0)
        if self.pipe is None:
            started = time.monotonic()
            self.load(on_progress)
            t["load"] = time.monotonic() - started
            if cancelled.is_set():
                raise Cancelled()
        counts = {}

        def on_token(phase, _token):  # phases "abc" and "semantic"; one event per 25 tokens (PROTOCOL.md section 3)
            counts[phase] = n = counts.get(phase, 0) + 1
            if n == 1 or n % 25 == 0:
                on_progress(phase, n if n > 1 else 0, None)

        request = dict(style=req["style"], lyrics=req.get("lyrics", ""), cot=req["cot"], seed=seed)
        if req.get("abc"):
            request["abc"] = req["abc"]
        try:
            song = self.pipe(**request, cancelled=cancelled.is_set, on_token=on_token, on_progress=on_progress)
        except Exception:
            if cancelled.is_set():  # the pipeline raises InterruptedError when cancelled
                raise Cancelled()
            raise
        if cancelled.is_set():
            raise Cancelled()
        song.save_artifacts(out)
        pt = song.timing  # abc/semantic are dicts with "seconds"; nar/vae are plain floats (vae includes the lazy decoder load)
        t["abc"] = float((pt.get("abc") or {}).get("seconds", 0.0))
        t["semantic"] = float((pt.get("semantic") or {}).get("seconds", 0.0))
        t["nar"] = float(pt.get("nar_seconds", 0.0))
        t["vae"] = float(pt.get("vae_seconds", 0.0))
        return dict(dir=str(out), audio="audio.flac", seed=seed,
                    duration=float(len(song.audio) / song.sample_rate), timings=t)

    def transcribe(self, req, on_progress, cancelled):
        out = Path(req["out"])
        py = self.data / "venvs" / "sheetsage2" / "bin" / "python"
        if not py.exists():
            raise RuntimeError("SheetSage2 is not installed (run setup).")
        out.mkdir(parents=True, exist_ok=True)
        if low_memory():
            self.unload()  # SheetSage2's memory use is unmeasured: free the YuE2 weights first
        cmd = [str(py), str(ENGINE_DIR / "sheetsage_wrap.py"), req["audio"],
               "--model-dir", str(self.data / "models" / "SheetSage2"), "--output", str(out),
               "--device", "mps" if sys.platform == "darwin" else "auto"]
        if req.get("mode") == "melody":
            cmd.append("--melody-only")
        env = dict(os.environ, PYTHONUNBUFFERED="1")  # HF_HOME, HF_HUB_OFFLINE, MPS fallback set in __init__
        started = time.monotonic()
        on_progress("transcribe", 0, None)
        with tempfile.TemporaryFile() as log:
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
            try:
                while True:
                    try:
                        proc.wait(timeout=2)
                        break
                    except subprocess.TimeoutExpired:
                        if cancelled.is_set():
                            raise Cancelled()
                        on_progress("transcribe", int(time.monotonic() - started), None)
            except BaseException:
                proc.kill()
                proc.wait()
                raise
            if proc.returncode or not (out / "score.abc").exists():
                log.seek(0)
                raise RuntimeError("Transcription failed: " + log.read().decode("utf-8", "replace")[-600:])
        return dict(dir=str(out))
