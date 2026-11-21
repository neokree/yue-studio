"""YuE2Pipeline with MLX token generation (8-bit) and MLX acoustic velocity (bf16). Apple Silicon only.

Imported lazily by backends.Yue2Backend when engine selection picked MLX; it imports yue2 (torch) and mlx.
Only two upstream methods are overridden, both with the upstream contract (yue2/pipeline.py at the pinned commit):
  _generate(prefix, sampling, seed, phase, **kwargs) -> (ids, timing, truncated)   abc + semantic tokens
  synthesize(semantic, cancelled, on_progress) -> np.ndarray latents                acoustic flow matching
Everything else (prompting, plans, VAE decode, artifacts) is the upstream pipeline, unchanged. The PyTorch model stays
loaded: the acoustic prefill, the VAE and the fallback use it.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

from yue2 import YuE2Pipeline


def log(msg):
    print(f"[mlx] {msg}", file=sys.stderr, flush=True)


class MlxYuE2Pipeline(YuE2Pipeline):
    def __init__(self, *args, ar_engine="mlx", nar_engine="mlx", ar_artifact=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.ar_engine, self.nar_engine = ar_engine, nar_engine
        self.ar_artifact = Path(ar_artifact) if ar_artifact else None
        self._ar_weights = self._nar_weights = None
        self.ar_source = None  # "artifact" | "load-time" once prepared

    def prepare_mlx(self):
        """Build the MLX weights (after _load_model). Cached artifact first; quantize at load as the fallback."""
        model = self._load_model()
        if self.ar_engine == "mlx" and self._ar_weights is None:
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
                weights = mlx_ar.ARWeights.from_model(model)
                self.ar_source = "load-time"
            self._ar_weights = weights
            self.load_timing["mlx_ar_seconds"] = time.perf_counter() - started
            log(f"AR weights 8-bit ({self.ar_source}): {weights.nbytes() / 1e9:.2f} GB in {time.perf_counter() - started:.1f} s")
        if self.nar_engine == "mlx" and self._nar_weights is None:
            import mlx_nar
            started = time.perf_counter()
            self._nar_weights = mlx_nar.NARWeights(model)
            self.load_timing["mlx_nar_seconds"] = time.perf_counter() - started
            log(f"NAR weights bf16: {self._nar_weights.nbytes() / 1e9:.2f} GB in {time.perf_counter() - started:.1f} s")

    def engine_label(self):
        ar = ("mlx-q8" if self._ar_weights.quantized else "mlx-bf16") if self._ar_weights is not None else "torch"
        return {"ar": ar, "nar": "mlx-bf16" if self._nar_weights is not None else "torch", "ar_weights": self.ar_source}

    def _generate(self, prefix, sampling, seed, phase, **kwargs):
        if self._ar_weights is None:
            return super()._generate(prefix, sampling, seed, phase, **kwargs)
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
        result = mlx_nar.synthesize(model, self._nar_weights, semantic.plan.prefix, semantic.tokens,
                                    semantic.plan.request.seed, steps=self.generation_config.ode_steps,
                                    context=self.generation_config.context, cancelled=cancelled, on_progress=on_progress)
        return result.detach().float().cpu().numpy()

    def close(self):
        self._ar_weights = self._nar_weights = None
        super().close()
