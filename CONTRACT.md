# CONTRACT: YuE2 Studio

Unofficial macOS client for the YuE2 open music model. Flutter app, local engine, no cloud.
Owner decisions below are fixed (agreed with the user on 2026-11-20). Do not rename or re-scope them.
Hard deadline: **today 16:00**. Speed is the priority of this document.

## 1. Who, what, why

- **Who**: anyone who downloads the dmg. Creators who generate many songs in a row on an Apple Silicon Mac.
- **What**: write style + lyrics, get a song; upload a recording, get a cover; keep, like and rename everything in a library.
- **Why Flutter**: the same UI builds for Linux (tested headless in Docker, so the user's screen stays free) and for macOS (what ships).
- **Starting state**: a Mac with nothing installed. The app installs its own engine and models. It must not rely on any developer tool on the machine (no system Python, uv, ffmpeg, Homebrew, Hugging Face cache).

## 2. Fixed product decisions

| Topic | Decision |
|---|---|
| Name | "YuE2 Studio" in bundle and file names; displayed as "YuE² Studio" with the 2 as a superscript. About screen and README say: unofficial client, not affiliated with the YuE2 authors. |
| Logo | The mark in `reference/yue2-logo.webp` (circle + notes, terracotta). Redraw it as a vector path in code. |
| Platforms | Ships: macOS 14+, Apple Silicon only. Linux build exists only for tests. |
| Language | English UI only, but every string goes through `slang` from the first commit. |
| Look | Apple look and feel: translucent sidebar (Create, Cover, Library), San Francisco system font, light and dark following the system, controls and spacing like Apple Music/Podcasts, terracotta as accent. Final tokens come from `design/DESIGN.md` (see section 8). |
| Animations | Written in Flutter code (fragment shaders, CustomPainter). No Rive, no Lottie, no video. The most refined animation is the song-generation state. |
| Song artwork | Generated algorithmically from the song id/seed (CustomPainter). No image model. Two songs must be visibly different at a glance. Artwork is persistent: same song, same artwork across restarts and regardless of other songs (versioned algorithm, see DESIGN.md). |
| Time estimate | Never a static string: computed from the user's hardware and calibrated by their own past runs (`GenerationEstimator`, see DESIGN.md). |
| Score view | ABC shown as staff notation (abcjs in a WebView on macOS) with a Text toggle; see DESIGN.md. |
| Signing | Ad-hoc signature, not notarized. README explains the Gatekeeper step. App Sandbox off (the app spawns processes and downloads files). |
| Repo | `neokree/yue-studio`, **private**. Local `gh` is logged in. No CI. |

## 3. Features (all four ship today, in this order)

1. **First-run setup**: one screen that downloads and installs everything (engine + all models, Cover included, about 10 GB), with real progress per step, resumable, retry on failure, free-disk check before starting. Shows the model licence note (weights are CC BY-NC 4.0 with creator permission) and the unofficial notice.
2. **Create (Text to Song)**: style, lyrics (section tags `[Verse]`, `[Chorus]`), symbolic plan mode (`full` default, `melody`, `off`), seed (random by default). Generate.
3. **Library**: every generation, newest first, with artwork, title, duration, date, status (queued, generating, done, failed). Actions: play (persistent player bar at the bottom), like, rename, delete, filter "liked only", "reuse style and lyrics" (prefills Create), export audio file. Not today: playlists, sharing, search.
4. **Cover**: upload a recording (wav, flac, mp3, ogg), choose "Close" (melody + chords, `cot=full`) or "Free" (melody only, `cot=melody`), transcribe to an ABC score shown in an editable field (pasting your own score also works), then style + lyrics + generate. Lyrics are typed by the user; there is no lyric recognition.

**Queue**: the engine runs one job at a time. The user can enqueue more while one runs; jobs run in order; each can be cancelled. The generation animation follows the running job; the others show as "queued" in the Library.

**Cut order if late**: staff-notation view first (fall back to the text score), then Cover, then export/reuse actions, then dark theme polish. Setup, Create, Library with like/rename and the generation animation are never cut.

## 4. Architecture (fixed)

```
Flutter app ── JSON lines over stdin/stdout ──> Python sidecar (engine/sidecar.py)
     │                                                  │
     └─ bundles: uv binary, engine/*.py                 └─ YuE2Pipeline (venv A, py3.12)
        data dir: ~/Library/Application Support/YuE2 Studio/     SheetSage2 subprocess (venv B, py3.11)
```

- **Only `uv` is bundled** (`uv-aarch64-apple-darwin` from the astral-sh/uv GitHub release, pinned version, checksum verified at build time). Everything else is downloaded at first run into the data dir: Python builds, two venvs, model weights. Set `UV_PYTHON_INSTALL_DIR`, `UV_CACHE_DIR`, `HF_HOME` to subfolders of the data dir and unset `HF_TOKEN` so nothing reads or writes outside it. Uninstall = delete that one folder.
- **Sidecar protocol**: one JSON object per line. Requests: `generate`, `transcribe`, `cancel`, `shutdown`. Events: `ready`, `progress {job, stage, done, total}`, `result {job, dir}`, `error {job, message}`. Stages for generate: `load`, `abc`, `semantic`, `nar`, `vae`. Define it once in `engine/PROTOCOL.md`; Dart and Python both follow that file.
- **Fake mode**: `sidecar.py --fake` uses only the Python standard library, emits the same events on a short timer and writes a tiny valid audio file. The setup flow takes a **manifest**; the fake manifest installs Python via uv, no torch, no models. Docker runs the real setup code path and the real protocol against the fake manifest. This is what keeps tests fast.
- **Library storage**: one folder per song under `library/<id>/` holding the engine artifacts plus `meta.json` (title, liked, createdAt, status, request). The list is a directory scan. No database.
- **State management**: plain `ChangeNotifier`/`ValueNotifier`. No Bloc/Riverpod unless a concrete problem requires it.
- **Audio playback**: one package that works on both macOS and Linux (check `audioplayers` first).

## 5. Engine facts already proven on this Mac (do not rediscover)

Working reference: `reference/gradio_webui_working.py` (Gradio UI that does Create and Cover end to end on this machine). Read it first; the sidecar is that file without Gradio.

- **YuE2 env (venv A)**: Python 3.12, install the wheel `https://github.com/multimodal-art-projection/YuE/releases/download/yue2-v0.1.6/yue2_infer-0.1.6-py3-none-any.whl` (pulls torch 2.14.1 on macOS, transformers 4.57.6, huggingface-hub 0.36.2, soundfile).
- **Run with** `PYTORCH_ENABLE_MPS_FALLBACK=1`, device `mps`.
- **API**: `YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="auto", cache_dir=...)`, then `pipe(style=, lyrics=, cot=, seed=, abc=optional, on_token=fn(phase, token), on_progress=fn(stage, done, total), cancelled=fn()->bool)`, then `song.save_artifacts(dir)` which writes `audio.flac` (48 kHz stereo), `score.abc`, `result.json`. Keep one pipeline loaded between jobs.
- **Measured**: about 160 s for a 70 s song; peak about 9 GB process memory; GPU 80-100% (`reference/mps-profile.csv`). Stage share: abc 17 s, semantic 55 s, nar 80 s, vae 4 s. `abc`/`semantic` report token counts with no known total; `nar`/`vae` report done/total.
- **Models**: `m-a-p/YuE2-3B` 6.8 GB, `m-a-p/YuE2-Vae` 507 MB, both public (not gated).
- **SheetSage2 env (venv B)**: Python 3.11, `huggingface-cli download m-a-p/SheetSage2 --local-dir <dir>` (223 MB) then install its `requirements.txt` (torch 2.8.0, transformers 4.45.2: this is why it needs its own venv). It pulls its encoder `m-a-p/MERT-v2-FullSong` (about 2.3 GB) on first load. Loading runs the repo's Python via `trust_remote_code=True`: pin the revision.
- **Transcribe**: `python <dir>/infer.py <audio> --output <fresh dir> --device mps [--melody-only]` writes `score.abc`. About 63 s for a 70 s song on MPS. `--melody-only` for Free, without it for Close (Close was not tested end to end).
- **Two things to verify early (risks)**:
  1. `infer.py` decodes files by calling the `ffmpeg` CLI, which must not be required. `audio_sheetsage2.load_audio` also accepts a waveform array plus `sampling_rate`: decode with `soundfile` in our own wrapper and pass the array. Confirm this in the first 30 minutes; if it fails, tell the user instead of bundling ffmpeg silently.
  2. This Mac has a Hugging Face token on disk. Confirm that SheetSage2 and MERT-v2-FullSong download **anonymously** (`HF_HOME` set to an empty temp dir, `HF_TOKEN` unset). If either is gated, stop and tell the user.

## 6. Tests: minimum runtime, maximum coverage

Long automated suites are the known failure mode of this process. Budgets are hard limits.

| Layer | Runs where | Budget | Covers |
|---|---|---|---|
| Unit + widget (`flutter test`) | host via `fvm`, headless | 60 s total | protocol parsing, queue, library store, setup state machine, each screen against a fake engine object |
| Sidecar (`pytest`, fake mode + protocol) | host via `uv run` | 20 s | every request/event, cancel, error paths |
| One e2e (`integration_test`) | Docker, Linux arm64, Xvfb | 3 min | fresh data dir → setup with fake manifest → generate → appears in Library → like → rename → play. Saves 4-5 screenshots for the critic. |
| Real engine (headless script) | macOS, after lunch | run twice at most | fresh data dir → real setup (10 GB download) → one real generation → one real transcription |

- One command runs the first three: `tool/test.sh`. Run it before every critic round, not after every edit.
- No pixel-golden tests. Screenshots are for the critic to look at, not for diffing.
- Docker VM: Linux arm64, 8 GB RAM, no GPU. The model never runs there. Build the image once (Ubuntu + Flutter 3.44.3 + GTK/Xvfb/GStreamer deps) and mount the source; do not rebuild per run.
- The agent never drives the macOS GUI. The user does one 5-minute manual pass on the built app.

## 7. How to build it

### 7a. Roles and models (all at high effort)

- **Orchestrator and critic**: the "Client App" session (Opus). It plans, reviews, judges. It does not write feature code.
- **Builders**: Sonnet sub-agents, several in parallel on disjoint folders.
- **Mechanical work**: Haiku sub-agents (scaffolding, running the test script and summarising failures, README, string tables, Dockerfile tweaks).
- **Fable**: only if an architectural blocker survives one Opus attempt.

### 7b. Development approach

Walking Skeleton first, then Outside-In. The skeleton (sidecar in fake mode + protocol + app shell that shows one fake song end to end in Docker) lands before any feature work, because every track depends on `engine/PROTOCOL.md` and the Dart engine interface. After that the tracks below run in parallel.

- **Track A, engine**: `engine/sidecar.py` real mode, manifests, `soundfile` wrapper for SheetSage2, pytest.
- **Track B, setup**: installer service (uv calls, progress parsing, resume) + first-run screen.
- **Track C, create + queue + generation animation**.
- **Track D, library + player + artwork**.
- **Track E, cover screen** (starts when A has `transcribe` in fake mode).
- **Track F, harness**: Docker image, `tool/test.sh`, e2e test, macOS real-engine script, dmg script (`hdiutil`).

Theme: all colours, radii, type sizes and motion durations live in `lib/theme/tokens.dart` with provisional values from day one, so the design can land late without touching screens.

### 7c. Gauntlet loop, lightened

- Reference to beat, judged blind per piece: `reference/noiz-*.png` for structure and completeness, `design/DESIGN.md` for look, Apple Music/Podcasts for native feel.
- **Maximum 3 critic rounds per milestone.** After round 3, ship what passes and list what does not; do not loop further.
- The critic judges screenshots from the e2e run and the test output, in one batch per round.

### 7d. Timeline

| Time | Milestone |
|---|---|
| 11:30 → 12:15 | M0 walking skeleton green in Docker; both early risks in section 5 answered |
| 12:15 → 13:30 | M1 setup + Create + generation animation; M2 library/player/queue in parallel |
| 12:30 | `design/DESIGN.md` arrives from the user's design session; apply tokens |
| 13:30 → 14:15 | M3 Cover; critic rounds on M1-M3 |
| 14:15 → 15:00 | macOS build with `fvm flutter build macos`, real-engine run from a fresh data dir, fixes |
| 15:00 → 15:30 | user's manual pass, fixes from it |
| 15:30 → 16:00 | dmg, README, draft release |

If a milestone is 20 minutes late, apply the cut order in section 3 instead of compressing tests.

## 8. Design input

`design/DESIGN.md` is approved and fixed (2026-11-20, 11:50). `design/proposal.html` is its visual reference: open it in a browser. `PRODUCT.md` holds the product context.

**Next step, not today**: evaluate YuE2-Turbo (https://github.com/NoizAI/YuE2-Turbo) as a faster engine. Its Apple Silicon support is unverified. Keep the sidecar's engine behind one small Python interface so it can be swapped later; do not spend time on Turbo before the release.

## 9. Rules

- Work only inside `/Users/fabiobiola/Developer/neokree/yue-studio` (your shell starts elsewhere: use absolute paths). Never modify `/Users/fabiobiola/Developer/AI-Tools/YuE`.
- Nothing system-wide: no `brew install`, no global pip, no sudo. Flutter through `fvm` (3.44.3 is installed). Python through `uv`.
- Git: commit freely on `main`. Creating the private GitHub repo and pushing is approved. **Creating or publishing a release is not**: prepare the dmg and a draft, then ask the user.
- Do not use the user's `~/.cache/huggingface` to make a test pass; the fresh-install test must download for real.
- Report honestly: what was tested, what was not, what was cut.
- Questions that block you go to the user in your own session. Design questions go to session `yue-99`.

## 10. Done means

1. `tool/test.sh` green within its budgets.
2. On this Mac, from an empty data dir: setup completes, one real song is generated, one real cover is generated from an uploaded file.
3. The user has done the manual pass.
4. A dmg exists and installs by drag-and-drop; README has install, Gatekeeper and unofficial/licence notes.
5. A written list of anything cut or untested.
