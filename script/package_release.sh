#!/usr/bin/env bash
# 打发行包：把引擎和模型装进 App，产出可直接双击运行的 zip。
#
#   ./script/package_release.sh          # 打包，产物在 tmp/release/
#   ./script/package_release.sh --upload # 打包并创建 GitHub Release
#
# 前提：本机有 ~/.cache/photo-edit/venv（含 pyinstaller）和
#       ~/.cache/photo-edit/{segformer,lama,sr} 模型。模型不打进 git。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
ARCH="$(uname -m)"
VENV="${HOME}/.cache/photo-edit/venv"
ASSETS="${HOME}/.cache/photo-edit"
STAGE="${ROOT}/tmp/release-stage"
OUT="${ROOT}/tmp/release"
APP_NAME="随心 AI 修图"
UPLOAD=0
[[ "${1:-}" == "--upload" ]] && UPLOAD=1

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

bold "打包 随心 AI 修图 ${VERSION}（${ARCH}）"

[[ -x "${VENV}/bin/pyinstaller" ]] || die "缺少 pyinstaller：${VENV}/bin/pip install pyinstaller"
for d in segformer lama sr; do
  [[ -d "${ASSETS}/${d}" ]] || die "缺少模型目录 ${ASSETS}/${d}，先运行 script/install.sh 下载。"
done

# ── 1. 引擎打成独立可执行文件 ────────────────────────────────
bold "编译引擎（PyInstaller，约 1–2 分钟）"
rm -rf "${ROOT}/tmp/pyi"
# 用 onedir：onefile 每次启动都要解压 100 MB 以上，冷启动要十几秒，界面会先于引擎就绪。
( cd "${ROOT}/engine" && "${VENV}/bin/pyinstaller" --noconfirm --onedir --name suitone-engine \
    --distpath "${ROOT}/tmp/pyi/dist" --workpath "${ROOT}/tmp/pyi/build" --specpath "${ROOT}/tmp/pyi" \
    --hidden-import assistant --hidden-import ai_recommendation --hidden-import image_edit \
    --hidden-import api_providers --hidden-import anthropic_provider --hidden-import jimeng_edit --hidden-import ideogram_edit \
    --hidden-import suggestions --hidden-import smart --hidden-import recommendations \
    --hidden-import enhance --hidden-import geometry --hidden-import inpaint --hidden-import match \
    --hidden-import render --hidden-import info_bar --hidden-import lut --hidden-import vision \
    service.py >/dev/null 2>&1 ) || die "引擎编译失败，去掉 >/dev/null 看报错。"
ENGINE_DIR="${ROOT}/tmp/pyi/dist/suitone-engine"
[[ -x "${ENGINE_DIR}/suitone-engine" ]] || die "没有产出引擎可执行文件。"
info "引擎：$(du -sh "${ENGINE_DIR}" | cut -f1)"

# ── 2. 编译 App ─────────────────────────────────────────────
bold "编译 App"
bash "${ROOT}/script/build_and_run.sh" --build-only >/dev/null || die "App 编译失败。"

# ── 3. 组装包 ───────────────────────────────────────────────
bold "组装应用包"
rm -rf "${STAGE}" && mkdir -p "${STAGE}"
ditto "${ROOT}/dist/SuiTone.app" "${STAGE}/${APP_NAME}.app"
BUNDLE="${STAGE}/${APP_NAME}.app"
RES="${BUNDLE}/Contents/Resources"
mkdir -p "${RES}/engine-bin" "${RES}/models"
mkdir -p "${RES}/ThirdPartyNotices"
cp "${ROOT}/docs/licenses/SegFormer-LICENSE.txt" "${RES}/ThirdPartyNotices/SegFormer-LICENSE.txt"
ditto "${ENGINE_DIR}" "${RES}/engine-bin"
chmod +x "${RES}/engine-bin/suitone-engine"
for d in segformer lama sr; do
  ditto "${ASSETS}/${d}" "${RES}/models/${d}"
done
info "模型：$(du -sh "${RES}/models" | cut -f1)"

# 发行包里不再指向本机源码目录，改由包内引擎和模型提供
/usr/libexec/PlistBuddy -c "Delete :PhotoEditProjectRoot" "${BUNDLE}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString ${VERSION}" \
  -c "Set :CFBundleVersion ${VERSION}" \
  -c "Set :CFBundleIdentifier io.github.chenmozhe008.suitone" \
  "${BUNDLE}/Contents/Info.plist"
# 双击照片「打开方式」直接导入
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleDocumentTypes array" \
  -c "Add :CFBundleDocumentTypes:0 dict" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 图像" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" \
  -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Alternate" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.image" \
  "${BUNDLE}/Contents/Info.plist"

bold "签名（ad-hoc）"
codesign --force --deep --sign - --identifier "io.github.chenmozhe008.suitone" "${BUNDLE}" 2>&1 | tail -1
codesign --verify --strict "${BUNDLE}" || die "签名校验失败。"

# ── 4. 打包 zip ─────────────────────────────────────────────
bold "压缩"
mkdir -p "${OUT}"
ZIP="${OUT}/SuiTone-${VERSION}-${ARCH}.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${BUNDLE}" "${ZIP}"
info "产物：${ZIP}（$(du -h "${ZIP}" | cut -f1)）"

if [[ "${UPLOAD}" == "1" ]]; then
  bold "创建 GitHub Release"
  gh release create "v${VERSION}" "${ZIP}" \
    --title "随心 AI 修图 ${VERSION}" \
    --notes-file "${ROOT}/tmp/release-notes.md" 2>&1 | tail -3
fi

bold "完成"
