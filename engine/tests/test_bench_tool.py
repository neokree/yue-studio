"""tool/bench_mlx.py: the teacher-forced agreement it reports, on a tiny random YuE2 (needs mlx, torch, yue2).

Skipped in the default layer. Checks the measurement, not speed: torch teacher-forced on its own greedy tokens must
rank exactly those tokens first, MLX bf16 must agree with torch on nearly every position, and the parent's child
command must round-trip its options.
"""
import argparse
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(ROOT / "tool"))
import bench_mlx  # noqa: E402  (imports nothing heavy at module level)


def test_child_command_keeps_the_options():
    args = argparse.Namespace(
        data_dir="/d", nar="auto", style="s", lyrics="l\\nx", cot="off", seed=7, tf_max_tokens=10, out="/o",
        semantic_max_tokens=300, teacher_forced=False)
    cmd = bench_mlx.child_command(args, "mlx-q8")
    assert cmd[2:4] == ["--engine", "mlx-q8"] and "--no-teacher-forced" in cmd
    assert cmd[cmd.index("--semantic-max-tokens") + 1] == "300" and cmd[cmd.index("--seed") + 1] == "7"


def test_agreement_and_free_running():
    ref = [1, 2, 3, 4]
    cand = {"top1": [1, 2, 9, 4], "top5": [[1], [2], [9, 3], [5]]}
    assert bench_mlx.agreement(ref, cand) == {"positions": 4, "top1": 0.75, "ref_in_top5": 0.75}
    assert bench_mlx.free_running(ref, [1, 2, 0]) == {"identical_prefix": 2, "same_position": 2 / 3, "ref_len": 4, "len": 3}


def test_summary_table(capsys):
    stage = {"seconds": 11.0, "prefill_seconds": 1.0, "output_tokens": 101}
    base = {"label": {}, "load_seconds": 5.0, "e2e_seconds": 60.0, "audio_seconds": 30.0, "nar_seconds": 9.0,
            "vae_seconds": 2.0, "abc": stage, "semantic": stage, "abc_ids": [], "semantic_ids": [1, 2, 3]}
    tf = {"semantic": {"top1": [1, 2, 3], "top5": [[1], [2], [3]]}}
    rows = bench_mlx.summarize({"torch": dict(base, teacher_forced=tf),
                                "mlx-q8": dict(base, semantic_ids=[1, 2, 4], teacher_forced=tf)})
    assert rows[0]["semantic_ms_per_token"] == pytest.approx(100.0)  # (11 - 1) s / 100 decode steps
    assert rows[1]["tf_semantic"]["top1"] == 1.0 and rows[1]["free_running_semantic"]["identical_prefix"] == 2
    bench_mlx.print_table(rows)
    assert "semantic: 100.0% / 100.0% (3 pos)" in capsys.readouterr().out


def test_teacher_forced_torch_vs_mlx_bf16_tiny_model():
    mx = pytest.importorskip("mlx.core")  # noqa: F841
    torch = pytest.importorskip("torch")
    pytest.importorskip("yue2")
    import mlx_ar
    from yue2.modeling_yue2 import YuE2Config, YuE2ForCausalLM
    from yue2.protocol import MUSIC_END, MUSIC_START, VOCAB_SIZE, Sampling
    from yue2.sampling import generate_tokens

    torch.manual_seed(0)
    cfg = YuE2Config(hidden_size=128, num_hidden_layers=2, num_attention_heads=4, num_key_value_heads=2, head_dim=32,
                     intermediate_size=256, vocab_size=VOCAB_SIZE, max_position_embeddings=24576, max_latent_frames=24576)
    model = YuE2ForCausalLM(cfg).eval()
    with torch.no_grad():
        model.lm_head.weight.mul_(40)
    model = model.to(torch.bfloat16)
    prefix = list(range(1000, 1048)) + [MUSIC_START]
    sampling = Sampling(temperature=0.0, min_tokens=0, max_tokens=24)
    with torch.inference_mode():
        tokens, _, truncated = generate_tokens(model, prefix, sampling, 1, "semantic", use_cuda_graph=False)
    end = None if truncated else MUSIC_END
    ref = bench_mlx.teacher_forced(lambda: bench_mlx.TorchStepper(model), prefix, tokens, sampling, "semantic", end=end)
    assert ref["top1"] == tokens + ([end] if end is not None else [])  # greedy: torch ranks its own picks first
    w = mlx_ar.ARWeights.from_model(model, bits=None)
    cand = bench_mlx.teacher_forced(lambda: bench_mlx.MlxStepper(w, "semantic"), prefix, tokens, sampling, "semantic", end=end)
    a = bench_mlx.agreement(ref["top1"], cand)
    assert a["positions"] == len(ref["top1"]) and a["top1"] >= 0.9 and a["ref_in_top5"] == 1.0
