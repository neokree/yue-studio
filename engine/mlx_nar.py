"""YuE2 acoustic flow matching (NAR) velocity in MLX, bf16 weights (NOT quantized).

Apple Silicon only; imported lazily by mlx_pipeline.py.

The NAR path stays bf16 on purpose: public measurements of quantized YuE2 report that the flow-matching path degrades
before the AR path at the same bit width (it accumulates error over the 32 ODE steps), so only the token loop is 8-bit.

Split of work per original chunk (same chunks, noise draw, solver and step count as yue2/nar.py at the pinned commit):
  1. the AR-prefix prefill runs in PyTorch through upstream ``CachedNAR`` (bf16, AR weights unquantized);
  2. its per-layer K/V cache and the NAR-path weights are copied bit-exactly into MLX;
  3. the 2 x steps velocity evaluations of the midpoint solver run in MLX (bf16 activations, fused SDPA).

Design credit: tonywestonuk/YuE-Studio (src/yue2/nar_mlx.py, Apache-2.0) showed this split; this is an independent
implementation; see NOTICE.
"""
from __future__ import annotations

import math

import numpy as np

import mlx.core as mx

from mlx_ar import torch_getter


class NARWeights:
    """NAR-path weights of a loaded YuE2ForCausalLM as bf16 MLX arrays (converted once per loaded model)."""

    def __init__(self, model):
        cfg = model.config
        get = torch_getter(model)
        self.eps, self.theta, self.shift = cfg.rms_norm_eps, cfg.rope_theta, cfg.timestep_shift
        self.H, self.KV, self.HD, self.D = cfg.num_attention_heads, cfg.num_key_value_heads, cfg.head_dim, cfg.hidden_size
        self.max_frames = cfg.max_latent_frames
        self.dtype = mx.bfloat16
        self.vae2llm = (get("vae2llm.weight"), get("vae2llm.bias"))
        self.llm2vae = (get("llm2vae.weight"), get("llm2vae.bias"))
        self.time = (get("time_embedder.mlp.0.weight"), get("time_embedder.mlp.0.bias"),
                     get("time_embedder.mlp.2.weight"), get("time_embedder.mlp.2.bias"))
        self.freq_size = model.time_embedder.frequency_embedding_size
        self.pe = get("latent_pos_embed.pe").astype(self.dtype)  # the module returns pe in the model dtype
        self.final_norm = get("model.norm.weight")
        self.layers = []
        for i in range(cfg.num_hidden_layers):
            p = f"model.layers.{i}."
            layer = {
                "in_norm": get(p + "nar_input_layernorm.weight"),
                "qkv": mx.concatenate([get(p + "nar_self_attn.q_proj.weight"), get(p + "nar_self_attn.k_proj.weight"),
                                       get(p + "nar_self_attn.v_proj.weight")], axis=0),
                "q_norm": get(p + "nar_self_attn.q_norm.weight"), "k_norm": get(p + "nar_self_attn.k_norm.weight"),
                "o": get(p + "nar_self_attn.o_proj.weight"),
                "mlp_norm": get(p + "nar_pre_mlp_layernorm.weight"),
                "gate_up": mx.concatenate([get(p + "nar_mlp.gate_proj.weight"), get(p + "nar_mlp.up_proj.weight")], axis=0),
                "down": get(p + "nar_mlp.down_proj.weight"),
            }
            mx.eval(*layer.values())
            self.layers.append(layer)
        mx.eval(self.pe, self.final_norm, *self.vae2llm, *self.llm2vae, *self.time)

    def nbytes(self):
        return sum(a.nbytes for l in self.layers for a in l.values()) + self.pe.nbytes


def _linear(x, w, b=None):
    y = mx.matmul(x, w.T)
    return y if b is None else y + b


def _rope(x, cos, sin):
    half = x.shape[-1] // 2
    x1, x2 = x[..., :half], x[..., half:]
    return mx.concatenate([x1 * cos - x2 * sin, x2 * cos + x1 * sin], axis=-1)


def _to_mx(t):
    import torch
    t = t.detach()
    if t.dtype == torch.bfloat16:
        return mx.view(mx.array(t.contiguous().view(torch.int16).cpu().numpy()), mx.bfloat16)
    return mx.array(t.float().cpu().numpy())


class Velocity:
    """MLX counterpart of upstream ``CachedNAR.velocity`` for one chunk, from that chunk's PyTorch prefill."""

    def __init__(self, engine, w: NARWeights):
        self.w = w
        self.ar_length, self.nar_length = engine.ar_length, engine.nar_length
        # Prefix K/V per layer (already normalized and rotated): [L0, KV, HD] -> [1, KV, L0, HD]
        self.cache = [(mx.transpose(_to_mx(k), (1, 0, 2))[None], mx.transpose(_to_mx(v), (1, 0, 2))[None])
                      for k, v in engine.cache]
        positions = np.arange(self.ar_length, self.ar_length + self.nar_length, dtype=np.float32)
        inv = 1.0 / (w.theta ** (np.arange(0, w.HD, 2, dtype=np.float32) / w.HD))
        angles = positions[:, None] * inv[None]
        self.cos = mx.array(np.cos(angles)).astype(w.dtype)  # [T, HD/2], cast like RotaryEmbedding + _apply_rotary
        self.sin = mx.array(np.sin(angles)).astype(w.dtype)
        local = np.minimum(np.arange(self.nar_length), w.max_frames - 1)
        self.pos_emb = w.pe[mx.array(local)]
        mx.eval(self.cos, self.sin, self.pos_emb, *[t for kv in self.cache for t in kv])

    def _time_embedding(self, raw_t):
        w = self.w
        t = mx.sigmoid(mx.array(raw_t, dtype=w.dtype))                       # torch: sigmoid on a model-dtype scalar
        t = (w.shift * t / (1 + (w.shift - 1) * t)).astype(w.dtype)
        half = w.freq_size // 2
        freqs = mx.exp(-math.log(10000) * mx.arange(half, dtype=mx.float32) / half)
        args = t.astype(mx.float32) * freqs
        emb = mx.concatenate([mx.cos(args), mx.sin(args)]).astype(w.dtype)[None]
        h = _linear(emb, w.time[0], w.time[1])
        h = h * mx.sigmoid(h)
        return _linear(h, w.time[2], w.time[3])                              # [1, D], broadcast over frames

    def __call__(self, state, raw_t):
        w = self.w
        T = self.nar_length
        x = _linear(mx.pad(state, ((1, 1), (0, 0))), w.vae2llm[0], w.vae2llm[1]) + self._time_embedding(raw_t) + self.pos_emb
        scale = w.HD ** -0.5
        q_end, k_end = w.H * w.HD, (w.H + w.KV) * w.HD
        for layer, (ar_k, ar_v) in zip(w.layers, self.cache):
            h = mx.fast.rms_norm(x, layer["in_norm"], w.eps)
            qkv = _linear(h, layer["qkv"])
            q = mx.fast.rms_norm(qkv[:, :q_end].reshape(T, w.H, w.HD), layer["q_norm"], w.eps)
            k = mx.fast.rms_norm(qkv[:, q_end:k_end].reshape(T, w.KV, w.HD), layer["k_norm"], w.eps)
            v = qkv[:, k_end:].reshape(T, w.KV, w.HD)
            qh = _rope(mx.transpose(q, (1, 0, 2))[None], self.cos, self.sin)
            kh = mx.concatenate([ar_k, _rope(mx.transpose(k, (1, 0, 2))[None], self.cos, self.sin)], axis=2)
            vh = mx.concatenate([ar_v, mx.transpose(v, (1, 0, 2))[None]], axis=2)
            a = mx.fast.scaled_dot_product_attention(qh, kh, vh, scale=scale)   # every frame sees prefix + all frames
            x = x + _linear(mx.transpose(a[0], (1, 0, 2)).reshape(T, w.H * w.HD), layer["o"])
            m = mx.fast.rms_norm(x, layer["mlp_norm"], w.eps)
            g, u = mx.split(_linear(m, layer["gate_up"]), 2, axis=-1)
            x = x + _linear(g * mx.sigmoid(g) * u, layer["down"])
        return _linear(mx.fast.rms_norm(x, w.final_norm, w.eps), w.llm2vae[0], w.llm2vae[1])[1:-1]


def solve(velocity, noise, steps, cancelled=None, on_progress=None):
    """Midpoint solver of upstream ``CachedNAR.solve``; returns CPU fp32 torch [frames, 64]."""
    import torch
    state = _to_mx(noise.to(torch.bfloat16))
    dt = 1.0 / steps
    for step in range(steps):
        if cancelled is not None and cancelled():
            raise InterruptedError("Cancelled during acoustic flow matching")
        t = 1.0 - step * dt
        raw = torch.logit(torch.tensor(t, dtype=torch.float64)).clamp(-20, 20).item()
        mid = state - velocity(state, raw) * (dt / 2)
        raw_mid = torch.logit(torch.tensor(t - dt / 2, dtype=torch.float64)).clamp(-20, 20).item()
        state = state - velocity(mid, raw_mid) * dt
        mx.eval(state)
        if on_progress is not None:
            on_progress(step + 1, int(steps))
    result = torch.from_numpy(np.array(state.astype(mx.float32)))
    if not torch.isfinite(result).all():
        raise FloatingPointError("Acoustic flow matching produced non-finite latents")
    return result


def synthesize(model, weights, prefix, codec, seed, steps=32, context=None, cancelled=None, on_progress=None):
    """Same contract as upstream yue2.nar.synthesize (CPU fp32 [frames, 64] latents), MLX velocity."""
    import torch
    from yue2.nar import CachedNAR, song_chunks
    from yue2.protocol import CONTEXT
    if isinstance(steps, bool) or not isinstance(steps, int) or steps < 1:
        raise ValueError("steps must be a positive integer")
    chunks = song_chunks(prefix, codec, seed, CONTEXT if context is None else context)
    output = []
    for index, chunk in enumerate(chunks):
        if cancelled is not None and cancelled():
            raise InterruptedError("Cancelled before acoustic prefill")
        engine = CachedNAR(model, chunk)
        try:
            velocity = Velocity(engine, weights)
        finally:
            engine.close()  # the MLX copy of the prefix cache is all the solver needs
        progress = None
        if on_progress is not None:
            def progress(completed, total, index=index):
                on_progress(index * total + completed, total * len(chunks))
        output.append(solve(velocity, chunk.noise, steps, cancelled, progress))
        del velocity
    return torch.cat(output, dim=0)
