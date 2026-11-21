#!/usr/bin/env python3
"""Benchmark the YuE2 engines on one Mac: PyTorch (the previous engine) vs MLX 8-bit (and MLX bf16) token generation.

Run it with the app's own yue2 venv, after setup has installed the models (nothing is downloaded here):

  DATA="$HOME/Library/Application Support/YuE2 Studio"
  "$DATA/venvs/yue2/bin/python" tool/bench_mlx.py --data-dir "$DATA" --engines torch,mlx-q8,mlx-bf16 --out /tmp/yue2-bench

Each engine runs in its own process (clean memory, no warm caches shared between engines), one after the other:
  1. load the pipeline (timed), generate one song for a fixed request and seed (abc -> semantic -> 32 NAR steps -> VAE),
     record per-stage seconds, tokens and ms/token, save the tokens and audio.flac;
  2. teacher-forced agreement: feed the torch reference's own tokens back through the engine and record, at every
     position, the token the sampler's distribution ranks first (after the upstream repetition penalty, top-k/top-p
     and the CFG mix): the same positions, the same history, so the engines are compared on identical inputs.
The torch engine runs first and is the reference. Free-running agreement (did the engine sample the same song?) is
reported too, but sampling at temperature 1 diverges for good after the first different token, so it is not a quality
measure; teacher-forced top-1 / top-5 agreement is.

Results: <out>/results.json and a table on stdout. Nothing is measured unless you run it: no numbers are claimed here.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE_DIR = ROOT / "engine"
ENGINES = ("torch", "mlx-q8", "mlx-bf16")
DEFAULT_STYLE = "indie pop, female vocals, warm electric guitar, steady drums, 100 bpm"
DEFAULT_LYRICS = """[verse]
Morning light on the window pane
Coffee cooling while I wait for rain
[chorus]
Hold on, hold on, the day is new
Every road I take leads back to you
"""


# ---------------------------------------------------------------- teacher-forced steppers (one per engine family)

class TorchStepper:
    """Upstream PyTorch path, exactly as yue2.sampling.generate_tokens drives it (StaticKVCache, logits_to_keep=1)."""

    def __init__(self, model):
        self.model = model

    def start(self, ids, budget):
        import torch
        from yue2.modeling_yue2 import StaticKVCache
        c, dev = self.model.config, self.model.model.embed_tokens.weight.device
        self.dev = dev
        cache = StaticKVCache(num_layers=c.num_hidden_layers, batch_size=1, num_kv_heads=c.num_key_value_heads,
                              max_seq_len=len(ids) + budget, head_dim=c.head_dim,
                              dtype=self.model.model.embed_tokens.weight.dtype, device=dev)
        with torch.inference_mode():
            out = self.model(torch.tensor([ids], device=dev), past_key_values=cache, use_cache=True, logits_to_keep=1)
        return _TorchBranch(self.model, cache, dev), out.logits[:, -1, :].cpu()


class _TorchBranch:
    def __init__(self, model, cache, dev):
        self.model, self.cache, self.dev = model, cache, dev

    def step(self, token):
        import torch
        with torch.inference_mode():
            out = self.model(torch.tensor([[token]], device=self.dev), past_key_values=self.cache, use_cache=True,
                             logits_to_keep=1)
        return out.logits[:, -1, :].cpu()


class MlxStepper:
    """engine/mlx_ar.py path: same forward, KV cache and vocabulary window as mlx_ar.generate_tokens."""

    def __init__(self, weights, phase):
        import mlx_ar
        self.w, self.ar = weights, mlx_ar
        self.lo, self.hi = mlx_ar.vocab_window(phase)

    def _logits(self, ids, cache):
        import mlx.core as mx
        import torch
        h = self.ar.forward(self.w, mx.array(ids, dtype=mx.int32), [cache])
        rows = self.w.logits(h, self.lo, self.hi)
        mx.eval(rows, *cache.arrays())
        out = torch.zeros((1, self.w.V), dtype=torch.bfloat16)
        out[:, self.lo:self.hi] = self.ar.to_torch_bf16(rows)
        return out

    def start(self, ids, budget):
        cache = self.ar.KVCache(self.w, len(ids) + budget)
        stepper = self

        class Branch:
            def step(self, token):
                return stepper._logits([[token]], cache)
        return Branch(), self._logits([ids], cache)


def teacher_forced(make_stepper, prefix, tokens, sampling, phase, negative=None, cfg_scale=1.0, legacy_off=False,
                   end=None, limit=None):
    """Feed `tokens` (the reference's sampled tokens, then `end` if it stopped) and return, per position, the sampler
    distribution's top-1 id and top-5 ids given the same history. `make_stepper()` returns a TorchStepper/MlxStepper."""
    from yue2.sampling import distribution
    seq = list(tokens) + ([end] if end is not None else [])
    if limit is not None:
        seq = seq[:limit]
    stepper = make_stepper()
    pos, cond = stepper.start(prefix, len(seq))
    neg = uncond = None
    if cfg_scale != 1.0:
        neg, uncond = stepper.start(negative, len(seq))
    top1, top5 = [], []
    for i, token in enumerate(seq):
        logits = cond if cfg_scale == 1.0 else uncond + cfg_scale * (cond - uncond)  # bf16 mix, as upstream
        scores = distribution(logits, sampling, list(seq[:i]), i, phase, legacy_off)
        five = scores.topk(5, dim=-1).indices[0].tolist()
        top1.append(five[0])
        top5.append(five)
        if i + 1 < len(seq):
            cond = pos.step(token)
            if neg is not None:
                uncond = neg.step(token)
    return {"top1": top1, "top5": top5}


def agreement(ref_top1, cand):
    """Teacher-forced agreement of a candidate engine with the reference engine on the same positions."""
    n = min(len(ref_top1), len(cand["top1"]))
    if n == 0:
        return {"positions": 0, "top1": None, "ref_in_top5": None}
    same = sum(ref_top1[i] == cand["top1"][i] for i in range(n))
    in5 = sum(ref_top1[i] in cand["top5"][i] for i in range(n))
    return {"positions": n, "top1": same / n, "ref_in_top5": in5 / n}


def free_running(ref, cand):
    n = min(len(ref), len(cand))
    prefix = next((i for i in range(n) if ref[i] != cand[i]), n)
    return {"identical_prefix": prefix, "same_position": (sum(ref[i] == cand[i] for i in range(n)) / n) if n else None,
            "ref_len": len(ref), "len": len(cand)}


# ---------------------------------------------------------------- one engine (child process)

def load_pipeline(args):
    os.environ["HF_HOME"] = str(Path(args.data_dir) / "hf")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    sys.path.insert(0, str(ENGINE_DIR))
    import backends
    import modelset
    pins = backends.pinned_revisions(Path(args.data_dir))
    kwargs = dict(vae="m-a-p/YuE2-Vae", device="auto", progress=False, revision=pins.get("m-a-p/YuE2-3B"),
                  vae_revision=pins.get("m-a-p/YuE2-Vae"), cache_dir=str(Path(args.data_dir) / "hf" / "hub"),
                  local_files_only=True)
    nar = args.nar if args.nar != "auto" else ("torch" if args.engine == "torch" else "mlx")
    started = time.perf_counter()
    if args.engine == "torch" and nar == "torch":
        from yue2 import YuE2Pipeline
        pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", **kwargs)
        pipe._load_model()
        label = {"ar": "torch", "nar": "torch", "ar_weights": None}
    else:
        from mlx_pipeline import MlxYuE2Pipeline
        ar = "torch" if args.engine == "torch" else "mlx"
        artifact = modelset.artifact_dir(Path(args.data_dir), backends.AR_ARTIFACT_ID) if args.engine == "mlx-q8" else None
        pipe = MlxYuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", ar_engine=ar, nar_engine=nar, ar_artifact=artifact, **kwargs)
        if args.engine == "mlx-bf16":
            import mlx_ar
            pipe._ar_weights = mlx_ar.ARWeights.from_model(pipe._load_model(), bits=None)
            pipe.ar_source = "load-time-bf16"
        pipe.prepare_mlx()
        label = pipe.engine_label()
    return pipe, label, time.perf_counter() - started


def run_one(args):
    from yue2.protocol import ABC_END, MUSIC_END, CODEC_OFFSET
    from yue2.protocol import negative_prefix, resolve_sampling, token_prefixes
    out = Path(args.out) / args.engine
    out.mkdir(parents=True, exist_ok=True)
    pipe, label, load_seconds = load_pipeline(args)
    request = dict(style=args.style, lyrics=args.lyrics, cot=args.cot, seed=args.seed)
    semantic_sampling = {"max_tokens": args.semantic_max_tokens} if args.semantic_max_tokens else None
    song = pipe(**request, semantic_sampling=semantic_sampling)
    song.save_artifacts(out)
    t = song.timing
    abc_ids = list(song.semantic.plan.abc_ids)
    semantic_ids = [int(x) + CODEC_OFFSET for x in song.semantic.tokens]
    result = {"engine": args.engine, "label": label, "load_seconds": load_seconds, "load": t.get("load"),
              "abc": t.get("abc"), "semantic": t.get("semantic"), "nar_seconds": t.get("nar_seconds"),
              "vae_seconds": t.get("vae_seconds"), "e2e_seconds": t.get("e2e_seconds"),
              "audio_seconds": len(song.audio) / song.sample_rate, "abc_ids": abc_ids, "semantic_ids": semantic_ids,
              "abc_truncated": song.semantic.plan.truncated, "semantic_truncated": song.semantic.truncated}
    if args.teacher_forced:
        ref = json.loads(Path(args.reference).read_text()) if args.reference else result
        r_abc, r_sem = ref["abc_ids"], ref["semantic_ids"]
        plan_request = song.semantic.plan.request
        cfg = pipe.generation_config
        model = pipe._load_model()
        weights = getattr(pipe, "_ar_weights", None)

        def stepper(phase):
            if weights is None:
                return lambda: TorchStepper(model)
            return lambda: MlxStepper(weights, phase)
        tf = {}
        started = time.perf_counter()
        if plan_request.cot != "off" and plan_request.abc is None and r_abc:
            abc_prefix = token_prefixes(plan_request, pipe.tokenizer)
            tf["abc"] = teacher_forced(stepper("abc"), abc_prefix, r_abc, cfg.abc, "abc",
                                       end=None if ref["abc_truncated"] else ABC_END, limit=args.tf_max_tokens)
        prefix = token_prefixes(plan_request, pipe.tokenizer, r_abc)
        guidance = plan_request.guidance
        negative = negative_prefix(plan_request, pipe.tokenizer, r_abc) if guidance != 1 else None
        sampling = resolve_sampling(semantic_sampling, cfg.semantic)
        tf["semantic"] = teacher_forced(stepper("semantic"), prefix, r_sem, sampling, "semantic", negative=negative,
                                        cfg_scale=guidance, legacy_off=plan_request.cot == "off",
                                        end=None if ref["semantic_truncated"] else MUSIC_END, limit=args.tf_max_tokens)
        result["teacher_forced"] = tf
        result["teacher_forced_seconds"] = time.perf_counter() - started
    (out / "result.json").write_text(json.dumps(result), encoding="utf-8")
    print(json.dumps({"engine": args.engine, "done": str(out / "result.json")}), flush=True)


# ---------------------------------------------------------------- orchestration (parent process)

def ms_per_token(stage):
    if not stage or not stage.get("output_tokens"):
        return None
    decode = stage["seconds"] - (stage.get("prefill_seconds") or 0.0)
    return 1000.0 * decode / max(stage["output_tokens"] - 1, 1)


def summarize(results):
    ref = results.get("torch")
    rows = []
    for name, r in results.items():
        row = {"engine": name, "label": r["label"], "load_s": r["load_seconds"], "e2e_s": r["e2e_seconds"],
               "audio_s": r["audio_seconds"], "nar_s": r["nar_seconds"], "vae_s": r["vae_seconds"]}
        for phase in ("abc", "semantic"):
            st = r.get(phase) or {}
            row[f"{phase}_tokens"] = st.get("output_tokens")
            row[f"{phase}_s"] = st.get("seconds")
            row[f"{phase}_ms_per_token"] = ms_per_token(st)
        if ref is not None and name != "torch":
            row["free_running_semantic"] = free_running(ref["semantic_ids"], r["semantic_ids"])
            for phase in ("abc", "semantic"):
                rt, ct = (ref.get("teacher_forced") or {}).get(phase), (r.get("teacher_forced") or {}).get(phase)
                if rt and ct:
                    row[f"tf_{phase}"] = agreement(rt["top1"], ct)
        rows.append(row)
    return rows


def fmt(x, nd=1):
    return "-" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


def print_table(rows):
    print(f"{'engine':10} {'load s':>7} {'abc tok':>7} {'abc ms/t':>8} {'sem tok':>7} {'sem ms/t':>8} {'nar s':>6} "
          f"{'vae s':>6} {'total s':>7}  agreement vs torch (teacher-forced top-1 / ref in top-5)")
    for r in rows:
        agree = "reference" if r["engine"] == "torch" else "  ".join(
            f"{p}: {fmt(100 * a['top1'])}% / {fmt(100 * a['ref_in_top5'])}% ({a['positions']} pos)"
            for p in ("abc", "semantic") if (a := r.get(f"tf_{p}")) and a["positions"])
        print(f"{r['engine']:10} {fmt(r['load_s']):>7} {fmt(r['abc_tokens']):>7} {fmt(r['abc_ms_per_token']):>8} "
              f"{fmt(r['semantic_tokens']):>7} {fmt(r['semantic_ms_per_token']):>8} {fmt(r['nar_s']):>6} "
              f"{fmt(r['vae_s']):>6} {fmt(r['e2e_s']):>7}  {agree}")


def child_command(args, engine):
    cmd = [sys.executable, str(Path(__file__).resolve()), "--engine", engine, "--data-dir", args.data_dir, "--nar", args.nar,
           "--style", args.style, "--lyrics", args.lyrics, "--cot", args.cot, "--seed", str(args.seed),
           "--tf-max-tokens", str(args.tf_max_tokens), "--out", args.out]
    if args.semantic_max_tokens:
        cmd += ["--semantic-max-tokens", str(args.semantic_max_tokens)]
    if not args.teacher_forced:
        cmd.append("--no-teacher-forced")
    return cmd


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--data-dir", default=str(Path.home() / "Library" / "Application Support" / "YuE2 Studio"))
    p.add_argument("--engines", default="torch,mlx-q8", help=f"comma list of {', '.join(ENGINES)}; torch is the reference")
    p.add_argument("--nar", choices=("auto", "torch", "mlx"), default="auto",
                   help="acoustic stage engine: auto = torch for torch, MLX bf16 for MLX engines (what the app does)")
    p.add_argument("--style", default=DEFAULT_STYLE)
    p.add_argument("--lyrics", default=DEFAULT_LYRICS)
    p.add_argument("--cot", choices=("off", "melody", "full"), default="full")
    p.add_argument("--seed", type=int, default=831001)
    p.add_argument("--semantic-max-tokens", type=int, default=None,
                   help="cap the semantic budget for a quicker run (default: the upstream default, unchanged)")
    p.add_argument("--no-teacher-forced", dest="teacher_forced", action="store_false")
    p.add_argument("--tf-max-tokens", type=int, default=1500, help="positions per phase in the teacher-forced pass")
    p.add_argument("--out", default="yue2-bench")
    p.add_argument("--engine", help=argparse.SUPPRESS)  # child mode
    p.add_argument("--reference", help=argparse.SUPPRESS)
    args = p.parse_args(argv)
    if args.engine:
        return run_one(args)
    engines = [e.strip() for e in args.engines.split(",") if e.strip()]
    if unknown := [e for e in engines if e not in ENGINES]:
        p.error(f"unknown engine(s): {', '.join(unknown)}")
    engines.sort(key=lambda e: e != "torch")  # the reference first
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    results = {}
    for engine in engines:
        cmd = child_command(args, engine)
        ref = out / "torch" / "result.json"
        if engine != "torch" and ref.exists() and "torch" in engines:
            cmd += ["--reference", str(ref)]
        print(f"== {engine}", flush=True)
        started = time.perf_counter()
        subprocess.run(cmd, check=True)
        results[engine] = json.loads((out / engine / "result.json").read_text())
        print(f"   {engine} done in {time.perf_counter() - started:.0f} s (process wall time)", flush=True)
    rows = summarize(results)
    (out / "results.json").write_text(json.dumps({"args": vars(args), "summary": rows}, indent=2), encoding="utf-8")
    print_table(rows)
    print(f"\nfull results: {out / 'results.json'}; songs: {out}/<engine>/audio.flac")


if __name__ == "__main__":
    main()
