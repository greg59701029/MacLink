#!/bin/zsh
cd "$(dirname "$0")"
PYTHON_BIN="$(command -v python3.13 || command -v python3)"
"$PYTHON_BIN" -B server.py
