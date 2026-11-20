"""Sidecar protocol tests, fake mode, run as a subprocess.

  uv run --no-project --with pytest pytest engine/tests -q
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import backends  # noqa: E402

SIDECAR = Path(__file__).resolve().parent.parent / "sidecar.py"


class Sidecar:
    def __init__(self, tmp, step="0.01"):
        self.tmp = tmp
        env = dict(os.environ, YUE2_FAKE_STEP_SECONDS=step)
        self.p = subprocess.Popen([sys.executable, str(SIDECAR), "--fake", "--data-dir", str(tmp)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, env=env)
        self.events = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.events.put(json.loads(line))

    def send(self, obj):
        self.raw(json.dumps(obj))

    def raw(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()

    def next(self, timeout=5):
        return self.events.get(timeout=timeout)

    def until(self, kinds=("result", "error"), job=None, timeout=10):
        """Collect events up to and including the first terminal one."""
        seen = []
        end = time.time() + timeout
        while time.time() < end:
            ev = self.next(timeout=max(0.1, end - time.time()))
            seen.append(ev)
            if ev["type"] in kinds and (job is None or ev.get("job") == job):
                return seen
        raise AssertionError(f"timeout, saw {seen}")

    def gen(self, job, **kw):
        req = dict(type="generate", job=job, out=str(self.tmp / job), style="lofi", lyrics="[Verse]\nla", cot="full", seed=7)
        self.send({**req, **kw})

    def close(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait()


@pytest.fixture
def sc(tmp_path):
    s = Sidecar(tmp_path)
    assert s.next()["type"] == "ready"
    yield s
    s.close()


@pytest.fixture
def slow(tmp_path):
    s = Sidecar(tmp_path, step="1.0")
    assert s.next()["type"] == "ready"
    yield s
    s.close()


def test_ready(tmp_path):
    s = Sidecar(tmp_path)
    try:
        assert s.next() == {"type": "ready", "version": 1, "fake": True}
    finally:
        s.close()


def test_generate_events_and_files(sc, tmp_path):
    sc.gen("a")
    evs = sc.until()
    assert all(e["job"] == "a" for e in evs)
    stages = [e["stage"] for e in evs if e["type"] == "progress"]
    order = list(dict.fromkeys(stages))
    assert order == ["load", "abc", "semantic", "nar", "vae"]
    by = {s: [e for e in evs if e.get("stage") == s] for s in order}
    assert by["load"][0]["total"] is None
    assert all(e["total"] is None for e in by["abc"] + by["semantic"])
    assert [e["done"] for e in by["semantic"]] == sorted(e["done"] for e in by["semantic"])
    assert all(e["done"] % 25 == 0 for e in by["semantic"])
    assert by["nar"][-1]["done"] == by["nar"][-1]["total"]
    assert by["vae"][-1]["done"] == by["vae"][-1]["total"]
    res = evs[-1]
    assert res["type"] == "result" and res["seed"] == 7 and res["audio"] == "audio.wav"
    out = Path(res["dir"])
    assert out == tmp_path / "a"
    with wave.open(str(out / res["audio"])) as w:
        assert (w.getframerate(), w.getnchannels()) == (48000, 2)
        assert 1.0 <= w.getnframes() / 48000 <= 2.0
        assert abs(res["duration"] - w.getnframes() / 48000) < 1e-6
    assert (out / "score.abc").read_text().startswith("X:")
    assert json.loads((out / "result.json").read_text())["seed"] == 7


def test_second_generate_skips_load_and_random_seed(sc):
    sc.gen("a")
    sc.until()
    sc.gen("b", seed=-1)
    evs = sc.until()
    assert "load" not in [e.get("stage") for e in evs]
    assert evs[-1]["type"] == "result" and evs[-1]["seed"] >= 0


def test_cot_off_and_given_abc_skip_abc_stage(sc, tmp_path):
    sc.gen("a", cot="off")
    assert "abc" not in [e.get("stage") for e in sc.until()]
    sc.gen("b", abc="X:1\nK:C\nCDEF|]")
    evs = sc.until()
    assert "abc" not in [e.get("stage") for e in evs]
    assert (tmp_path / "b" / "score.abc").read_text().startswith("X:1\nK:C")


def test_cancel_mid_job(slow):
    slow.gen("a")
    while slow.next()["type"] != "progress":
        pass
    slow.send({"type": "cancel", "job": "a"})
    t = time.time()
    last = slow.until(timeout=3)[-1]
    assert last == {"type": "error", "job": "a", "message": "cancelled", "cancelled": True}
    assert time.time() - t < 2
    slow.gen("b")  # the sidecar is usable afterwards
    assert slow.until(timeout=15)[-1]["type"] == "result"


def test_busy(slow):
    slow.gen("a")
    slow.gen("b")
    ev = slow.until(kinds=("error",), job="b")[-1]
    assert ev["message"] == "busy" and ev["job"] == "b"
    slow.send({"type": "cancel", "job": "a"})
    assert slow.until(kinds=("error",), job="a")[-1]["cancelled"] is True


def test_malformed_line_keeps_running(sc):
    sc.raw("{not json")
    ev = sc.next()
    assert ev["type"] == "error" and ev["job"] is None
    sc.raw("[1,2]")
    assert sc.next()["job"] is None
    sc.gen("a")
    assert sc.until()[-1]["type"] == "result"


def test_missing_field_and_unknown_type(sc):
    sc.send({"type": "generate", "job": "a"})
    ev = sc.next()
    assert ev["type"] == "error" and ev["job"] == "a"
    sc.send({"type": "nope", "job": "z"})
    assert sc.next()["type"] == "error"


def test_transcribe(sc, tmp_path):
    for mode in ("full", "melody"):
        sc.send({"type": "transcribe", "job": mode, "audio": str(tmp_path / "x.wav"), "out": str(tmp_path / mode), "mode": mode})
        evs = sc.until()
        assert evs[0] == {"type": "progress", "job": mode, "stage": "transcribe", "done": 0, "total": None}
        assert evs[-1] == {"type": "result", "job": mode, "dir": str(tmp_path / mode)}
        assert (tmp_path / mode / "score.abc").read_text().startswith("X:")


def test_shutdown_idle(sc):
    sc.send({"type": "shutdown"})
    assert sc.p.wait(timeout=5) == 0


def test_shutdown_mid_job(slow):
    slow.gen("a")
    slow.next()
    slow.send({"type": "shutdown"})
    assert slow.p.wait(timeout=5) == 0
    assert slow.until(kinds=("error",))[-1]["cancelled"] is True


# ---------------------------------------------------------------- timings (additive protocol field)

def test_result_timings(sc):
    sc.gen("a")
    res = sc.until()[-1]
    t = res["timings"]
    assert set(t) == {"load", "abc", "semantic", "nar", "vae"}
    assert all(isinstance(v, float) and v >= 0 for v in t.values())
    assert t["load"] > 0 and t["abc"] > 0 and t["semantic"] > 0 and t["nar"] > 0 and t["vae"] > 0
    sc.gen("b", cot="off")  # second job: model already loaded, no abc stage
    t = sc.until()[-1]["timings"]
    assert t["load"] == 0 and t["abc"] == 0 and t["semantic"] > 0


# ---------------------------------------------------------------- backend split

def test_backends_contract():
    assert issubclass(backends.FakeBackend, backends.Backend) and issubclass(backends.Yue2Backend, backends.Backend)
    assert backends.FakeBackend.fake and not backends.Yue2Backend.fake
    src = SIDECAR.read_text()
    assert "import torch" not in src and "from yue2" not in src  # sidecar.py only does protocol


def test_fake_backend_direct(tmp_path):
    b = backends.FakeBackend()
    seen = []
    r = b.generate({"out": str(tmp_path / "x"), "seed": 3, "cot": "full", "style": "s"},
                   lambda *a: seen.append(a[0]), threading.Event())
    assert r["audio"] == "audio.wav" and r["timings"]["load"] > 0
    assert list(dict.fromkeys(seen)) == ["load", "abc", "semantic", "nar", "vae"]
    ev = threading.Event()
    ev.set()
    with pytest.raises(backends.Cancelled):
        b.generate({"out": str(tmp_path / "y"), "seed": 3, "cot": "full"}, lambda *a: None, ev)


def test_yue2_backend_is_offline_and_pinned(tmp_path, monkeypatch):
    for k in ("HF_HUB_OFFLINE", "HF_HOME", "HF_TOKEN"):
        monkeypatch.setenv(k, "x")  # restored after the test
    monkeypatch.delenv("YUE2_STUDIO_MANIFEST", raising=False)
    b = backends.Yue2Backend(tmp_path)
    assert os.environ["HF_HUB_OFFLINE"] == "1" and os.environ["HF_HOME"] == str(tmp_path / "hf")
    assert "HF_TOKEN" not in os.environ and b.pipe is None  # constructing must not import torch or load anything
    with pytest.raises(RuntimeError, match="not installed"):
        b.transcribe({"out": str(tmp_path / "o"), "audio": "a.wav", "mode": "full"}, lambda *a: None, threading.Event())
    pins = backends.pinned_revisions()
    assert pins["m-a-p/YuE2-3B"] == "8f24312f187763b9854adeec87e437e2b03bbff1"
    assert pins["m-a-p/MERT-v2-FullSong"] == "d8ba1c745e733b3908ce6ad16ebeb17ac7600a42"


def test_real_manifest_pins_every_model():
    m = json.loads((Path(__file__).resolve().parent.parent / "manifests" / "real.json").read_text())
    hf = [s for s in m["steps"] if s["kind"] == "hf"]
    assert len(hf) == 4 and all(len(s["revision"]) == 40 and s["revision"] != "main" for s in hf)
    assert m["bytes"] >= sum(s["bytes"] for s in hf)
    venv = next(s for s in m["steps"] if s["id"] == "venv-sheetsage2")
    assert "soundfile==0.14.0" in venv["packages"] and venv["requirements"].endswith("requirements.txt")


def test_real_mode_transcribe_without_install_errors(tmp_path):
    """Real sidecar starts without torch; a transcribe with no venv fails cleanly instead of hanging."""
    p = subprocess.Popen([sys.executable, str(SIDECAR), "--data-dir", str(tmp_path)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                         env={k: v for k, v in os.environ.items() if not k.startswith("HF_")})
    try:
        assert json.loads(p.stdout.readline()) == {"type": "ready", "version": 1, "fake": False}
        p.stdin.write(json.dumps({"type": "transcribe", "job": "t", "audio": "a.wav", "out": str(tmp_path / "o"), "mode": "melody"}) + "\n")
        p.stdin.flush()
        ev = json.loads(p.stdout.readline())
        assert ev["type"] == "error" and "not installed" in ev["message"] and ev["cancelled"] is False
    finally:
        p.kill()
        p.wait()


# ---------------------------------------------------------------- yue2 @ 1116bea contract (fake pipeline)

class FakePipeline:
    """Same __call__ signature as YuE2Pipeline at 1116bea: cancelled(), on_token(phase, token), on_progress(stage, done, total)."""

    def __call__(self, style=None, lyrics=None, *, tags=None, abc_sampling=None, semantic_sampling=None,
                 cancelled=None, on_token=None, on_progress=None, **kwargs):
        assert set(kwargs) <= {"cot", "seed", "abc", "cfg_scale", "id"}, kwargs  # SongRequest(**kwargs)
        assert callable(cancelled) and not isinstance(cancelled, threading.Event)
        for _ in range(60):
            on_token("abc", 1)
        for _ in range(50):
            on_token("semantic", 1)
        for i in range(1, 4):
            on_progress("nar", i, 3)
        on_progress("vae", 1, 2)
        on_progress("vae", 2, 2)
        if cancelled():
            raise InterruptedError("cancelled")

        class Song:
            audio = [0.0] * 96000
            sample_rate = 48000
            timing = {"abc": {"seconds": 1.5}, "semantic": {"seconds": 2.5}, "nar_seconds": 3.5, "vae_seconds": 0.5}

            def save_artifacts(self, directory):
                (Path(directory) / "audio.flac").write_bytes(b"x")

        return Song()


def test_yue2_backend_reports_progress_through_pipeline_callbacks(tmp_path, monkeypatch):
    monkeypatch.delenv("YUE2_STUDIO_MANIFEST", raising=False)
    b = backends.Yue2Backend(tmp_path)
    b.pipe = FakePipeline()
    events = []
    r = b.generate({"out": str(tmp_path / "o"), "seed": 5, "cot": "full", "style": "s", "lyrics": "l"},
                   lambda *a: events.append(a), threading.Event())
    assert list(dict.fromkeys(e[0] for e in events)) == ["abc", "semantic", "nar", "vae"]  # pipe preloaded: no load event
    assert [e[1:] for e in events if e[0] == "abc"] == [(0, None), (25, None), (50, None)]
    assert [e[1:] for e in events if e[0] == "semantic"] == [(0, None), (25, None), (50, None)]
    assert [e[1:] for e in events if e[0] == "nar"] == [(1, 3), (2, 3), (3, 3)]
    assert [e[1:] for e in events if e[0] == "vae"] == [(1, 2), (2, 2)]
    assert r["audio"] == "audio.flac" and r["duration"] == 2.0 and (tmp_path / "o" / "audio.flac").exists()
    assert r["timings"] == {"load": 0.0, "abc": 1.5, "semantic": 2.5, "nar": 3.5, "vae": 0.5}


def test_yue2_backend_cancel_maps_to_cancelled(tmp_path, monkeypatch):
    monkeypatch.delenv("YUE2_STUDIO_MANIFEST", raising=False)
    b = backends.Yue2Backend(tmp_path)
    b.pipe = FakePipeline()
    ev = threading.Event()
    ev.set()
    with pytest.raises(backends.Cancelled):
        b.generate({"out": str(tmp_path / "o"), "seed": 5, "cot": "off", "style": "s"}, lambda *a: None, ev)


def test_fetch_disables_xet_before_importing_huggingface_hub(tmp_path):
    stub = tmp_path / "stub"
    stub.mkdir()
    (stub / "huggingface_hub.py").write_text(
        "import os, pathlib\npathlib.Path(os.environ['SEEN']).write_text(os.environ.get('HF_HUB_DISABLE_XET', 'unset'))\n"
        "HfApi = constants = hf_hub_download = None\n")
    seen = tmp_path / "seen"
    env = {k: v for k, v in os.environ.items() if not k.startswith("HF_")}
    subprocess.run([sys.executable, "-c", f"import sys; sys.path[:0] = [{str(stub)!r}, {str(SIDECAR.parent)!r}]; import fetch"],
                   env=dict(env, SEEN=str(seen)), check=True, timeout=20)
    assert seen.read_text() == "1"


def _load_stages_across_transcribe(tmp_path, mem_gb, monkeypatch):
    monkeypatch.setenv("YUE2_STUDIO_MEM_GB", mem_gb)
    s = Sidecar(tmp_path)
    try:
        assert s.next()["type"] == "ready"
        loads = []
        for job in ("g1", "t", "g2"):
            if job == "t":
                s.send({"type": "transcribe", "job": job, "audio": str(tmp_path / "x.wav"), "out": str(tmp_path / job), "mode": "full"})
            else:
                s.gen(job)
            evs = s.until(job=job)
            assert evs[-1]["type"] == "result"
            loads.append(any(e.get("stage") == "load" for e in evs))
        return loads
    finally:
        s.close()


def test_low_memory_unloads_before_transcribe(tmp_path, monkeypatch):
    # 16 GB: g1 loads, transcribe unloads, g2 loads again
    assert _load_stages_across_transcribe(tmp_path, "16", monkeypatch) == [True, False, True]


def test_24gb_still_unloads(tmp_path, monkeypatch):
    assert _load_stages_across_transcribe(tmp_path, "24", monkeypatch) == [True, False, True]


def test_enough_memory_keeps_pipeline(tmp_path, monkeypatch):
    assert _load_stages_across_transcribe(tmp_path, "32", monkeypatch) == [True, False, False]


def test_yue2_unload_drops_pipe(tmp_path):
    b = backends.Yue2Backend(tmp_path)
    b.pipe = object()
    b.unload()
    assert b.pipe is None
    b.unload()  # idempotent


def test_mps_watermarks():
    # cap in GB = high x Metal working set (2/3 of RAM up to 36 GB, 3/4 above): 13-14 GB, 1.0 where the set is smaller
    for gb, high, ws in [(16, 1.0, 10.67), (24, 0.8125, 16), (32, 0.61, 21.33), (48, 0.373, 36), (64, 0.292, 48)]:
        env = backends.mps_watermarks(gb)
        h, low = float(env["PYTORCH_MPS_HIGH_WATERMARK_RATIO"]), float(env["PYTORCH_MPS_LOW_WATERMARK_RATIO"])
        assert h == pytest.approx(high, abs=0.002) and low == pytest.approx(0.7 * h, abs=0.002)
        assert 0 < low < h <= 1.0
        assert h * ws >= 10.6  # the real 11 GB peak fits (16 GB: the whole working set)
    assert backends.mps_watermarks(float("inf")) == {}
