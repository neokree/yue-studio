"""Engine selection (backends.select_engine): pure function, no mlx/torch needed. Runs on any OS."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

ENGINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE))
import backends  # noqa: E402

MAC = dict(system="Darwin", machine="arm64", mlx_available=True)


def sel(env=None, config=None, **kw):
    args = {**MAC, "mem_gb": 48, **kw}
    return backends.select_engine(env=env or {}, config=config, **args)


def test_auto_on_apple_silicon_with_enough_memory_is_mlx():
    assert sel() == {"ar": "mlx", "nar": "mlx", "reason": "auto"}


@pytest.mark.parametrize("mem", [8, 16, 23.9])
def test_auto_below_24_gb_keeps_torch(mem):
    e = sel(mem_gb=mem)
    assert (e["ar"], e["nar"]) == ("torch", "torch") and "< 24 GB" in e["reason"]


def test_exactly_24_gb_is_mlx():
    assert sel(mem_gb=24)["ar"] == "mlx"


@pytest.mark.parametrize("system,machine", [("Linux", "x86_64"), ("Darwin", "x86_64"), ("Windows", "AMD64"), ("Linux", "aarch64")])
def test_not_apple_silicon_is_torch_even_when_mlx_is_requested(system, machine):
    for env in ({}, {"YUE2_STUDIO_ENGINE": "mlx"}):
        e = sel(env, system=system, machine=machine)
        assert e["ar"] == e["nar"] == "torch" and "not Apple Silicon" in e["reason"]


def test_mlx_missing_falls_back_to_torch():
    e = sel(mlx_available=False)
    assert e["ar"] == "torch" and "mlx not installed" in e["reason"]


def test_env_switch_forces_torch_on_a_capable_mac():
    assert sel({"YUE2_STUDIO_ENGINE": "torch"})["ar"] == "torch"
    assert sel({"YUE2_STUDIO_ENGINE": " TORCH "})["nar"] == "torch"


def test_explicit_mlx_ignores_the_memory_threshold():
    assert sel({"YUE2_STUDIO_ENGINE": "mlx"}, mem_gb=16)["ar"] == "mlx"


def test_config_file_switch_and_env_precedence(tmp_path):
    (tmp_path / "engine.json").write_text(json.dumps({"engine": "torch"}))
    cfg = backends.engine_config(tmp_path)
    assert sel(config=cfg)["ar"] == "torch"
    assert sel({"YUE2_STUDIO_ENGINE": "mlx"}, config=cfg)["ar"] == "mlx"  # env wins


def test_bad_config_or_value_means_auto(tmp_path):
    (tmp_path / "engine.json").write_text("{not json")
    assert backends.engine_config(tmp_path) == {}
    assert backends.engine_config(tmp_path / "missing") == {}
    assert sel({"YUE2_STUDIO_ENGINE": "cuda"})["ar"] == "mlx"


def test_nar_can_be_switched_alone():
    e = sel({"YUE2_STUDIO_NAR_ENGINE": "torch"})
    assert (e["ar"], e["nar"]) == ("mlx", "torch")
    e = sel({"YUE2_STUDIO_ENGINE": "torch", "YUE2_STUDIO_NAR_ENGINE": "mlx"})
    assert (e["ar"], e["nar"]) == ("torch", "mlx")


def test_importing_backends_never_imports_mlx_or_torch():
    code = ("import sys; sys.path.insert(0, %r); import backends; backends.select_engine(); "
            "print(sorted(m for m in sys.modules if m.split('.')[0] in ('mlx', 'torch', 'yue2')))") % str(ENGINE)
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout.strip()
    assert out == "[]"
