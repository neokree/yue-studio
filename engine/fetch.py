#!/usr/bin/env python3
"""Download one Hugging Face repo, file by file, printing JSON progress lines (PROTOCOL.md section 5).

  fetch.py --repo m-a-p/YuE2-3B --revision main [--local-dir <dir>]
  fetch.py --url <https url> --sha256 <hex> --size <bytes> --dest <file>


Without --local-dir files go to the HF cache (HF_HOME/hub). Re-running resumes: finished files are
skipped by huggingface_hub, partial ones continue from their .incomplete file.
--url: one file, resumed from <dest>.part with an HTTP Range request, checked against --sha256, then renamed to <dest>;
a file already at <dest> with the right hash is not downloaded again.
"""
import argparse
import hashlib
import json
import os
import sys
import threading
import time
import urllib.request
from pathlib import Path

os.environ["HF_HUB_DISABLE_XET"] = "1"  # before huggingface_hub: xet writes in bursts, plain HTTP grows <file>.incomplete

from huggingface_hub import HfApi, constants, hf_hub_download


def say(**event):
    print(json.dumps(event), flush=True)


def partial_bytes(roots):
    total = 0
    for root in roots:
        for p in root.rglob("*.incomplete"):
            try:
                total += p.stat().st_size
            except OSError:
                pass
    return total


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def fetch_url(url, want, total, dest):
    dest = Path(dest)
    if dest.exists() and sha256(dest) == want:
        say(type="progress", done=total, total=total)
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    say(type="progress", done=have, total=total)
    if total and have >= total:  # killed between the last write and the rename: a Range past the end would get 416 forever
        if sha256(part) == want:
            os.replace(part, dest)
            say(type="progress", done=total, total=total)
            return
        part.unlink()
        have = 0
    req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    with urllib.request.urlopen(req, timeout=60) as r, open(part, "ab" if have and r.status == 206 else "wb") as f:
        done, last = (have if r.status == 206 else 0), 0.0
        while chunk := r.read(1 << 20):
            f.write(chunk)
            done += len(chunk)
            if time.monotonic() - last >= 1:
                last = time.monotonic()
                say(type="progress", done=min(done, total), total=total)
    if sha256(part) != want:
        part.unlink()
        raise RuntimeError(f"{dest.name}: the download does not match its published hash; try again")
    os.replace(part, dest)
    say(type="progress", done=total, total=total)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo")
    ap.add_argument("--revision", default="main")
    ap.add_argument("--local-dir")
    ap.add_argument("--url")
    ap.add_argument("--sha256")
    ap.add_argument("--size", type=int, default=0)
    ap.add_argument("--dest")
    args = ap.parse_args()
    if args.url:
        try:
            fetch_url(args.url, args.sha256, args.size, args.dest)
            say(type="done")
        except Exception as exc:
            say(type="error", message=f"{type(exc).__name__}: {exc}")
            sys.exit(1)
        return
    try:
        info = HfApi().model_info(args.repo, revision=args.revision, files_metadata=True)
        files = [(s.rfilename, s.size or 0) for s in info.siblings]
        total = sum(size for _, size in files)
        roots = [Path(args.local_dir)] if args.local_dir else [
            Path(constants.HF_HUB_CACHE) / ("models--" + args.repo.replace("/", "--"))]
        state = {"done": 0}
        finished = threading.Event()

        def ticker():  # bytes of finished files + the file in flight
            while not finished.wait(1.0):
                say(type="progress", done=min(state["done"] + partial_bytes(roots), total), total=total)

        say(type="progress", done=0, total=total)
        threading.Thread(target=ticker, daemon=True).start()
        for name, size in files:
            hf_hub_download(args.repo, name, revision=args.revision, local_dir=args.local_dir)
            state["done"] += size
        finished.set()
        say(type="progress", done=total, total=total)
        say(type="done")
    except Exception as exc:
        say(type="error", message=f"{type(exc).__name__}: {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
