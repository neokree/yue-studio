"""Cached 8-bit MLX token weights (mlx_convert.py): converted once from the official checkpoint, bit-identical to
quantizing at load time. Skipped unless mlx, torch, yue2 and safetensors are importable (runs on Linux with mlx[cpu])."""
import sys
from pathlib import Path

import pytest

mx = pytest.importorskip("mlx.core")
torch = pytest.importorskip("torch")
pytest.importorskip("yue2")
pytest.importorskip("safetensors")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mlx_ar  # noqa: E402
import mlx_convert  # noqa: E402
from yue2.modeling_yue2 import YuE2Config, YuE2ForCausalLM  # noqa: E402
from yue2.protocol import VOCAB_SIZE  # noqa: E402


@pytest.fixture(scope="module")
def model():
    torch.manual_seed(0)
    cfg = YuE2Config(hidden_size=128, num_hidden_layers=2, num_attention_heads=4, num_key_value_heads=2, head_dim=32,
                     intermediate_size=256, vocab_size=VOCAB_SIZE)
    return YuE2ForCausalLM(cfg).eval().to(torch.bfloat16)


def test_artifact_roundtrip_is_bit_exact(model, tmp_path):
    """Converted once from safetensors == quantized at load from the PyTorch model (same bytes, same logits)."""
    from safetensors.torch import save_file
    src = tmp_path / "src"
    src.mkdir()
    save_file({k: v.contiguous() for k, v in model.state_dict().items()}, str(src / "model.safetensors"))
    (src / "config.json").write_text(model.config.to_json_string(), encoding="utf-8")
    out = tmp_path / "artifact"
    mlx_convert.convert(src, out)
    a = mlx_ar.ARWeights.from_artifact(out)
    b = mlx_ar.ARWeights.from_model(model)
    assert a.quantized and set(a.flat) == set(b.flat)
    for k in a.flat:
        assert mx.array_equal(a.flat[k], b.flat[k]).item(), k
    mlx_convert.check(out)



def test_check_rejects_a_truncated_or_foreign_artifact(model, tmp_path):
    from safetensors.torch import save_file
    src = tmp_path / "src"
    src.mkdir()
    save_file({k: v.contiguous() for k, v in model.state_dict().items()}, str(src / "model.safetensors"))
    (src / "config.json").write_text(model.config.to_json_string(), encoding="utf-8")
    out = mlx_convert.convert(src, tmp_path / "a")
    arrays = mx.load(str(out / "weights.safetensors"))
    arrays.pop("layers.1.down.q")
    mx.save_safetensors(str(out / "weights.safetensors"), arrays)
    with pytest.raises(ValueError, match="differ"):
        mlx_convert.check(out)
    (out / "config.json").write_text('{"format": "other", "recipe_version": 1}')
    with pytest.raises(ValueError, match="format"):
        mlx_convert.check(out)


def test_artifact_size_matches_the_estimate(model, tmp_path):
    """estimated_bytes (used for the manifest's download/disk estimate) is the real array payload."""
    from safetensors.torch import save_file
    src = tmp_path / "src"
    src.mkdir()
    save_file({k: v.contiguous() for k, v in model.state_dict().items()}, str(src / "model.safetensors"))
    (src / "config.json").write_text(model.config.to_json_string(), encoding="utf-8")
    out = mlx_convert.convert(src, tmp_path / "a")
    size = (out / "weights.safetensors").stat().st_size
    est = mlx_convert.estimated_bytes(mlx_ar.config_dict(model.config))
    assert est <= size <= est + 64 * 1024  # + the safetensors JSON header
