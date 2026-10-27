#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="PhotoEdit"
BUNDLE_ID="local.photo-edit.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build --package-path "$ROOT_DIR/app" -c release
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR/app" -c release --show-bin-path)/$APP_NAME"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
export PHOTO_EDIT_BUILD_ROOT="$ROOT_DIR"
/usr/bin/python3 - <<'PY'
import os,plistlib
from pathlib import Path
root=Path(os.environ['PHOTO_EDIT_BUILD_ROOT'])
info=dict(CFBundleExecutable='PhotoEdit',CFBundleIdentifier='local.photo-edit.app',CFBundleName='Photo Edit',
          CFBundleDisplayName='Photo Edit',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='0.1.0',
          LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication',NSHighResolutionCapable=True,
          PhotoEditProjectRoot=str(root))
with (root/'dist/PhotoEdit.app/Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "PhotoEdit"' ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo 'usage: build_and_run.sh [--build-only|--verify|--debug|--logs]' >&2; exit 2 ;;
esac
