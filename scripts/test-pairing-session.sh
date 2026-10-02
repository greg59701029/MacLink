#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/maclink-pairing-tests.XXXXXX")"
trap 'rm -f "$test_dir/pairing-tests"; rmdir "$test_dir"' EXIT
xcrun swiftc -parse-as-library "$project_dir/Sources/MacLink/Models.swift" "$project_dir/Sources/MacLink/AppModel.swift" "$project_dir/Tests/PairingSessionTests.swift" -o "$test_dir/pairing-tests"
"$test_dir/pairing-tests"
