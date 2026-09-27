#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

lookup_pinned_ghosttykit_sha256() {
  local ghostty_sha="$1"
  local checksums_file="$2"
  awk -v sha="$ghostty_sha" '
    $1 == sha {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$checksums_file"
}

validate_bridge_header() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
required = '#include "ghostty/include/ghostty.h"'
if required not in text:
    raise SystemExit(1)
PY
}

if [[ ! -d "$PROJECT_DIR/ghostty" ]]; then
  echo "error: ghostty submodule is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/ghostty/include/ghostty.h" ]]; then
  echo "error: ghostty/include/ghostty.h is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! validate_bridge_header "$PROJECT_DIR/ghostty.h"; then
  echo "error: ghostty.h no longer points at ghostty/include/ghostty.h." >&2
  echo "Restore the bridge header so Xcode uses Ghostty's canonical C API." >&2
  exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
GHOSTTYKIT_CRASH_REPORT_SUBDIR="${CMUX_GHOSTTYKIT_CRASH_REPORT_SUBDIR:-cmux/crash}"
GHOSTTY_CLEAN_KEY="$GHOSTTY_SHA"
if [[ "$GHOSTTYKIT_CRASH_REPORT_SUBDIR" != "cmux/crash" ]]; then
  GHOSTTY_CLEAN_KEY="$GHOSTTY_SHA-custom-$(printf '%s' "$GHOSTTYKIT_CRASH_REPORT_SUBDIR" | hash_stdin)"
fi
GHOSTTY_KEY="$GHOSTTY_CLEAN_KEY"
UNTRACKED_FILES="$(git -C ghostty ls-files --others --exclude-standard)"
if ! git -C ghostty diff --quiet --ignore-submodules=all HEAD -- || [[ -n "$UNTRACKED_FILES" ]]; then
  DIRTY_HASH="$(
    {
      printf 'head=%s\n' "$GHOSTTY_SHA"
      git -C ghostty diff --binary HEAD -- .
      if [[ -n "$UNTRACKED_FILES" ]]; then
        printf '\n--untracked--\n'
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          printf 'path=%s\n' "$path"
          hash_file "$PROJECT_DIR/ghostty/$path"
        done <<< "$UNTRACKED_FILES"
      fi
    } | hash_stdin
  )"
  GHOSTTY_KEY="${GHOSTTY_CLEAN_KEY}-dirty-${DIRTY_HASH}"
fi

CACHE_ROOT="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_KEY"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_KEY_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_state_key"
LEGACY_LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_KEY.lock"
GHOSTTYKIT_CHECKSUMS_FILE="${CMUX_GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
GHOSTTYKIT_ARCHIVE_VALIDATOR="${CMUX_GHOSTTYKIT_ARCHIVE_VALIDATOR:-$SCRIPT_DIR/validate-xcframework-archive.py}"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty build key: $GHOSTTY_KEY"

LOCK_TIMEOUT=300
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
    echo "==> Lock stale (>${LOCK_TIMEOUT}s), removing and retrying..."
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    continue
  fi
  echo "==> Waiting for GhosttyKit cache lock for $GHOSTTY_KEY..."
  sleep 1
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

try_fetch_prebuilt_xcframework() {
  if [[ "$GHOSTTY_KEY" != "$GHOSTTY_CLEAN_KEY" || "${CMUX_GHOSTTYKIT_NO_PREBUILT:-0}" == "1" \
    || "$GHOSTTYKIT_CRASH_REPORT_SUBDIR" != "cmux/crash" ]]; then
    return 1
  fi
  if ! GHOSTTY_SHA="$GHOSTTY_SHA" \
    GHOSTTYKIT_CHECKSUMS_FILE="$GHOSTTYKIT_CHECKSUMS_FILE" \
    GHOSTTYKIT_ARCHIVE_VALIDATOR="$GHOSTTYKIT_ARCHIVE_VALIDATOR" \
    GHOSTTYKIT_OUTPUT_DIR="$LOCAL_XCFRAMEWORK" \
    "$SCRIPT_DIR/download-prebuilt-ghosttykit.sh"; then
    return 1
  fi
  echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
  echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
}

cache_is_usable() {
  [[ -d "$1" ]] || return 1
  if [[ "${CMUX_GHOSTTYKIT_REQUIRE_PREBUILT:-0}" == "1" ]]; then
    local expected
    expected="$(lookup_pinned_ghosttykit_sha256 "$GHOSTTY_CLEAN_KEY" "$GHOSTTYKIT_CHECKSUMS_FILE")" || return 1
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$GHOSTTY_KEY" == "$GHOSTTY_CLEAN_KEY" ]] || return 1
    [[ -f "$1/.prebuilt_sha256" && "$(cat "$1/.prebuilt_sha256")" == "$expected" ]] || return 1
  fi
}

if cache_is_usable "$CACHE_XCFRAMEWORK"; then
  echo "==> Reusing cached GhosttyKit.xcframework"
else
  LOCAL_KEY=""
  if [[ -f "$LOCAL_KEY_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LOCAL_KEY_STAMP")"
  elif [[ -f "$LEGACY_LOCAL_SHA_STAMP" ]]; then
    LOCAL_KEY="$(cat "$LEGACY_LOCAL_SHA_STAMP")"
  fi

  if [[ "$LOCAL_KEY" == "$GHOSTTY_KEY" ]] && cache_is_usable "$LOCAL_XCFRAMEWORK"; then
    echo "==> Seeding cache from existing local GhosttyKit.xcframework (build key matches)"
  elif try_fetch_prebuilt_xcframework; then
    echo "==> Seeding cache from prebuilt GhosttyKit.xcframework"
  else
    if [[ "${CMUX_GHOSTTYKIT_REQUIRE_PREBUILT:-0}" == "1" ]]; then
      echo "error: verified GhosttyKit release required for $GHOSTTY_CLEAN_KEY; source build disabled." >&2
      exit 1
    fi
    if ! command -v zig >/dev/null 2>&1; then
      echo "error: zig is required to build GhosttyKit from source." >&2
      exit 1
    fi
    rm -f "$LOCAL_XCFRAMEWORK/.prebuilt_sha256"
    echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
    (
      cd ghostty
      zig build -Dcrash-report-subdir="$GHOSTTYKIT_CRASH_REPORT_SUBDIR" \
        -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast
    )
    echo "$GHOSTTY_KEY" > "$LOCAL_KEY_STAMP"
    echo "$GHOSTTY_SHA" > "$LEGACY_LOCAL_SHA_STAMP"
  fi

  if [[ ! -d "$LOCAL_XCFRAMEWORK" ]]; then
    echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK" >&2
    exit 1
  fi

  TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
  mkdir -p "$CACHE_DIR"
  cp -R "$LOCAL_XCFRAMEWORK" "$TMP_DIR/GhosttyKit.xcframework"
  rm -rf "$CACHE_XCFRAMEWORK"
  mv "$TMP_DIR/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
  rmdir "$TMP_DIR"
  echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK"
fi

MACOS_ARCHIVE="$CACHE_XCFRAMEWORK/macos-arm64/libghostty-internal-fat.a"
if [[ -f "$MACOS_ARCHIVE" ]]; then
  # Xcode 26 can fail to resolve symbols from Ghostty's static archive
  # until its ranlib index is refreshed after reuse or copy.
  echo "==> Refreshing libghostty archive index..."
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required to refresh libghostty archive index." >&2
    exit 1
  fi
  if ! XCODE_RANLIB="$(xcrun --find ranlib 2>/dev/null)"; then
    echo "error: could not locate ranlib via xcrun." >&2
    exit 1
  fi
  "$XCODE_RANLIB" "$MACOS_ARCHIVE"
fi

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework
