"""MLX engine parity against the upstream PyTorch reference, on a tiny random YuE2 (2 layers, hidden 128).

Skipped unless mlx, torch and yue2 are importable (the default `pytest engine/tests` layer has none of them). Runs on
Linux with `mlx[cpu]` too, so the math is checked without a Mac; speed is NOT measured here (tool/bench_mlx.py on a Mac).

  uv pip install "mlx[cpu]" torch yue2-infer@<pinned zip> pytest && pytest engine/tests/test_mlx_parity.py
"""
import sys
from pathlib import Path

import pytest

mx = pytest.importorskip("mlx.core")
torch = pytest.importorskip("torch")
pytest.importorskip("yue2")
np = pytest.importorskip("numpy")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mlx_ar  # noqa: E402
import mlx_nar  # noqa: E402
from yue2.modeling_yue2 import YuE2Config, YuE2ForCausalLM  # noqa: E402
from yue2.nar import synthesize as torch_synthesize  # noqa: E402
from yue2.protocol import CODEC_OFFSET, CODEC_SIZE, MUSIC_START, VOCAB_SIZE, Sampling  # noqa: E402
from yue2.sampling import generate_tokens as torch_generate  # noqa: E402

PREFIX = list(range(1000, 1048)) + [MUSIC_START]


@pytest.fixture(scope="module")
def model():
    torch.manual_seed(0)
    cfg = YuE2Config(hidden_size=128, num_hidden_layers=2, num_attention_heads=4, num_key_value_heads=2, head_dim=32,
                     intermediate_size=256, vocab_size=VOCAB_SIZE, max_position_embeddings=24576, max_latent_frames=24576)
    m = YuE2ForCausalLM(cfg).eval()
    with torch.no_grad():  # sharper logits than the 0.02-std init, so greedy decoding is not a coin toss
        m.lm_head.weight.mul_(40)
    return m.to(torch.bfloat16)


def torch_logits(model, ids):
    with torch.inference_mode():
        return model(torch.tensor([ids]), use_cache=False, logits_to_keep=1).logits[0, -1].float().numpy()


def mlx_logits(w, ids):
    cache = mlx_ar.KVCache(w, len(ids))
    h = mlx_ar.forward(w, mx.array([ids], dtype=mx.int32), [cache])
    return np.array(w.logits(h, 0, w.V).astype(mx.float32))[0]


def corr(a, b):
    return float(np.corrcoef(a, b)[0, 1])


def near_top(ref, idx, rel=0.02):
    """True when ref[idx] is within rel * std of ref's max. A random tiny model has many logits tied at bf16
    resolution, so exact argmax equality is a coin toss there; this checks the pick is a top pick of the reference."""
    return ref[idx] >= ref.max() - rel * ref.std()


def test_bf16_prefill_logits_match_torch(model):
    lt, lm = torch_logits(model, PREFIX), mlx_logits(mlx_ar.ARWeights.from_model(model, bits=None), PREFIX)
    assert corr(lt, lm) > 0.9995  # bf16 logits of magnitude ~10 round in steps of 1/16
    assert near_top(lt, lm.argmax())


def test_q8_logits_close_to_bf16(model):
    lt, lq = torch_logits(model, PREFIX), mlx_logits(mlx_ar.ARWeights.from_model(model), PREFIX)
    assert corr(lt, lq) > 0.999
    assert near_top(lt, lq.argmax(), rel=0.2)


def test_kv_cache_decode_equals_full_prefill(model):
    """Prefill + 1-token steps through the cache give the logits of a full forward over the same ids."""
    w = mlx_ar.ARWeights.from_model(model, bits=None)
    ids = PREFIX + [CODEC_OFFSET + 5, CODEC_OFFSET + 77, CODEC_OFFSET + 901]
    cache = mlx_ar.KVCache(w, len(ids))
    mlx_ar.forward(w, mx.array([PREFIX], dtype=mx.int32), [cache])
    for t in ids[len(PREFIX):]:
        h = mlx_ar.forward(w, mx.array([[t]], dtype=mx.int32), [cache])
    stepped = np.array(w.logits(h, 0, w.V).astype(mx.float32))[0]
    assert corr(stepped, mlx_logits(w, ids)) > 0.9999


def _semantic(max_tokens, temperature=0.0):
    return Sampling(temperature=temperature, top_p=0.93, top_k=50, repetition_penalty=1.0, penalty_window=50,
                    min_tokens=max_tokens, max_tokens=max_tokens)


# 8-bit rel: on random Gaussian weights the q8 logit error reaches ~0.2 std; trained weights are the Mac bench's job.
@pytest.mark.parametrize("bits,rel", [(None, 0.02), (8, 0.2)])
def test_teacher_forced_picks_are_reference_top_picks(model, bits, rel):
    """Along torch's own greedy sequence, every MLX step picks a token torch also ranks at the top."""
    ref, _, _ = torch_generate(model, PREFIX, _semantic(24), 7, "semantic", use_cuda_graph=False)
    with torch.inference_mode():
        all_logits = model(torch.tensor([PREFIX + ref]), use_cache=False).logits[0].float().numpy()
    w = mlx_ar.ARWeights.from_model(model, bits=bits)
    lo, hi = mlx_ar.vocab_window("semantic")
    cache = mlx_ar.KVCache(w, len(PREFIX) + len(ref))
    h = mlx_ar.forward(w, mx.array([PREFIX], dtype=mx.int32), [cache])
    exact = 0
    for i, token in enumerate(ref):
        pick = lo + int(np.array(w.logits(h, lo, hi).astype(mx.float32))[0].argmax())
        torch_row = all_logits[len(PREFIX) - 1 + i, lo:hi]
        assert near_top(torch_row, pick - lo, rel), f"step {i}: MLX picked {pick}, not a torch top pick"
        exact += pick == token
        h = mlx_ar.forward(w, mx.array([[token]], dtype=mx.int32), [cache])
    print(f"bits={bits}: {exact}/{len(ref)} teacher-forced argmax identical to torch")


def test_greedy_generation_runs_end_to_end(model):
    w = mlx_ar.ARWeights.from_model(model)
    got, timing, truncated = mlx_ar.generate_tokens(w, PREFIX, _semantic(24), 7, "semantic")
    assert len(got) == 24 and truncated
    assert all(CODEC_OFFSET <= t < CODEC_OFFSET + CODEC_SIZE for t in got)
    assert timing["execution"] == "mlx-q8" and timing["output_tokens"] == 24


def test_sampled_tokens_follow_the_seed(model):
    """Same seed -> same tokens; a different seed differs (the RNG is upstream's CPU torch.Generator)."""
    w = mlx_ar.ARWeights.from_model(model, bits=None)
    a, _, _ = mlx_ar.generate_tokens(w, PREFIX, _semantic(16, 1.0), 11, "semantic")
    b, _, _ = mlx_ar.generate_tokens(w, PREFIX, _semantic(16, 1.0), 11, "semantic")
    c, _, _ = mlx_ar.generate_tokens(w, PREFIX, _semantic(16, 1.0), 12, "semantic")
    assert a == b and a != c


def test_cfg_runs_both_branches_batched(model):
    w = mlx_ar.ARWeights.from_model(model, bits=None)
    negative = list(range(2000, 2030)) + [MUSIC_START]
    ref, _, _ = torch_generate(model, PREFIX, _semantic(12), 3, "semantic", negative=negative, cfg_scale=1.5,
                               use_cuda_graph=False)
    got, timing, _ = mlx_ar.generate_tokens(w, PREFIX, _semantic(12), 3, "semantic", negative=negative, cfg_scale=1.5)
    assert timing["cfg_branches"] == 2
    assert len(got) == len(ref) == 12
    assert all(CODEC_OFFSET <= t < CODEC_OFFSET + CODEC_SIZE for t in got)


def test_cancel_stops_generation(model):
    w = mlx_ar.ARWeights.from_model(model, bits=None)
    calls = []
    with pytest.raises(InterruptedError):
        mlx_ar.generate_tokens(w, PREFIX, _semantic(50), 1, "semantic", cancelled=lambda: len(calls) > 3,
                               on_token=lambda *a: calls.append(a))


def test_nar_latents_match_torch(model):
    codec = [(i * 37) % CODEC_SIZE for i in range(40)]
    ref = torch_synthesize(model, PREFIX, codec, 5, steps=4)
    got = mlx_nar.synthesize(model, mlx_nar.NARWeights(model), PREFIX, codec, 5, steps=4)
    assert got.shape == ref.shape == (40, 64)
    assert corr(ref.flatten().numpy(), got.flatten().numpy()) > 0.999
