#!/bin/sh
# uv for the e2e: python 3.12 is pre-installed in the image so `python install` is instant; the venv step sleeps a moment
# so the "installing" screenshot catches a real in-progress state (Python done, engine environment running).
[ "$1" = venv ] && sleep "${E2E_UV_VENV_SLEEP:-2.5}"
exec /usr/local/bin/uv "$@"
