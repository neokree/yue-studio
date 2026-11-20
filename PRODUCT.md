# Product

YuE2 Studio: an unofficial macOS client for the YuE2 open music model. Confirmed with the owner on 2026-11-20.

## Platform

adaptive

Ships on macOS 14+ (Apple Silicon). A Linux build exists only for automated tests.

## Stack

Flutter desktop, strings through `slang`. Local Python engine installed by the app itself. See CONTRACT.md.

## Users

Anyone who downloads the dmg: creators and musicians on a Mac who generate many songs in a row, compare variants, keep the ones they like.

## Product Purpose

Write a style and lyrics and get a full song; upload a recording and get a cover; keep everything in a library. All on the user's own machine, no account, no cloud.

## Positioning

The local, private counterpart of hosted song generators. Structure borrowed from the NOIZ web demo (used as a structural reference); library behaviour borrowed from Suno (list of generations, like, rename).

## Operating Context

Each song takes 2-3 minutes to generate on an M-series Mac, so users wait often. The wait is the product's signature moment. First run downloads about 10 GB.

## Capabilities and Constraints

- Create, Cover (upload, Close/Free melody), Library (play, like, rename, delete, liked filter, reuse, export), simple queue, first-run setup.
- One generation at a time. No lyric recognition. No voice cloning. No image model: artwork is algorithmic.
- English UI only for now.

## Brand Commitments

- The YuE2 mark (circle with hanging notes) and its terracotta are used as the app's logo and accent.
- "Unofficial client" is stated in About and README.
- Apple look and feel: the owner's explicit choice. Native conventions win over invention.

## Evidence on Hand

`reference/yue2-logo.webp`, measured timings in `reference/mps-profile.csv`.

## Product Principles

- The tool disappears into the task; expression is concentrated in the generation moment and the artwork.
- Honest progress: animation is bound to real engine stages, never a fake spinner.
- Nothing leaves the machine.

## Accessibility & Inclusion

System light and dark. Text contrast at least 4.5:1. Full keyboard operation. Motion respects "Reduce motion".
