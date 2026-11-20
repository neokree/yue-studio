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
