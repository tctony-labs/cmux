#!/usr/bin/env bash
set -euo pipefail

BUILD_START_TIME=$(date +%s)

print_elapsed_time() {
  local status=$?
  local elapsed=$(( $(date +%s) - BUILD_START_TIME ))

  printf '\n==> Total elapsed time: %02d:%02d:%02d\n' \
    "$((elapsed / 3600))" \
    "$(((elapsed % 3600) / 60))" \
    "$((elapsed % 60))"
  return "$status"
}

trap print_elapsed_time EXIT

CMUX_REPO="${CMUX_REPO:-$HOME/Develop/Projects/cmux}"
DERIVED_DATA="${CMUX_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/cmux-release-local}"
BUNDLE_ID="com.tctony.cmux"
SIGNING_IDENTITY="Apple Development: chang tang (QLFYDXFVK8)"
DEVELOPMENT_TEAM="NSWMLDGCEZ"
ZIG_FORMULA="zig@0.15"
ZIG_REQUIRED="0.15.2"

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required but was not found in PATH" >&2
  exit 1
fi

if ! brew list --versions "$ZIG_FORMULA" >/dev/null 2>&1; then
  echo "==> installing $ZIG_FORMULA"
  brew install "$ZIG_FORMULA"
fi

ZIG_PREFIX="$(brew --prefix "$ZIG_FORMULA")"
ZIG_BIN="$ZIG_PREFIX/bin/zig"
if [[ ! -x "$ZIG_BIN" ]]; then
  echo "error: expected zig at $ZIG_BIN" >&2
  exit 1
fi

ZIG_VERSION="$("$ZIG_BIN" version)"
if [[ "$ZIG_VERSION" != "$ZIG_REQUIRED" ]]; then
  echo "error: $ZIG_FORMULA is $ZIG_VERSION, expected $ZIG_REQUIRED" >&2
  echo "try: brew update && brew reinstall $ZIG_FORMULA" >&2
  exit 1
fi

if [[ ! -d "$CMUX_REPO" ]]; then
  echo "error: cmux repo not found: $CMUX_REPO" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning \
  | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "error: code-signing identity not found: $SIGNING_IDENTITY" >&2
  exit 1
fi

cd "$CMUX_REPO"

export PATH="$PATH:$ZIG_PREFIX/bin"
export CMUX_ZIG="$ZIG_BIN"

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Ensuring ghosttykit..."
"$CMUX_REPO/scripts/ensure-ghosttykit.sh"

echo "==> using zig: $("$CMUX_ZIG" version) ($CMUX_ZIG)"
echo "==> bundle id: $BUNDLE_ID"
echo "==> signing: $SIGNING_IDENTITY (team $DEVELOPMENT_TEAM)"
echo "==> building cmux Release app"
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CMUX_SIDEBAR_EXTENSION_POINT_ID="$BUNDLE_ID.cmux.sidebar" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/cmux.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: cmux.app not found at $APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
if ! grep -Fq "Authority=$SIGNING_IDENTITY" <<<"$SIGNATURE_INFO"; then
  echo "error: built app was not signed by $SIGNING_IDENTITY" >&2
  exit 1
fi
if ! grep -Fq "TeamIdentifier=$DEVELOPMENT_TEAM" <<<"$SIGNATURE_INFO"; then
  echo "error: built app does not have team identifier $DEVELOPMENT_TEAM" >&2
  exit 1
fi

echo "==> Release app:"
echo "    $APP_PATH"
echo
echo "The app has been revealed in Finder."
echo
echo "To replace the installed app manually:"
echo "    ditto \"$APP_PATH\" /Applications/cmux.app"
echo
echo "To copy UserDefaults from the production bundle id:"
echo "    defaults export com.cmuxterm.app /tmp/cmux-defaults.plist"
echo "    defaults import $BUNDLE_ID /tmp/cmux-defaults.plist"
echo
echo "To disable automatic update checks for this local build:"
echo "    defaults write $BUNDLE_ID SUEnableAutomaticChecks -bool false"

open -R "$APP_PATH"
