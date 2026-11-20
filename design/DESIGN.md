# DESIGN: YuE² Studio

Approved by the owner on 2026-11-20. Visual reference: open `design/proposal.html` in a browser (light/dark toggle top right). It is an HTML mock, not app code: match its look, not its markup. Where this file and the mock disagree, this file wins.

## Direction

Apple-native, restrained. The tool disappears into the task. Expression is concentrated in two places only: the generation waveform and the per-song artwork. One accent colour, the terracotta of the logo.

## Name

Displayed everywhere as **YuE² Studio**: the 2 is a superscript, about 62% size, bold, in the accent colour. Bundle and file names stay `YuE2 Studio`.

## Tokens

| Token | Light | Dark |
|---|---|---|
| accent | `#A4503A` | `#D97C62` |
| accentPressed | `#8C4230` | `#E8927A` |
| accentSoft (selection, current nav) | accent at 12% | accent at 18% |
| onAccent (text on accent buttons) | `#FFFFFF` | `#1B0F0B` |
| window | `#FFFFFF` | `#1E1E20` |
| sidebar (over system blur) | `#F6F4F1` at 82% | `#282726` at 78% |
| field | `#F4F3F1` | `#2A2A2D` |
| text | `#1D1D1F` | `#F5F5F7` |
| textSecondary | `#5F5F64` | `#B4B4BA` |
| textTertiary | `#77777C` | `#98989E` |
| separator | black at 9% | white at 10% |

- **Appearance** follows the system; no in-app switch.
- **Type**: San Francisco (system font). Sizes: 26 setup title, 22 screen title, 20 song title in generation, 14 brand, 13 body and controls, 12 secondary, 11 table headers and sidebar group labels. Weights 400/600/700. Tabular numerals for times, sizes, counts. Monospace (SF Mono 12) only for ABC text.
- **Spacing**: 4-pt grid. Window content padding 22 × 28. Field gap 16. Sidebar 216 wide.
- **Radii**: window 12, fields 10, buttons 8, segmented controls 7, artwork 6.
- **Motion**: ease-out exponential `cubic-bezier(.16, 1, .3, 1)`, 200 ms for control states, 450 ms for screen transitions. Honour Reduce Motion: waveform becomes a static ring with the progress fill, no pulse.
- **Contrast**: body text at least 4.5:1 in both themes. Check secondary buttons in dark (the mock had a bug there).

## Layout

- **Window**: translucent sidebar on the left (macOS vibrancy), content on the right, persistent player bar under the content.
- **Sidebar**: logo + name, Create, Cover, group label "Library" with All Songs and Liked (with counts). Bottom: queue status (running song, stage, step, number queued, thin progress bar).
- **Player bar**: artwork 40, title + style/length, previous/play/next, elapsed, scrubber, total, like.
- **Controls**: accent filled button for the single primary action per screen ("Add to Queue"); quiet bordered buttons for the rest; segmented controls for 2-3 way choices. No cards inside cards, no gradients on text, no decorative blur.

## Screens

1. **First run**: no sidebar. Centered column 520 wide: logo 64, title "Setting up YuE² Studio", subtitle "Your private-first music generation studio. Music is generated locally.", step list (name, size or "x of y GB", state dot: empty, spinning, filled), a "Total download" row with the summed size from the manifest (downloaded of total), one progress bar. At the very bottom of the window, centered, 8.5 px tertiary text: "Unofficial client, not affiliated with the YuE2 authors." The model licence sentence is not on this screen: it goes in the macOS About panel.
2. **Create**: title, Style field, Lyrics field (fills the height), bottom row: Plan segmented (Melody + chords / Melody / None), seed, time estimate, "Add to Queue".
3. **Generating**: takes the whole content area right after "Add to Queue". Waveform (below), song title, four stage labels (Score, Melody, Sound, Master: done / current / upcoming), one status line ("Rendering sound, step 15 of 32"), Cancel. Clicking Create in the sidebar returns to the form to queue more.
4. **Cover**: file strip (artwork, file name, size · length · state, Replace, Remove); two columns. Left: Score with a Notation/Text segmented control, and under it Close/Free with a one-line hint. Right: Cover description, Lyrics. Bottom row as in Create.
5. **Library**: title, All/Liked segmented, table: artwork, title + style, created, length, like. Running and queued songs appear at the top with their status in accent. Double-click a title to rename. Context menu: Rename, Reuse Style and Lyrics, Export Audio, Show Score, Delete.

Every screen needs: empty state that teaches (empty Library points to Create), error state that names the problem and the recovery, keyboard focus rings in accent.

## Generation waveform (signature animation)

- A ring of 120 radial bars around the logo mark (mark about 27% of the ring's outer diameter, accent colour).
- Bars already reached by overall progress are accent, full amplitude, and pulse together with a beat (sharp attack, slow release, about 0.35 Hz). Bars not yet reached are tertiary grey at 45% opacity and low amplitude.
- Bar length is a sum of three moving sines so the ring looks like a live spectrum; rounded caps, bar width about 0.9% of ring diameter.
- Progress fills clockwise from 12 o'clock and maps to **real** engine progress: weight the four stages by their measured share of time (see estimator). Within Score and Melody, where the engine gives only token counts, advance by tokens against the estimated total and never go backwards.
- On completion: the pulse stops, the ring settles to even length, the song's artwork fades in at the centre, then travels to its Library row.
- Implement as a fragment shader or CustomPainter driven by one `Ticker`. Target 60 fps at under 5% CPU.

## Artwork

- Deterministic from the song id; stored in `meta.json` as `artwork: {algorithm: 1, seed: <int>}`. Old songs keep rendering with the algorithm version they were created with, forever: never change version 1, add version 2 instead. Creating or deleting other songs never changes an existing artwork.
- Version 1: two-hue diagonal gradient, three soft light blobs, then one of **five** motifs chosen by seed (concentric rings, parallel stripes at a seeded angle, dot grid with seeded sizes, plus two more of the builder's design, e.g. stacked waves and radial rays), each with a seeded density from 4 to 10. White at 34-40% opacity for the motif.
- Use the same PRNG in every platform build (implement it in Dart, do not use `Random` with platform-dependent behaviour).

## Score notation

Staff notation as in the owner's screenshot: two voices ("Vocal Melody", "Ins Melody"), tempo mark, chord symbols above the staff. Render ABC with **abcjs** (MIT; a copy is in `design/abcjs-basic-min.js` with its licence) inside a WebView on macOS, coloured with the theme's text colour on a transparent background. "Text" shows the raw ABC in the monospace editor; edits re-render the notation. On Linux (tests only) the notation view may fall back to the text view. Playback-synced highlighting is not part of today.

## Time estimate

Never a fixed string. `GenerationEstimator` returns seconds for a request:

- **Expected song length** from the lyrics (lines and sections) or, for covers, from the source duration.
- **Machine speed**: before the user has generated anything, a prior from the hardware (chip family, performance cores, GPU cores, memory) scaled from the reference measurement: M4 Pro 48 GB = 2.3 s of work per second of audio, stage shares Score 11%, Melody 35%, Sound 51%, Master 3%. After each real generation, update per-stage speeds with a moving average stored in the data dir, and use those from then on.
- Shown as "About 2 min 40 s on this Mac"; during generation the remaining time is recomputed from the live stage speed.
- Only one machine has been measured: priors for other chips are estimates until the first run calibrates them. Say "About".
