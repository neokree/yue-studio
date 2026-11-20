#!/usr/bin/env python3
"""Download one Hugging Face repo, file by file, printing JSON progress lines (PROTOCOL.md section 5).

  fetch.py --repo m-a-p/YuE2-3B --revision main [--local-dir <dir>]

Without --local-dir files go to the HF cache (HF_HOME/hub). Re-running resumes: finished files are
skipped by huggingface_hub, partial ones continue from their .incomplete file.
"""
import argparse
import json
import os
import sys
import threading
import time
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--revision", default="main")
    ap.add_argument("--local-dir")
    args = ap.parse_args()
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
