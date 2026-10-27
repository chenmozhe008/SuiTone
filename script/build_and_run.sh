#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="SuiTone"
BUNDLE_ID="local.photo-edit.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x PhotoEdit >/dev/null 2>&1 || true
swift build --package-path "$ROOT_DIR/app" -c release
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR/app" -c release --show-bin-path)/$APP_NAME"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -f "$ROOT_DIR/app/Resources/AppIcon.icns" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources"
  cp "$ROOT_DIR/app/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
export PHOTO_EDIT_BUILD_ROOT="$ROOT_DIR"
"$HOME/.cache/photo-edit/venv/bin/python" -B - <<'PY'
import os,plistlib
from pathlib import Path
root=Path(os.environ['PHOTO_EDIT_BUILD_ROOT'])
info=dict(CFBundleExecutable='SuiTone',CFBundleIdentifier='local.photo-edit.app',CFBundleName='SuiTone',
          CFBundleDisplayName='随心调色',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='0.1.0',
          LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication',NSHighResolutionCapable=True,
          PhotoEditProjectRoot=str(root))
if (root/'app/Resources/AppIcon.icns').is_file():info['CFBundleIconFile']='AppIcon'
with (root/'dist/SuiTone.app/Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "SuiTone"' ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo 'usage: build_and_run.sh [--build-only|--verify|--debug|--logs]' >&2; exit 2 ;;
esac
