#!/usr/bin/env bash
set -euo pipefail
test_root="$(cd "$(dirname "$0")" && pwd)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/expo-mpv-font-tests.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
cmake -S "$test_root" -B "$build_root" \
  -DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' \
  -DCMAKE_CXX_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'
cmake --build "$build_root" --parallel 4
ctest --test-dir "$build_root" --output-on-failure
