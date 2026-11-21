#!/usr/bin/env python3
"""Convert the official YuE2-3B checkpoint into the cached 8-bit MLX AR weights (recipe "yue2-ar-mlx-q8", v1).

  mlx_convert.py --src <YuE2-3B snapshot dir> --out <dir>

Input: model.safetensors + config.json from m-a-p/YuE2-3B at the pinned revision (the source of truth; no third-party
weights). Output dir: weights.safetensors (AR path only: quantized matrices as .q/.scales/.biases triples, norms bf16)
and config.json (format, recipe version, quantization parameters, model dims). Deterministic: the same input and recipe
give the same arrays as quantizing at load time from the PyTorch model (engine/tests/test_mlx_parity.py checks it).
Needs mlx only (no torch): MLX reads bf16 safetensors directly. Called by modelset.py as a "derived" artifact recipe.
"""
import argparse
import json
from pathlib import Path

FORMAT, RECIPE_VERSION = "yue2-ar-mlx-q8", 1
MODEL_KEYS = ("hidden_size", "num_hidden_layers", "num_attention_heads", "num_key_value_heads", "head_dim",
              "intermediate_size", "vocab_size", "rms_norm_eps", "rope_theta")


def expected_shapes(cfg):
    """{flat name: shape} of the artifact, from the model config (used by check)."""
    import mlx_ar
    D, H, KV, HD, I, V = (cfg[k] for k in ("hidden_size", "num_attention_heads", "num_key_value_heads", "head_dim",
                                           "intermediate_size", "vocab_size"))
    full = {"embed": (V, D), "final_norm": (D,), "head": (V, D)}
    for i in range(cfg["num_hidden_layers"]):
        full.update({f"layers.{i}.in_norm": (D,), f"layers.{i}.q_norm": (HD,), f"layers.{i}.k_norm": (HD,),
                     f"layers.{i}.mlp_norm": (D,), f"layers.{i}.qkv": ((H + 2 * KV) * HD, D),
                     f"layers.{i}.o": (D, H * HD), f"layers.{i}.gate_up": (2 * I, D), f"layers.{i}.down": (D, I)})
    shapes = {}
    for name, shape in full.items():
        if mlx_ar.is_quantized_name(name):
            rows, cols = shape
            per_word = 32 // mlx_ar.BITS
            shapes[name + ".q"] = (rows, cols // per_word)
            shapes[name + ".scales"] = shapes[name + ".biases"] = (rows, cols // mlx_ar.GROUP_SIZE)
        else:
            shapes[name] = shape
    return shapes


def estimated_bytes(cfg):
    """Array bytes of the artifact for a model config (uint32-packed weights, bf16 scales/biases/norms)."""
    total = 0
    for name, shape in expected_shapes(cfg).items():
        n = 1
        for d in shape:
            n *= d
        total += n * (4 if name.endswith(".q") else 2)
    return total


def convert(src, out):
    import mlx.core as mx
    import mlx_ar
    src, out = Path(src), Path(out)
    cfg_all = json.loads((src / "config.json").read_text(encoding="utf-8"))
    cfg = {k: cfg_all[k] for k in MODEL_KEYS}
    shards = sorted(src.glob("model*.safetensors"))
    if not shards:
        raise FileNotFoundError(f"no model*.safetensors in {src}")
    tensors = {}
    for shard in shards:
        tensors.update(mx.load(str(shard)))  # lazy: a tensor is read when first evaluated

    def get(name):
        a = tensors[name]
        return a if a.dtype == mx.bfloat16 else a.astype(mx.bfloat16)

    flat = mlx_ar.quantize_flat(mlx_ar.ar_tensors(get, cfg["num_hidden_layers"]))
    out.mkdir(parents=True, exist_ok=True)
    meta = {"format": FORMAT, "recipe_version": RECIPE_VERSION, "bits": mlx_ar.BITS, "group_size": mlx_ar.GROUP_SIZE,
            "mode": mlx_ar.MODE, "model": cfg}
    mx.save_safetensors(str(out / "weights.safetensors"), flat, metadata={"format": FORMAT})
    (out / "config.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return out


def check(out):
    """Structural check of a converted dir: format, recipe version, every expected array with its shape. Raises."""
    import mlx.core as mx
    out = Path(out)
    meta = json.loads((out / "config.json").read_text(encoding="utf-8"))
    if meta.get("format") != FORMAT or meta.get("recipe_version") != RECIPE_VERSION:
        raise ValueError(f"unexpected artifact format {meta.get('format')} v{meta.get('recipe_version')}")
    arrays = mx.load(str(out / "weights.safetensors"))
    want = expected_shapes(meta["model"])
    if set(arrays) != set(want):
        raise ValueError(f"artifact arrays differ: missing {sorted(set(want) - set(arrays))[:3]}, extra {sorted(set(arrays) - set(want))[:3]}")
    for name, shape in want.items():
        if tuple(arrays[name].shape) != tuple(shape):
            raise ValueError(f"{name}: shape {tuple(arrays[name].shape)} != {shape}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    convert(args.src, args.out)
    check(args.out)
    print(json.dumps({"type": "done", "out": args.out}))


if __name__ == "__main__":
    main()
