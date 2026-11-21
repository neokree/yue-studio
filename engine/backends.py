"""Engine backends. sidecar.py only speaks the protocol; everything that makes audio lives here.

A Backend has three methods (swap the class to swap the engine, e.g. YuE2-Turbo later):

  load(on_progress)                                  load weights (idempotent, lazy)
  generate(request, on_progress, cancelled) -> dict  result fields: dir, audio, seed, duration, timings
  transcribe(request, on_progress, cancelled) -> dict  result fields: dir
  stems(request, on_progress, cancelled) -> dict  result fields: dir (the stems folder, one <name>.flac per STEMS)

on_progress(stage, done, total) reports a protocol stage (PROTOCOL.md section 3).
cancelled is a threading.Event; a backend raises Cancelled promptly once it is set.
request is the protocol request dict; for generate, "seed" is already resolved to an int.
timings (generate) is {load, abc, semantic, nar, vae} in seconds; 0 for a stage that did not run.
Real generate results also carry `engine` ({ar, nar, ar_weights}): which engine produced the song (select_engine).
"""
import importlib.util
import json
import math
import os
import platform
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
STEMS = ("drums", "bass", "other", "vocals", "guitar", "piano")  # Demucs htdemucs_6s sources
DEMUCS_CHECKPOINT = "hub/checkpoints/5c90dfd2-34c22ccb.th"  # under <data>/models/demucs (TORCH_HOME), setup step url


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

    def stems(self, request, on_progress, cancelled):
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
    return memory_gb() < 32  # SheetSage2 peaks ~15 GB + YuE2 resident ~9.7 GB: 24 GB Macs would swap


def mps_watermarks(mem_gb):
    """SheetSage2 env that caps the Metal allocator pool. Without it, decoding a 210 s song grows past 30 GB, because MPS keeps
    freed decode buffers. The ratios are relative to Metal's recommended working set (2/3 of RAM up to 36 GB, 3/4 above, as
    torch.mps.recommended_max_memory() reports); the cap lands at 13-14 GB (real peak is ~11 GB), never above 1.0 of the set.
    On 16 GB the set itself (10.7 GB) is the cap: close other apps (README). low = 0.7 x high. Unknown memory: no cap."""
    if not math.isfinite(mem_gb):
        return {}
    working_set = mem_gb * (2 / 3 if mem_gb <= 36 else 3 / 4)
    high = min(1.0, min(max(0.28 * mem_gb, 13.0), 14.0) / working_set)
    return {"PYTORCH_MPS_HIGH_WATERMARK_RATIO": f"{high:.3f}", "PYTORCH_MPS_LOW_WATERMARK_RATIO": f"{0.7 * high:.3f}"}


def abc_seconds(abc):
    """Song length in seconds from a score: bars x meter / tempo, longest voice (173.6 s song -> 175.8). None if unreadable.
    ponytail: counts bars, not note lengths, so a pickup or a short last bar counts as full; sum durations if that matters."""
    import re
    frac = lambda s: int(s[0]) / int(s[1])  # noqa: E731
    meter, tempo, voice, total = 1.0, None, "", {}
    for line in abc.splitlines():
        line = line.strip()
        if m := re.match(r"M:\s*(\d+)/(\d+)", line):
            meter = frac(m.groups())
        elif m := re.match(r"Q:\s*(?:(\d+)/(\d+)\s*=\s*)?(\d+)", line):
            tempo = tempo or int(m[3]) * (frac(m.groups()[:2]) if m[1] else 0.25)  # whole notes per minute; first one wins
        elif m := re.match(r"V:\s*(\S+)", line):
            voice = m[1]
        elif line and not re.match(r"[A-Za-z]:|%", line):
            bars = sum(int(m[1] or 1) if (m := re.fullmatch(r"Z(\d*)", b)) else 1
                       for b in re.sub(r'"[^"]*"|[\[\]:\s]', "", line).split("|") if b)
            total[voice] = total.get(voice, 0.0) + bars * meter
    return max(total.values()) / tempo * 60 if tempo and total else None


def run_child(cmd, env, stage, on_progress, cancelled):
    """Run an engine child process: one progress event at start, then one per ~2 s with elapsed seconds in done;
    killed on cancel (raises Cancelled). Returns (exit code, last 600 chars of its output)."""
    started = time.monotonic()
    on_progress(stage, 0, None)
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
                    on_progress(stage, int(time.monotonic() - started), None)
        except BaseException:
            proc.kill()
            proc.wait()
            raise
        log.seek(0)
        return proc.returncode, log.read().decode("utf-8", "replace")[-600:]


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

    def stems(self, req, on_progress, cancelled):
        out = Path(req["out"])
        on_progress("stems", 0, None)
        nap(cancelled, FAKE_STEP)
        out.mkdir(exist_ok=True)  # no parents, as stems.py
        for i, name in enumerate(STEMS):
            write_wav(out / f"{name}.wav", i)
        return dict(dir=str(out))


# ---------------------------------------------------------------- engine selection (pure: unit-tested on any OS)

ENGINE_CHOICES = ("auto", "mlx", "torch")
MLX_MIN_MEMORY_GB = 24  # torch model (~7.3 GB) + 8-bit AR (~2.3 GB) + bf16 NAR (~2.9 GB) MLX copies stay resident


def mlx_importable():
    """True when the mlx package is installed, without importing it (no Metal init, works on Linux)."""
    return importlib.util.find_spec("mlx") is not None


def engine_config(data_dir):
    """Optional <data>/engine.json, e.g. {"engine": "torch"}; missing or invalid -> {}."""
    try:
        cfg = json.loads((Path(data_dir) / "engine.json").read_text(encoding="utf-8"))
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def select_engine(env=None, config=None, system=None, machine=None, mem_gb=None, mlx_available=None):
    """Which engine runs the token loop (ar) and the acoustic velocity (nar): "mlx" or "torch", plus why.

    Switch: env YUE2_STUDIO_ENGINE (auto|mlx|torch), else "engine" in <data>/engine.json, else auto.
    YUE2_STUDIO_NAR_ENGINE / "nar_engine" override the acoustic stage alone (default: same as the token loop).
    auto = MLX on Apple Silicon with >= 24 GB and mlx installed, otherwise PyTorch. An explicit "mlx" where MLX cannot
    run falls back to PyTorch (never a crash); memory is not checked then (the user asked for it).
    """
    env = os.environ if env is None else env
    config = config or {}
    system = platform.system() if system is None else system
    machine = platform.machine() if machine is None else machine
    apple = system == "Darwin" and machine == "arm64"
    have_mlx = mlx_importable() if mlx_available is None else mlx_available

    def choice(env_key, cfg_key, default):
        value = str(env.get(env_key) or config.get(cfg_key) or default).strip().lower()
        if value not in ENGINE_CHOICES:
            print(f"engine: unknown {env_key}/{cfg_key} value {value!r}, using auto", file=sys.stderr, flush=True)
            return "auto"
        return value

    def resolve(wanted):
        if wanted == "torch":
            return "torch", "requested"
        if not apple:
            return "torch", "not Apple Silicon" + (" (mlx requested)" if wanted == "mlx" else "")
        if not have_mlx:
            return "torch", "mlx not installed" + (" (mlx requested)" if wanted == "mlx" else "")
        if wanted == "mlx":
            return "mlx", "requested"
        mem = memory_gb() if mem_gb is None else mem_gb
        if mem < MLX_MIN_MEMORY_GB:
            return "torch", f"{mem:.1f} GB memory < {MLX_MIN_MEMORY_GB} GB"
        return "mlx", "auto"

    ar_wanted = choice("YUE2_STUDIO_ENGINE", "engine", "auto")
    ar, ar_reason = resolve(ar_wanted)
    nar_wanted = choice("YUE2_STUDIO_NAR_ENGINE", "nar_engine", ar_wanted)
    nar, nar_reason = resolve(nar_wanted) if (env.get("YUE2_STUDIO_NAR_ENGINE") or config.get("nar_engine")) else (ar, ar_reason)
    return {"ar": ar, "nar": nar, "reason": ar_reason if ar == nar else f"ar: {ar_reason}; nar: {nar_reason}"}


# ---------------------------------------------------------------- real: YuE2 (torch) + SheetSage2 (subprocess)

def pinned_revisions(data_dir=None):
    """{repo: sha} of the YuE2 models, so generation loads exactly the snapshots setup fetched and verified.

    Source, in order: the switched model state (<data>/models/installed.json, written by modelset.py), the model-set
    manifest (engine/manifests/models.json), and hf steps of the setup manifest (installs from before model sets)."""
    import modelset
    state = modelset.installed(data_dir) if data_dir is not None else None
    if state:
        return {e["repo"]: e["revision"] for e in state["artifacts"].values() if e.get("kind") == "hf"}
    try:
        manifest = modelset.Manifest.read(os.environ.get("YUE2_STUDIO_MODELS_MANIFEST") or modelset.DEFAULT_MANIFEST)
        pins = {a.raw["repo"]: a.raw["revision"] for a in manifest.artifacts if a.kind == "hf"}
    except (OSError, ValueError, KeyError, modelset.MigrationError):
        pins = {}
    path = Path(os.environ.get("YUE2_STUDIO_MANIFEST") or ENGINE_DIR / "manifests" / "real.json")
    try:
        steps = json.loads(path.read_text(encoding="utf-8"))["steps"]
    except (OSError, ValueError, KeyError):
        return pins
    return {**{s["repo"]: s["revision"] for s in steps if s.get("kind") == "hf"}, **pins}


AR_ARTIFACT_ID = "yue2-3b-ar-mlx-q8"


class Yue2Backend(Backend):
    """Offline by construction: HF_HUB_OFFLINE=1 plus local_files_only, so nothing is ever downloaded here."""

    def __init__(self, data_dir):
        self.data = Path(data_dir)
        self.pipe = None
        self.engine = select_engine(config=engine_config(self.data))
        print(f"engine: tokens {self.engine['ar']}, acoustic {self.engine['nar']} ({self.engine['reason']})",
              file=sys.stderr, flush=True)
        os.environ["HF_HOME"] = str(self.data / "hf")
        os.environ["HF_HUB_OFFLINE"] = "1"  # before huggingface_hub is imported
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        os.environ.pop("HF_TOKEN", None)

    def load(self, on_progress=None):
        if self.pipe is not None:
            return
        if on_progress:
            on_progress("load", 0, None)
        pins = pinned_revisions(self.data)
        kwargs = dict(vae="m-a-p/YuE2-Vae", device="auto", progress=False,
                      revision=pins.get("m-a-p/YuE2-3B"), vae_revision=pins.get("m-a-p/YuE2-Vae"),
                      cache_dir=str(self.data / "hf" / "hub"), local_files_only=True)
        try:
            if "mlx" in (self.engine["ar"], self.engine["nar"]):
                try:
                    self.pipe = self._load_mlx(kwargs)
                except Exception as exc:  # MLX/Metal trouble must not cost the user the song: PyTorch can still run it
                    self.pipe = None
                    self.engine = {"ar": "torch", "nar": "torch", "reason": f"MLX failed to load ({type(exc).__name__}: {exc})"}
                    print(f"engine: falling back to PyTorch: {self.engine['reason']}", file=sys.stderr, flush=True)
            if self.pipe is None:
                from yue2 import YuE2Pipeline
                self.pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", **kwargs)
                # Weights load lazily inside the first call; do it now so stage `load` is the load and abc/semantic are not.
                self.pipe._load_model()
        except Exception as exc:
            raise RuntimeError(f"Could not load the YuE2 model from the local install ({type(exc).__name__}: {exc}). "
                               "Run setup again.") from exc

    def _load_mlx(self, kwargs):
        sys.path.insert(0, str(ENGINE_DIR))  # mlx_*.py live next to this file
        from mlx_pipeline import MlxYuE2Pipeline  # imports mlx + yue2 only here, never in fake mode or tests
        pipe = MlxYuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", ar_engine=self.engine["ar"], nar_engine=self.engine["nar"],
                                               ar_artifact=self.ar_artifact(), **kwargs)
        pipe.prepare_mlx()  # loads the PyTorch model too, so stage `load` is the whole load
        return pipe

    def ar_artifact(self):
        """Directory of the cached 8-bit MLX token weights (installed by modelset.py), or None: then they are
        quantized at load time from the loaded model (same weights, slower load)."""
        import modelset
        return modelset.artifact_dir(self.data, AR_ARTIFACT_ID)

    def engine_label(self):
        if self.pipe is not None and hasattr(self.pipe, "engine_label"):
            return self.pipe.engine_label()
        return {"ar": "torch", "nar": "torch", "ar_weights": None}

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
        # ponytail: no MPS watermark cap here, unmeasured on long songs and a wrong cap could break generation; if it grows
        # unbounded too, set PYTORCH_MPS_HIGH/LOW_WATERMARK_RATIO from mps_watermarks() in __init__ before torch loads.
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
        counts, score = {}, []

        def on_token(phase, token):  # phases "abc" and "semantic"; one event per 25 tokens (PROTOCOL.md section 3)
            counts[phase] = n = counts.get(phase, 0) + 1
            if phase == "abc":
                score.append(token)
            if n == 1 or n % 25 == 0:
                extra = {}
                if n == 1 and phase == "semantic" and score:  # the score is done: its bars and tempo give the song length
                    try:
                        seconds = abc_seconds(self.pipe.tokenizer.decode(score))
                        extra = {"audio": round(seconds, 1)} if seconds else {}
                    except Exception:  # the estimate is a nicety, never fail a job over it
                        pass
                on_progress(phase, n if n > 1 else 0, None, **extra)

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
                    duration=float(len(song.audio) / song.sample_rate), timings=t, engine=self.engine_label())

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
        # HF_HOME, HF_HUB_OFFLINE, MPS fallback set in __init__; the watermarks cap the Metal pool (see mps_watermarks)
        env = dict(os.environ, PYTHONUNBUFFERED="1", **mps_watermarks(memory_gb()))
        code, log = run_child(cmd, env, "transcribe", on_progress, cancelled)
        if code or not (out / "score.abc").exists():
            raise RuntimeError("Transcription failed: " + log)
        return dict(dir=str(out))

    def stems(self, req, on_progress, cancelled):
        out, model_dir = Path(req["out"]), self.data / "models" / "demucs"
        if not (model_dir / DEMUCS_CHECKPOINT).exists():
            raise RuntimeError("The stems model is not installed (run setup).")
        if low_memory():
            self.unload()  # Demucs peaks ~4.4 GB on a 145 s song; the resident YuE2 pipeline would push < 32 GB Macs to swap
        cmd = [sys.executable, str(ENGINE_DIR / "stems.py"), req["audio"], str(out), "--model-dir", str(model_dir)]
        code, log = run_child(cmd, dict(os.environ, PYTHONUNBUFFERED="1"), "stems", on_progress, cancelled)
        if code or not all((out / f"{n}.flac").exists() for n in STEMS):
            raise RuntimeError("Stem separation failed: " + log)
        return dict(dir=str(out))
