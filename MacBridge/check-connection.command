#!/bin/zsh
cd "$(dirname "$0")" || exit 1
PYTHON_BIN="$(command -v python3.13 || command -v python3)"
"$PYTHON_BIN" -B diagnostics.py
print '\n按 Enter 關閉。'
read
