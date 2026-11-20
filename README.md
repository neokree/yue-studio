# YuE² Studio

YuE² Studio is an unofficial macOS app for the YuE2 open music model. It turns a style and lyrics into a song. It also turns an uploaded recording into a cover.

The app is not affiliated with the YuE2 authors. Everything runs on your Mac. The first run downloads the engine and the models. After that, generation runs locally and does not need the network.

The interface is in English.

## What it does

- **Create**: write a style and lyrics, then generate a song.
- **Cover**: upload a recording (wav, flac, mp3 or ogg) and generate a new version in the style and lyrics you choose. You type the lyrics yourself. The app does not recognise lyrics in the recording.
- **Library**: keep every song. Play, like, rename, delete and export the audio. Reuse the style and lyrics of a song in Create. Queue more songs while one is generating.

## System requirements

- Mac with Apple Silicon (M1 or later). Intel Macs are not supported.
- macOS 14 or later.
- Memory: 24 GB of RAM to work properly. With 16 to 23 GB you can try anyway. With less than 16 GB the app cannot go on.
- 15 GB of free disk space (25 GB recommended).
- Internet connection for the first run.

macOS itself keeps out Intel Macs and macOS older than 14. The app checks the memory before it downloads anything. With less than 24 GB it shows a page that says so. From 16 GB up, the page has a **Try anyway** button that opens setup. The app remembers that choice and does not show the page again. Setup checks the free disk space.

Cover transcription peaks at about 11 GB, so on a 16 GB Mac close other apps before transcribing.

On Macs with less than 24 GB of memory, the app unloads the song model before a Cover transcription and loads it again afterwards.

## Install

1. Open `YuE2-Studio-<version>.dmg`.
2. Drag **YuE² Studio** into the **Applications** folder.
3. Open the app from Applications. See the next section the first time.

## Opening the app the first time

The app is ad-hoc signed and is not notarized by Apple. macOS blocks it the first time you open it. Use one of these steps.

**System Settings:**

1. Try to open the app once. macOS shows a warning.
2. Open **System Settings**, then **Privacy & Security**.
3. Find the message about "YuE² Studio" and click **Open Anyway**. Enter your password if asked.

**Right-click:** on some macOS versions you can right-click the app in Applications and choose **Open**. If that does not work, use the System Settings steps.

**Terminal:** this removes the quarantine flag that macOS adds to downloaded apps. Run it only on the copy you installed from the dmg.

```
xattr -dr com.apple.quarantine "/Applications/YuE² Studio.app"
```

## First run

On first launch the app checks the memory (see System requirements), then installs everything it needs:

- The engine, its Python environment and all models, including the models for Cover. The total download is about 10 to 11 GB.
- Progress for each step.
- A free disk space check before the download starts.
- Resume. If the download stops, start the app again and setup continues from the last finished step.
- Retry. If a step fails, press retry on that step.

Setup shows the unofficial notice. The model licence note is in the About panel (YuE² Studio menu > About YuE² Studio).

All downloaded files go to this folder:

```
~/Library/Application Support/YuE2 Studio
```

Your songs are in the `library` folder inside it.

## Uninstall

1. Quit the app.
2. Delete **YuE² Studio** from Applications.
3. Delete the folder `~/Library/Application Support/YuE2 Studio`.

Step 3 also deletes all your songs and the models. Export the songs you want to keep before you delete the folder.

## Licences

- **App code**: MIT licence, see [LICENSE](LICENSE). It covers this repository's code only, not the model weights the app downloads.
- **Model weights**: CC BY-NC 4.0. The creators gave permission to use them in this app. The licence allows non-commercial use only.
- **abcjs** (score rendering): MIT licence, Copyright (c) 2009-2024 Paul Rosen and Gregory Dyke.
- **uv** (Python environment manager, bundled): MIT or Apache-2.0, at your option.

## Development

Requirements: Flutter through `fvm`, version 3.44.3 (pinned in `.fvmrc`). Docker for the end-to-end test. Apple Silicon Mac for the real engine run.

```
fvm use 3.44.3                                  # only if .fvmrc is missing
tool/fetch_uv.sh                                # pinned uv into assets/uv, sha256 checked
docker build -t yue2-studio-test:3.44.3 docker  # once, not per run
```

Python is run only through `uv`. The app keeps its downloads in its own data folder and does not use the Hugging Face cache.

Scripts in `tool/`:

- `tool/test.sh [--only unit|py|e2e]` runs three layers. Unit and widget tests with `fvm flutter test` (60 s budget). Sidecar tests with pytest through `uv` (20 s budget). The end-to-end test in Docker on Linux with Xvfb (3 min budget). Screenshots go to `build/e2e-shots/`. The first e2e run compiles the Linux app and gets 10 minutes.
- `tool/real_engine.sh [--fresh] [data dir]` runs the real engine on an Apple Silicon Mac. It downloads the models, then generates one song, one transcription and one cover. Default data dir: `.scratch/real-data`. `--fresh` wipes it first. Log: `.scratch/real-engine.log`.
- `tool/make_dmg.sh` builds the release app, signs it ad-hoc and writes `dist/YuE2-Studio-<version>.dmg`. It publishes nothing.
- `tool/fetch_uv.sh [--force]` downloads the pinned uv for Apple Silicon, checks its sha256 and writes `assets/uv/uv`. That file is gitignored.

The engine protocol is in `engine/PROTOCOL.md`.
