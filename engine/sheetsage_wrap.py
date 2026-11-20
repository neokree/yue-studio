"""SheetSage2 without the ffmpeg CLI: decode with soundfile, pass the waveform array.

python sheetsage_wrap.py <audio> --model-dir <dir> --output <dir> [--melody-only] [--device mps]

Runs inside the SheetSage2 venv (torch 2.8.0, transformers 4.45.2, soundfile).
SheetSage2's load_audio() only shells out to ffmpeg for path/bytes input; a
waveform + sampling_rate takes the pure-torch path (mono mix + torchaudio resample).
Offline: HF_HUB_OFFLINE=1 and local_files_only (MERT loads from the HF cache at the revision SheetSage2's config pins).
Writes <output>/score.abc like infer.py. Exit 1 + message on stderr on failure.
"""
import argparse
import os
import sys
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"  # setup already fetched SheetSage2 and the pinned MERT snapshot: never hit the network here


def main():
    p = argparse.ArgumentParser(description="SheetSage2 transcription (soundfile decode, no ffmpeg)")
    p.add_argument("audio", type=Path)
    p.add_argument("--model-dir", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--melody-only", action="store_true")
    p.add_argument("--device", default="auto", help="auto|cpu|mps|cuda")
    p.add_argument("--dtype", choices=("bf16", "fp32"), default="bf16")
    p.add_argument("--max-seconds", type=float)
    a = p.parse_args()

    import soundfile as sf
    try:
        data, sr = sf.read(str(a.audio), dtype="float32", always_2d=True)  # (samples, channels)
    except Exception as e:  # sf.LibsndfileError, RuntimeError, ...
        sys.exit(f"SheetSage2: cannot decode {a.audio.name} with soundfile: {e}")
    wave = data.T.copy()  # (channels, samples); load_audio mixes down + resamples to 24 kHz

    import torch
    from transformers import AutoModel

    torch.set_num_threads(min(4, torch.get_num_threads()))
    if a.device == "auto":
        device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    else:
        device = a.device
    model = AutoModel.from_pretrained(str(a.model_dir), trust_remote_code=True, local_files_only=True).eval().to(device)

    def progress(v):
        if v["stage"] == "encoding":
            print(f"Window {v['window']}/{v['windows']}", flush=True)

    opts = dict(dtype=a.dtype, progress=progress, sampling_rate=int(sr), max_seconds=a.max_seconds)
    if a.melody_only:
        opts["melody_only"] = True
    try:
        result = model.transcribe(wave, output_dir=a.output, **opts)
    except (ValueError, RuntimeError, FileNotFoundError) as e:
        sys.exit(f"SheetSage2: {e}")
    if not result.get("abc"):
        sys.exit(f"SheetSage2: no ABC score produced: {result.get('abc_error') or 'unknown'}")
    print(f"Saved transcription to {a.output.resolve()}")


if __name__ == "__main__":
    main()
