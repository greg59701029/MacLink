#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/maclink-address-tests.XXXXXX")"
trap 'rm -f "$test_dir/private-address-tests"; rmdir "$test_dir"' EXIT
xcrun swiftc "$project_dir/Sources/MacLink/Models.swift" "$project_dir/Tests/PrivateAddressTests.swift" -o "$test_dir/private-address-tests"
"$test_dir/private-address-tests"
