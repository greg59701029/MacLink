#!/bin/zsh
cd "$(dirname "$0")" || exit 1
PYTHON_BIN="$(command -v python3.13 || command -v python3)"
if [[ -z "$PYTHON_BIN" ]]; then
    print '請先安裝 Python 3.10 以上，再執行安裝。'
else
    "$PYTHON_BIN" -B install_service.py
fi
print '\n按 Enter 關閉。'
read
