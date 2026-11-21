"""YuE2 autoregressive token generation (abc + semantic) in MLX with 8-bit weights.

Apple Silicon only; imported lazily by mlx_pipeline.py, never by the fake engine or the tests' default layer.

What is quantized: the AR path's matrices (token embedding, fused Q/K/V, O, fused gate/up, down, lm_head), MLX affine
quantization, 8 bits, group size 64 (a 16-bit scale and bias per 64 weights). RMSNorm weights and the rotary tables stay
in bf16/fp32; activations, KV cache and logits stay bf16 like the PyTorch path. The NAR (acoustic) path is never
quantized (see mlx_nar.py).

Sampling is NOT reimplemented: logits go back to PyTorch (CPU) and the upstream yue2.sampling.distribution plus a CPU
torch.Generator seeded like upstream pick the token, so seeds, top-k/top-p, repetition penalty and CFG arithmetic follow
the reference generate_tokens (yue2/sampling.py at the pinned commit). Only the transformer forward pass moves to MLX.

Design credit: the approach (8-bit MLX weights for the bandwidth-bound token loop, fused projections, logits for the
selectable vocabulary rows only) follows tonywestonuk/YuE-Studio (src/yue2/ar_mlx.py, Apache-2.0). This file is an
independent implementation for neokree/yue-studio; see NOTICE.
"""
from __future__ import annotations

import time

import numpy as np

import mlx.core as mx

GROUP_SIZE, BITS, MODE = 64, 8, "affine"
QUANTIZED = ("embed", "qkv", "o", "gate_up", "down", "head")  # per-layer: qkv, o, gate_up, down


def quantize(w):
    """(wq, scales, biases) of a [out, in] matrix; rows stay independent, so row slices remain valid."""
    return tuple(mx.quantize(w, group_size=GROUP_SIZE, bits=BITS, mode=MODE))


def qmatmul(x, q):
    wq, scales, biases = q
    return mx.quantized_matmul(x, wq, scales, biases, transpose=True, group_size=GROUP_SIZE, bits=BITS, mode=MODE)


# ---------------------------------------------------------------- weights

def ar_tensors(get, num_layers):
    """Fused AR-path tensors (bf16, unquantized) from a getter over checkpoint names (HF module paths)."""
    out = {"embed": get("model.embed_tokens.weight"), "final_norm": get("model.norm.weight"), "head": get("lm_head.weight")}
    for i in range(num_layers):
        p = f"model.layers.{i}."
        out[f"layers.{i}.in_norm"] = get(p + "input_layernorm.weight")
        out[f"layers.{i}.q_norm"] = get(p + "self_attn.q_norm.weight")
        out[f"layers.{i}.k_norm"] = get(p + "self_attn.k_norm.weight")
        out[f"layers.{i}.mlp_norm"] = get(p + "post_attention_layernorm.weight")
        out[f"layers.{i}.qkv"] = mx.concatenate(
            [get(p + "self_attn.q_proj.weight"), get(p + "self_attn.k_proj.weight"), get(p + "self_attn.v_proj.weight")], axis=0)
        out[f"layers.{i}.o"] = get(p + "self_attn.o_proj.weight")
        out[f"layers.{i}.gate_up"] = mx.concatenate([get(p + "mlp.gate_proj.weight"), get(p + "mlp.up_proj.weight")], axis=0)
        out[f"layers.{i}.down"] = get(p + "mlp.down_proj.weight")
    return out


def is_quantized_name(name):
    return name.rsplit(".", 1)[-1] in QUANTIZED


def quantize_flat(tensors):
    """{name: array} -> flat {name.q|.scales|.biases: array} for quantized matrices, {name: array} for the rest."""
    flat = {}
    for name, w in tensors.items():
        if is_quantized_name(name):
            wq, s, b = quantize(w)
            flat[name + ".q"], flat[name + ".scales"], flat[name + ".biases"] = wq, s, b
        else:
            flat[name] = w
        mx.eval(*[v for k, v in flat.items() if k.startswith(name)])
    return flat


def torch_getter(model):
    """Checkpoint-name getter over a loaded YuE2ForCausalLM (bf16 copied bit-exactly into MLX)."""
    import torch
    state = model.state_dict()

    def get(name):
        t = state[name].detach()
        if t.dtype == torch.bfloat16:
            return mx.view(mx.array(t.contiguous().view(torch.int16).cpu().numpy()), mx.bfloat16)
        return mx.array(t.float().cpu().numpy())
    return get


class ARWeights:
    """The AR path as MLX arrays. ``flat`` holds quantized triples (name.q/.scales/.biases) or plain bf16 arrays."""

    def __init__(self, flat, config):
        self.flat = flat
        self.H, self.KV, self.HD = config["num_attention_heads"], config["num_key_value_heads"], config["head_dim"]
        self.D, self.V, self.L = config["hidden_size"], config["vocab_size"], config["num_hidden_layers"]
        self.eps, self.theta = config["rms_norm_eps"], config["rope_theta"]
        self.quantized = "embed.q" in flat
        self.dtype = mx.bfloat16
        self.layers = [{k: self._get(f"layers.{i}.{k}") for k in ("in_norm", "q_norm", "k_norm", "mlp_norm", "qkv", "o", "gate_up", "down")}
                       for i in range(self.L)]
        self.embed, self.head, self.final_norm = self._get("embed"), self._get("head"), self._get("final_norm")
        inv = 1.0 / (self.theta ** (np.arange(0, self.HD, 2, dtype=np.float32) / self.HD))
        self.inv_freq = inv

    def _get(self, name):
        if name + ".q" in self.flat:
            return (self.flat[name + ".q"], self.flat[name + ".scales"], self.flat[name + ".biases"])
        return self.flat[name]

    @classmethod
    def from_model(cls, model, bits=BITS):
        """Quantize at load time from the PyTorch model already in memory (fallback when no cached artifact exists)."""
        cfg = config_dict(model.config)
        tensors = ar_tensors(torch_getter(model), cfg["num_hidden_layers"])
        flat = quantize_flat(tensors) if bits else {k: v for k, v in tensors.items()}
        if not bits:
            mx.eval(*flat.values())
        return cls(flat, cfg)

    @classmethod
    def from_artifact(cls, path):
        """Load the pre-quantized artifact written by mlx_convert.py (mmap'd safetensors + config)."""
        import json
        from pathlib import Path
        path = Path(path)
        cfg = json.loads((path / "config.json").read_text(encoding="utf-8"))
        flat = mx.load(str(path / "weights.safetensors"))
        mx.eval(*flat.values())
        return cls(flat, cfg["model"])

    def nbytes(self):
        return sum(v.nbytes for v in self.flat.values())

    def linear(self, x, w):
        return qmatmul(x, w) if isinstance(w, tuple) else mx.matmul(x, w.T)

    def embedding(self, ids):
        if not isinstance(self.embed, tuple):
            return self.embed[ids]
        wq, s, b = self.embed
        flat = ids.reshape(-1)
        rows = mx.dequantize(wq[flat], s[flat], b[flat], group_size=GROUP_SIZE, bits=BITS, mode=MODE)
        return rows.reshape(*ids.shape, self.D).astype(self.dtype)

    def logits(self, h, lo, hi):
        """Logits for vocabulary rows [lo, hi) only: the sampler masks every other row to -inf anyway."""
        if isinstance(self.head, tuple):
            wq, s, b = self.head
            return qmatmul(h, (wq[lo:hi], s[lo:hi], b[lo:hi]))
        return mx.matmul(h, self.head[lo:hi].T)

    def rotary(self, start, length):
        """cos/sin [length, HD/2] in bf16, like RotaryEmbedding (fp32 angles, cast to the activation dtype)."""
        angles = np.arange(start, start + length, dtype=np.float32)[:, None] * self.inv_freq[None]
        return mx.array(np.cos(angles)).astype(self.dtype), mx.array(np.sin(angles)).astype(self.dtype)


def config_dict(config):
    keys = ("hidden_size", "num_hidden_layers", "num_attention_heads", "num_key_value_heads", "head_dim",
            "intermediate_size", "vocab_size", "rms_norm_eps", "rope_theta")
    return {k: getattr(config, k) for k in keys}


# ---------------------------------------------------------------- forward

class KVCache:
    """One row's per-layer K/V, preallocated to prefix + generation budget: [1, KV, capacity, HD]."""

    def __init__(self, w, capacity):
        self.k = [mx.zeros((1, w.KV, capacity, w.HD), dtype=w.dtype) for _ in range(w.L)]
        self.v = [mx.zeros((1, w.KV, capacity, w.HD), dtype=w.dtype) for _ in range(w.L)]
        self.offset = 0

    def arrays(self):
        return self.k + self.v


def _rope(x, cos, sin):
    """x [1, heads, T, HD]; cos/sin [T, HD/2]: the model's rotate-half convention, in the activation dtype."""
    half = x.shape[-1] // 2
    x1, x2 = x[..., :half], x[..., half:]
    return mx.concatenate([x1 * cos - x2 * sin, x2 * cos + x1 * sin], axis=-1)


def forward(w, ids, caches):
    """One step for B rows of equal length T. ids [B, T] (int32); caches: B KVCache (each row attends to its own).

    Returns the last position's final-norm hidden state [B, D]. Linear layers run on the whole batch (one weight read
    for all rows: this is what makes CFG's second branch cheap); attention runs per row on its own cache.
    """
    B, T = ids.shape
    x = w.embedding(ids)
    ropes = [w.rotary(c.offset, T) for c in caches]
    q_end, k_end = w.H * w.HD, (w.H + w.KV) * w.HD
    scale = w.HD ** -0.5
    for i, layer in enumerate(w.layers):
        h = mx.fast.rms_norm(x, layer["in_norm"], w.eps)
        qkv = w.linear(h, layer["qkv"])
        q = mx.fast.rms_norm(qkv[..., :q_end].reshape(B, T, w.H, w.HD), layer["q_norm"], w.eps)
        k = mx.fast.rms_norm(qkv[..., q_end:k_end].reshape(B, T, w.KV, w.HD), layer["k_norm"], w.eps)
        v = qkv[..., k_end:].reshape(B, T, w.KV, w.HD)
        outs = []
        for r, cache in enumerate(caches):
            cos, sin = ropes[r]
            qr = _rope(mx.transpose(q[r:r + 1], (0, 2, 1, 3)), cos, sin)
            kr = _rope(mx.transpose(k[r:r + 1], (0, 2, 1, 3)), cos, sin)
            vr = mx.transpose(v[r:r + 1], (0, 2, 1, 3))
            end = cache.offset + T
            cache.k[i][..., cache.offset:end, :] = kr
            cache.v[i][..., cache.offset:end, :] = vr
            keys, values = cache.k[i][..., :end, :], cache.v[i][..., :end, :]
            mask = "causal" if T > 1 else None  # prefill starts at offset 0; decode (T=1) sees every cached key
            a = mx.fast.scaled_dot_product_attention(qr, keys, values, scale=scale, mask=mask)
            outs.append(mx.transpose(a, (0, 2, 1, 3)).reshape(1, T, w.H * w.HD))
        x = x + w.linear(outs[0] if B == 1 else mx.concatenate(outs, axis=0), layer["o"])
        m = mx.fast.rms_norm(x, layer["mlp_norm"], w.eps)
        g, u = mx.split(w.linear(m, layer["gate_up"]), 2, axis=-1)
        x = x + w.linear(g * mx.sigmoid(g) * u, layer["down"])
    for c in caches:
        c.offset += T
    return mx.fast.rms_norm(x[:, -1], w.final_norm, w.eps)


def to_torch_bf16(a):
    """MLX bf16 [B, n] -> torch bf16 CPU tensor, bit-exact (numpy has no bf16: go through int16)."""
    import torch
    return torch.from_numpy(np.array(mx.view(a.astype(mx.bfloat16), mx.int16))).view(torch.bfloat16)


def vocab_window(phase):
    """[lo, hi) rows the sampler can ever select in this phase (distribution() masks the rest to -inf)."""
    from yue2.protocol import ABC_END, CODEC_OFFSET, CODEC_SIZE, EOD, MUSIC_END
    if phase == "abc":
        return 0, max(EOD, ABC_END + 1)
    return min(CODEC_OFFSET, MUSIC_END), max(CODEC_OFFSET + CODEC_SIZE, MUSIC_END + 1)


# ---------------------------------------------------------------- generation (mirrors yue2.sampling.generate_tokens)

def generate_tokens(w, prefix, sampling, seed, phase, negative=None, cfg_scale=1.0, legacy_off=False,
                    cancelled=None, on_token=None):
    import torch
    from yue2.protocol import ABC_END, CONTEXT, MUSIC_END
    from yue2.sampling import distribution
    if len(prefix) + sampling.max_tokens > CONTEXT:
        raise ValueError("Prefix + requested generation budget exceeds 24576; no implicit truncation")
    if cfg_scale != 1 and negative is None:
        raise ValueError("CFG requires a negative prefix")
    if negative is not None and len(negative) + sampling.max_tokens > CONTEXT:
        raise ValueError("Negative prefix + generation budget exceeds context")
    if cancelled is not None and cancelled():
        raise InterruptedError("Cancelled before prefill")
    generator = torch.Generator(device="cpu").manual_seed(seed)  # upstream samples on CPU on MPS too: same RNG stream
    lo, hi = vocab_window(phase)
    use_cfg = cfg_scale != 1.0

    def full(rows):  # [B, hi-lo] -> [B, V] bf16 with zeros outside the window (CFG-safe; distribution masks them)
        out = torch.zeros((rows.shape[0], w.V), dtype=torch.bfloat16)
        out[:, lo:hi] = to_torch_bf16(rows)
        return out

    def step_logits(ids, caches):
        h = forward(w, ids, caches)
        rows = w.logits(h, lo, hi)
        mx.eval(rows, *[a for c in caches for a in c.arrays()])
        return full(rows)

    start = time.perf_counter()
    positive = KVCache(w, len(prefix) + sampling.max_tokens)
    caches = [positive]
    conditional = step_logits(mx.array([prefix], dtype=mx.int32), [positive])[:1]
    unconditional = None
    if use_cfg:
        negative_cache = KVCache(w, len(negative) + sampling.max_tokens)
        caches.append(negative_cache)
        unconditional = step_logits(mx.array([negative], dtype=mx.int32), [negative_cache])[:1]
    prefill_seconds = time.perf_counter() - start
    history, first, eos = [], None, False
    end = ABC_END if phase == "abc" else MUSIC_END
    for step in range(sampling.max_tokens):
        if cancelled is not None and cancelled():
            raise InterruptedError(f"Cancelled during {phase}")
        logits = conditional if not use_cfg else unconditional + cfg_scale * (conditional - unconditional)
        scores = distribution(logits, sampling, history, step, phase, legacy_off)
        if sampling.temperature == 0:
            if not torch.isfinite(scores.max()).item():
                raise FloatingPointError("Greedy decoding requires finite selectable logits")
            next_id = scores.argmax(-1, keepdim=True)
        else:
            next_id = torch.multinomial(scores.softmax(-1), 1, generator=generator)
        token = int(next_id.item())
        if first is None:
            first = time.perf_counter() - start
        if on_token is not None:
            on_token(phase, token)
        if token == end:
            eos = True
            break
        history.append(token)
        if step + 1 < sampling.max_tokens:
            both = step_logits(mx.array([[token]] * len(caches), dtype=mx.int32), caches)
            conditional = both[:1]
            unconditional = both[1:] if use_cfg else None
    seconds = time.perf_counter() - start
    count = len(history) + int(eos)
    timing = {"seconds": seconds, "prefill_seconds": prefill_seconds, "ttft_seconds": first, "output_tokens": count,
              "content_tokens": len(history), "output_tps": count / seconds if seconds else 0.0,
              "prefix_tokens": len(prefix), "cfg_branches": 2 if use_cfg else 1,
              "execution": "mlx-q8" if w.quantized else "mlx-bf16", "attention": "mlx-sdpa"}
    return history, timing, not eos
