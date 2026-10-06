#!/bin/sh
# Builds Bore with SwiftPM and assembles an ad-hoc signed Bore.app in ./dist.
#
#   ./build.sh            release build
#   ./build.sh --debug    debug build
#   ./build.sh --run      build, then launch Bore.app
set -eu

cd "$(dirname "$0")"

CONFIG=release
RUN=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

swift build -c "$CONFIG"

BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)
APP=dist/Bore.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Bore" "$APP/Contents/MacOS/Bore"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP"

echo "Built $APP"

if [ "$RUN" = 1 ]; then
  # Relaunch cleanly if an instance is already running.
  osascript -e 'tell application id "com.nmoon.Bore" to quit' >/dev/null 2>&1 || true
  sleep 0.5
  open "$APP"
fi
