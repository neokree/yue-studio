"""YuE2Pipeline with MLX token generation (8-bit) and MLX acoustic velocity (bf16). Apple Silicon only.

Imported lazily by backends.Yue2Backend when engine selection picked MLX; it imports yue2 (torch) and mlx.
Only two upstream methods are overridden, both with the upstream contract (yue2/pipeline.py at the pinned commit):
  _generate(prefix, sampling, seed, phase, **kwargs) -> (ids, timing, truncated)   abc + semantic tokens
  synthesize(semantic, cancelled, on_progress) -> np.ndarray latents                acoustic flow matching
Everything else (prompting, plans, VAE decode, artifacts) is the upstream pipeline, unchanged. The PyTorch model stays
loaded: the acoustic prefill and the VAE use it.

Memory (both engines MLX): the PyTorch model is kept "lean", without the per-layer acoustic (NAR) modules, which only
the MLX velocity needs and which already live in MLX (about 2.9 GB less); and the 8-bit token weights are dropped while
the acoustic stage runs, then read back from the cached artifact (0.4 s) for the next song (2.3 GB less at the peak).
Same weights, same bits: only where they are held changes. Design credit for both ideas: tonywestonuk/YuE-Studio
(src/yue2/lean.py, tools/yue2_worker.py trim_gpu_memory); independent implementation, see NOTICE.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

from yue2 import YuE2Pipeline


# The acoustic half of every DecoderLayer (yue2/modeling_yue2.py at the pinned commit).
NAR_MODULES = ("nar_input_layernorm", "nar_self_attn", "nar_pre_mlp_layernorm", "nar_mlp")


def log(msg):
    print(f"[mlx] {msg}", file=sys.stderr, flush=True)


class MlxYuE2Pipeline(YuE2Pipeline):
    def __init__(self, *args, ar_engine="mlx", nar_engine="mlx", ar_artifact=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.ar_engine, self.nar_engine = ar_engine, nar_engine
        self.ar_artifact = Path(ar_artifact) if ar_artifact else None
        self._ar_weights = self._nar_weights = None
        self.ar_source = None  # "artifact" | "load-time" once prepared
        self._ar_label = "torch"
        # Lean only when PyTorch runs neither the token loop nor the velocity: the PyTorch fallback needs the full model.
        self.lean = ar_engine == "mlx" and nar_engine == "mlx"

    def _load_model(self, for_nar=False):
        """Upstream load, except that a lean model gives its acoustic modules to MLX and drops them before it moves to
        the GPU. Upstream then finds ``_model`` set and only moves it."""
        if self._model is None and self.lean:
            import torch
            from yue2.modeling_yue2 import YuE2ForCausalLM
            start = time.perf_counter()
            model = YuE2ForCausalLM.from_pretrained(self.model_dir, local_files_only=True,  # same call as upstream
                                                    torch_dtype=torch.bfloat16, low_cpu_mem_usage=True).eval()
            self._build_nar(model)
            strip_nar(model)
            self._model = model
            self.load_timing["mot_load_seconds"] = time.perf_counter() - start
        return super()._load_model(for_nar)

    def _build_nar(self, model):
        import mlx_nar
        started = time.perf_counter()
        self._nar_weights = mlx_nar.NARWeights(model)
        self.load_timing["mlx_nar_seconds"] = time.perf_counter() - started
        log(f"NAR weights bf16: {self._nar_weights.nbytes() / 1e9:.2f} GB in {time.perf_counter() - started:.1f} s")

    def _load_ar(self):
        """8-bit token weights: cached artifact first; quantize from the loaded model as the fallback."""
        import mlx_ar
        started = time.perf_counter()
        weights = None
        if self.ar_artifact is not None:
            try:
                weights = mlx_ar.ARWeights.from_artifact(self.ar_artifact)
                self.ar_source = "artifact"
            except Exception as exc:  # broken or missing artifact: same weights, built from the loaded model
                log(f"cached 8-bit weights unusable ({type(exc).__name__}: {exc}); quantizing at load time")
        if weights is None:
            weights = mlx_ar.ARWeights.from_model(self._load_model())
            self.ar_source = "load-time"
        self._ar_weights = weights
        self._ar_label = "mlx-q8" if weights.quantized else "mlx-bf16"
        self.load_timing["mlx_ar_seconds"] = time.perf_counter() - started
        log(f"AR weights 8-bit ({self.ar_source}): {weights.nbytes() / 1e9:.2f} GB in {time.perf_counter() - started:.1f} s")

    def prepare_mlx(self):
        """Build the MLX weights and load the PyTorch model, so that stage `load` is the whole load."""
        model = self._load_model()
        if self.ar_engine == "mlx" and self._ar_weights is None:
            self._load_ar()
        if self.nar_engine == "mlx" and self._nar_weights is None:  # not lean: the model keeps its acoustic modules
            self._build_nar(model)

    def engine_label(self):
        return {"ar": self._ar_label, "nar": "mlx-bf16" if self._nar_weights is not None else "torch",
                "ar_weights": self.ar_source}

    def _generate(self, prefix, sampling, seed, phase, **kwargs):
        if self.ar_engine != "mlx":
            return super()._generate(prefix, sampling, seed, phase, **kwargs)
        if self._ar_weights is None:  # dropped by the acoustic stage of the previous song
            self._load_ar()
        import mlx_ar
        callback = kwargs.pop("on_token", None)
        return mlx_ar.generate_tokens(self._ar_weights, prefix, sampling, seed, phase, on_token=callback, **kwargs)

    def synthesize(self, semantic, *, cancelled=None, on_progress=None):
        if self._nar_weights is None:
            return super().synthesize(semantic, cancelled=cancelled, on_progress=on_progress)
        import mlx_nar
        from yue2.pipeline import SemanticResult
        from yue2.protocol import token_prefixes
        if not isinstance(semantic, SemanticResult):
            raise TypeError("Pass the SemanticResult returned by generate_semantic()")
        if token_prefixes(semantic.plan.request, self.tokenizer, semantic.plan.abc_ids) != semantic.plan.prefix:
            raise ValueError("Semantic result does not retain the request's exact prefix")
        model = self._load_model(for_nar=True)
        if self.ar_source == "artifact":  # the token loop is over: its weights come back from disk in 0.4 s
            import mlx.core as mx
            self._ar_weights = None
            mx.clear_cache()
        result = mlx_nar.synthesize(model, self._nar_weights, semantic.plan.prefix, semantic.tokens,
                                    semantic.plan.request.seed, steps=self.generation_config.ode_steps,
                                    context=self.generation_config.context, cancelled=cancelled, on_progress=on_progress)
        return result.detach().float().cpu().numpy()

    def close(self):
        self._ar_weights = self._nar_weights = None
        super().close()


def strip_nar(model):
    """Remove the acoustic modules of every layer (the MLX copy is the only user). The AR path, which the acoustic
    prefill runs in PyTorch, is untouched; a PyTorch acoustic forward on a stripped model fails with AttributeError."""
    for layer in model.model.layers:
        for name in NAR_MODULES:
            delattr(layer, name)
