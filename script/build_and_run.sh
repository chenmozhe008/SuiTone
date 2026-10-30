#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="SuiTone"
BUNDLE_ID="local.photo-edit.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"

source "$ROOT_DIR/script/swift_env.sh"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
# 没有开发证书时退回临时签名。固定签名身份能让钥匙串在重新编译后仍认出这个 App，不必重新授权读取 API 密钥。
if [[ "$CODESIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CODESIGN_IDENTITY"; then
  CODESIGN_IDENTITY="-"
fi
stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x PhotoEdit >/dev/null 2>&1 || true
}
swift build --package-path "$ROOT_DIR/app" -c release --disable-sandbox
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR/app" -c release --disable-sandbox --show-bin-path)/$APP_NAME"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/CHANGELOG.md" "$APP_BUNDLE/Contents/Resources/CHANGELOG.md"
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
version=(root/'VERSION').read_text().strip()
info=dict(CFBundleExecutable='SuiTone',CFBundleIdentifier='local.photo-edit.app',CFBundleName='随心修图',
          CFBundleDisplayName='随心修图',CFBundlePackageType='APPL',CFBundleVersion=version,CFBundleShortVersionString=version,
          LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication',NSHighResolutionCapable=True,
          PhotoEditProjectRoot=str(root))
if (root/'app/Resources/AppIcon.icns').is_file():info['CFBundleIconFile']='AppIcon'
with (root/'dist/SuiTone.app/Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
case "$MODE" in
  --build-only) ;;
  run) stop_app; /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug|debug) stop_app; lldb -- "$APP_BINARY" ;;
  --logs|logs) stop_app; /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "SuiTone"' ;;
  --verify|verify) stop_app; /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo 'usage: build_and_run.sh [--build-only|--verify|--debug|--logs]' >&2; exit 2 ;;
esac
