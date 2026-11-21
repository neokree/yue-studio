#!/usr/bin/env python3
"""Split a song into 6 stems with Demucs htdemucs_6s (drums, bass, other, vocals, guitar, piano). Run by backends.py
in the yue2 venv, as a child process (its memory goes back to the system when it exits; cancel = kill).

  stems.py <audio> <out dir> --model-dir <data>/models/demucs

Offline: TORCH_HOME=<model dir>, where setup put hub/checkpoints/5c90dfd2-34c22ccb.th; torch hub finds it there and
never downloads. Writes <name>.flac at the input's sample rate into <out>.partial, then renames it to <out>, so <out>
exists only when all six stems are written. I/O is soundfile: demucs.separate / demucs.audio (torchaudio I/O) are not used.
"""
import argparse
import os
import shutil
import sys
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("out")
    ap.add_argument("--model-dir", required=True)
    args = ap.parse_args()
    os.environ["TORCH_HOME"] = args.model_dir  # before torch.hub is used
    import julius
    import soundfile as sf
    import torch
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    model = get_model("htdemucs_6s")
    model.eval()
    wav, sr = sf.read(args.audio, dtype="float32", always_2d=True)
    x = torch.from_numpy(wav.T.copy())
    if x.shape[0] == 1:
        x = x.repeat(2, 1)  # the model takes stereo
    x = x[:2]
    if sr != model.samplerate:
        x = julius.resample_frac(x, sr, model.samplerate)
    ref = x.mean(0)  # same normalization as demucs.separate
    mean, std = ref.mean(), ref.std() + 1e-8
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    with torch.no_grad():
        y = apply_model(model, ((x - mean) / std)[None], device=device, split=True, overlap=0.25, progress=False)[0]
    y = y * std + mean
    if sr != model.samplerate:
        y = julius.resample_frac(y, model.samplerate, sr)
    out = Path(args.out)
    tmp = out.with_name(out.name + ".partial")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()  # no parents: a song folder deleted meanwhile is an error, not recreated
    for name, stem in zip(model.sources, y):
        sf.write(tmp / f"{name}.flac", stem.T.clamp(-1, 1).cpu().numpy(), sr)
    shutil.rmtree(out, ignore_errors=True)
    tmp.rename(out)
    print(f"stems: {', '.join(model.sources)} -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
