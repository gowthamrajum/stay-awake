#!/usr/bin/env bash
# Build Stay Awake.app from the single Swift source file.
#
#   ./build.sh              # universal (arm64 + x86_64) into dist/
#   ./build.sh --native     # this machine's arch only — much faster for iterating
#   ./build.sh --install    # build, then replace /Applications/Stay Awake.app
#
# Needs only the Command Line Tools (`xcode-select --install`). No Xcode
# project, no SwiftPM manifest — one swiftc invocation and a bundle laid out by
# hand, because that is genuinely all a 600-line AppKit agent needs.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Stay Awake"
EXECUTABLE="StayAwake"
DEPLOYMENT_TARGET="12.0"
OUT="dist"
BUNDLE="$OUT/$APP_NAME.app"

native_only=false
install=false
for arg in "$@"; do
  case "$arg" in
    --native) native_only=true ;;
    --install) install=true ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

rm -rf "$OUT"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

build_slice() {
  local arch="$1" output="$2"
  swiftc \
    -O \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -framework AppKit \
    -framework ServiceManagement \
    -o "$output" \
    StayAwake/StayAwake.swift
}

if $native_only; then
  echo "==> Compiling ($(uname -m))"
  build_slice "$(uname -m)" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
else
  echo "==> Compiling arm64 + x86_64"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  build_slice arm64 "$tmp/arm64"
  build_slice x86_64 "$tmp/x86_64"
  lipo -create "$tmp/arm64" "$tmp/x86_64" -output "$BUNDLE/Contents/MacOS/$EXECUTABLE"
fi

echo "==> Assembling bundle"
cp StayAwake/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Ad-hoc signature. There is no paid Developer ID here, so this is not
# Gatekeeper-satisfying — it just gives the bundle a stable identity so macOS
# stops re-prompting for permissions on every rebuild. See README for the
# first-launch right-click dance a downloaded copy needs.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE" && echo "    signature ok"

if $install; then
  echo "==> Installing to /Applications"
  # Leave a running copy no chance to be half-replaced underneath itself.
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$BUNDLE" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "    installed and launched"
fi

echo "==> Done: $BUNDLE"
lipo -archs "$BUNDLE/Contents/MacOS/$EXECUTABLE" | sed 's/^/    arches: /'
