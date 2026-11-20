"""Builds the long MP3 (44.1 kHz stereo) for the long transcription test: a generated song of 150 s or more as it is, a shorter one repeated to >= 205 s.
Run with the sheetsage2 venv (soundfile): python make_long_input.py <audio.flac> <out.mp3>. Falls back to FLAC if MP3 writing fails."""
import sys

import numpy as np
import soundfile as sf

src, out = sys.argv[1], sys.argv[2]
d, sr = sf.read(src, dtype="float32", always_2d=True)
x = d if d.shape[0] / sr >= 150 else np.concatenate([d] * (int(205 * sr / d.shape[0]) + 1))  # a normal song is used as it is
if sr != 44100:  # linear interpolation: a test input, not audio to listen to
    t = np.arange(int(x.shape[0] * 44100 / sr)) * sr / 44100
    x = np.stack([np.interp(t, np.arange(x.shape[0]), x[:, c]) for c in range(x.shape[1])], 1).astype("float32")
try:
    sf.write(out, x, 44100, format="MP3")
except Exception as e:  # noqa: BLE001
    out = out.rsplit(".", 1)[0] + ".flac"
    print("MP3 failed:", e)
    sf.write(out, x, 44100)
print(out, round(x.shape[0] / 44100, 1), "s")
