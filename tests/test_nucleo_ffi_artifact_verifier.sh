#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-nucleo-verifier-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

LIB_NAME="libcmux_command_palette_nucleo_ffi.dylib"
ARTIFACT_DIR="$WORK_DIR/Native/CommandPaletteNucleoFFI/target/universal"
SOURCE_PATH="$WORK_DIR/nucleo_test.c"
DYLIB_PATH="$ARTIFACT_DIR/$LIB_NAME"

mkdir -p "$ARTIFACT_DIR"
printf '%s\n' 'int cmux_nucleo_test_symbol(void) { return 0; }' > "$SOURCE_PATH"
xcrun clang \
  -dynamiclib \
  -arch arm64 \
  -arch x86_64 \
  -install_name "@rpath/$LIB_NAME" \
  "$SOURCE_PATH" \
  -o "$DYLIB_PATH"
xcrun lipo "$DYLIB_PATH" -verify_arch arm64 x86_64

"$ROOT_DIR/scripts/verify-command-palette-nucleo-ffi-artifact.sh" "$DYLIB_PATH"

echo "PASS: valid universal Nucleo FFI artifacts ignore otool architecture headers"
