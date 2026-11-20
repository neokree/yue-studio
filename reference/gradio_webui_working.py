#!/usr/bin/env python3
"""Minimal local web UI for YuE2. Run from the repo root:

    PYTORCH_ENABLE_MPS_FALLBACK=1 uv run --with gradio --with huggingface-hub==0.36.2 examples/webui.py

The huggingface-hub pin matters: without it gradio pulls hub 2.x, which transformers 4.57.6 rejects.

The Cover tab transcribes an uploaded recording with SheetSage2, which needs its own environment
(different torch/transformers pins). One-time setup from the repo root:

    uvx --from huggingface-hub==0.36.2 huggingface-cli download m-a-p/SheetSage2 --local-dir models/SheetSage2
    uv venv .venv-sheetsage2 --python 3.11
    uv pip install --python .venv-sheetsage2 -r models/SheetSage2/requirements.txt
"""
import json
import random
import subprocess
import sys
import time
from pathlib import Path

import gradio as gr

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = json.loads((ROOT / "examples" / "song.json").read_text(encoding="utf-8"))
SHEETSAGE_PY = ROOT / ".venv-sheetsage2" / "bin" / "python"
SHEETSAGE_INFER = ROOT / "models" / "SheetSage2" / "infer.py"
# "Close" keeps melody and chords (cot=full); "Free" keeps the melody only (cot=melody).
COVER_MODES = {"Close (melody + chords)": "full", "Free (melody only)": "melody"}
_pipe = None  # ponytail: one pipeline, one request at a time; add a worker pool if this ever serves several users


def generate(style, lyrics, cot, seed, abc=None, progress=gr.Progress()):
    global _pipe
    if not style.strip():
        raise gr.Error("Style is required.")
    seed = random.randrange(2**31) if seed is None or seed < 0 else int(seed)
    if _pipe is None:
        progress(0, desc="Loading model (first request only)")
        from yue2 import YuE2Pipeline
        _pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="auto")

    counts = {}

    def on_token(phase, _token):
        counts[phase] = counts.get(phase, 0) + 1
        if counts[phase] % 25 == 0:
            label = "Planning score" if phase == "abc" else "Generating song"
            progress(0, desc=f"{label}: {counts[phase]} tokens")

    def on_progress(stage, done, total):
        progress(done / total, desc="Rendering acoustics" if stage == "nar" else "Decoding audio")

    request = dict(style=style, lyrics=lyrics, cot=cot, seed=seed)
    if abc:
        request["abc"] = abc
    try:
        song = _pipe(**request, on_token=on_token, on_progress=on_progress)
    except ValueError as exc:  # request validation, e.g. an ABC score the model cannot read
        raise gr.Error(str(exc))
    out = ROOT / "outputs" / "webui" / f"{time.strftime('%Y%m%d-%H%M%S')}-{seed}"
    song.save_artifacts(out)
    info = {"output": str(out), "seed": seed, "device": song.config["device"],
            "audio_seconds": round(len(song.audio) / song.sample_rate, 1),
            "generation_seconds": round(song.timing["e2e_seconds"], 1), "truncated": song.truncated}
    return str(out / "audio.flac"), song.abc or "", info


def transcribe(audio_path, mode, progress=gr.Progress()):
    if not audio_path:
        raise gr.Error("Upload a recording first.")
    if not SHEETSAGE_PY.exists() or not SHEETSAGE_INFER.exists():
        raise gr.Error("SheetSage2 is not installed. See the setup commands at the top of examples/webui.py.")
    progress(0, desc="Transcribing melody with SheetSage2 (about a minute)")
    out = ROOT / "outputs" / "webui" / f"transcribe-{time.strftime('%Y%m%d-%H%M%S')}"
    command = [str(SHEETSAGE_PY), str(SHEETSAGE_INFER), audio_path, "--output", str(out),
               "--device", "mps" if sys.platform == "darwin" else "auto"]
    if COVER_MODES[mode] == "melody":
        command.append("--melody-only")
    result = subprocess.run(command, capture_output=True, text=True)
    score = out / "score.abc"
    if result.returncode or not score.exists():
        raise gr.Error("Transcription failed: " + (result.stderr or result.stdout)[-600:])
    return score.read_text(encoding="utf-8")


def cover(style, lyrics, mode, abc, seed, progress=gr.Progress()):
    if not abc.strip():
        raise gr.Error("Transcribe a recording or paste an ABC score first.")
    return generate(style, lyrics, COVER_MODES[mode], seed, abc=abc, progress=progress)


with gr.Blocks(title="YuE2") as demo:
    gr.Markdown("# YuE2\nOne request at a time. Every run is saved under `outputs/webui/`.")
    with gr.Row():
        with gr.Column():
            with gr.Tab("Text to Song"):
                style = gr.Textbox(label="Style", lines=3, value=EXAMPLE["style"],
                                   info="Genre, instruments, voice, language, tempo")
                lyrics = gr.Textbox(label="Lyrics", lines=12, value=EXAMPLE["lyrics"],
                                    info="Use section tags like [Verse] and [Chorus]. Leave empty for instrumental.")
                with gr.Row():
                    cot = gr.Radio(["full", "melody", "off"], value="full", label="Symbolic plan")
                    seed = gr.Number(value=-1, precision=0, label="Seed (-1 = random)")
                run = gr.Button("Generate", variant="primary")
            with gr.Tab("Cover"):
                source = gr.Audio(label="Original song", type="filepath", sources=["upload"])
                mode = gr.Radio(list(COVER_MODES), value="Free (melody only)", label="Reference melody",
                                info="Only the melody (and chords, in Close) is taken from the recording, "
                                     "not the voice or the sound. Changing this clears the score.")
                transcribe_btn = gr.Button("Transcribe melody")
                cover_abc = gr.Code(label="Score (ABC): review, edit, or paste your own", language=None,
                                    interactive=True, lines=10)
                cover_style = gr.Textbox(label="Cover description", lines=3,
                                         info="New style: genre, instruments, voice, language, tempo")
                cover_lyrics = gr.Textbox(label="Lyrics", lines=10,
                                          info="Type the words to sing, in the order of the score's sections. "
                                               "Lyrics are not recognized from the recording.")
                cover_seed = gr.Number(value=-1, precision=0, label="Seed (-1 = random)")
                cover_btn = gr.Button("Generate cover", variant="primary")
        with gr.Column():
            audio = gr.Audio(label="Song", type="filepath")
            score = gr.Code(label="Score used (ABC)", language=None)
            info = gr.JSON(label="Run")
    outputs = [audio, score, info]
    # concurrency_id shares one slot: transcription and generation never run on the GPU together.
    run.click(generate, [style, lyrics, cot, seed], outputs, concurrency_limit=1, concurrency_id="gpu")
    transcribe_btn.click(transcribe, [source, mode], cover_abc, concurrency_limit=1, concurrency_id="gpu")
    cover_btn.click(cover, [cover_style, cover_lyrics, mode, cover_abc, cover_seed], outputs,
                    concurrency_limit=1, concurrency_id="gpu")
    mode.change(lambda: "", None, cover_abc)

if __name__ == "__main__":
    demo.launch(inbrowser="--no-browser" not in sys.argv)  # binds 127.0.0.1 only
