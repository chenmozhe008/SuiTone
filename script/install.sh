#!/usr/bin/env bash
# 随心 AI 修图 SuiTone · 一键安装脚本
#
#   curl -fsSL https://raw.githubusercontent.com/chenmozhe008/SuiTone/master/script/install.sh | bash
#
# 可重复运行：已存在源码会更新，已存在虚拟环境和模型会跳过。
# 选项：
#   --no-models        不下载 AI 模型（约 420 MB）：分区、去杂物、放大不可用，调色和导出照常
#   --src <目录>       指定源码目录，默认 ~/SuiTone
#   --prefix <目录>    安装位置，默认 /Applications
#   --no-build         只准备环境，不编译不安装
#   -h, --help         显示帮助
set -euo pipefail

REPO_URL="${SUITONE_REPO:-https://github.com/chenmozhe008/SuiTone.git}"
APP_NAME="随心 AI 修图"
ASSET_ROOT="${HOME}/.cache/photo-edit"
VENV="${ASSET_ROOT}/venv"
SRC="${HOME}/SuiTone"
PREFIX="/Applications"
INSTALL_MODELS=1
DO_BUILD=1
PROXY="${SUITONE_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  提示：%s\033[0m\n' "$*"; }
die() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-models) INSTALL_MODELS=0 ;;
    --no-build) DO_BUILD=0 ;;
    --src) SRC="${2:?--src 需要目录}"; shift ;;
    --prefix) PREFIX="${2:?--prefix 需要目录}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
  shift
done

bold "随心 AI 修图 · 安装"

# ── 1. 系统检查 ──────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "只能在 macOS 上安装。"

OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "${OS_MAJOR}" -ge 14 ]] || die "需要 macOS 14 或更新版本，当前为 $(sw_vers -productVersion)。"
info "系统：macOS $(sw_vers -productVersion)（$(uname -m)）"

if [[ "$(uname -m)" != "arm64" ]]; then
  warn "当前为 Intel 处理器，尚未在 Intel 机器上验收；可以继续，但效果与速度未经验证。"
fi

command -v git >/dev/null 2>&1 || die "缺少 git。运行 xcode-select --install 安装命令行工具后重试。"

if ! xcode-select -p >/dev/null 2>&1; then
  die "缺少 Xcode 命令行工具。先运行 xcode-select --install，装完后重新执行本脚本。"
fi

# 依赖里的 onnxruntime 等需要 Python 3.10+；系统自带的 3.9 太旧。
PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      PYTHON="$(command -v "$candidate")"
      break
    fi
  fi
done
if [[ -z "${PYTHON}" ]]; then
  if command -v brew >/dev/null 2>&1; then
    info "未找到 Python 3.10+，用 Homebrew 安装 python@3.12（约 1 分钟）"
    brew install python@3.12 >/dev/null 2>&1 || die "Homebrew 安装 Python 失败，请手动安装 python@3.12 后重试。"
    PYTHON="$(brew --prefix)/bin/python3.12"
    [[ -x "${PYTHON}" ]] || die "找不到 Homebrew 安装的 python3.12。"
  else
    die "需要 Python 3.10 或更新版本。可先安装 Homebrew（https://brew.sh），再运行 brew install python@3.12。"
  fi
fi
info "Python：${PYTHON}（$("${PYTHON}" -V 2>&1)）"

# ── 2. 取源码 ────────────────────────────────────────────────
if [[ -d "${SRC}/.git" ]]; then
  info "更新源码：${SRC}"
  git -C "${SRC}" pull --ff-only --quiet || warn "源码更新失败，继续使用现有版本。"
elif [[ -f "${SRC}/script/install.sh" ]]; then
  info "使用已有源码：${SRC}"
else
  info "下载源码到 ${SRC}"
  mkdir -p "$(dirname "${SRC}")"
  git clone --depth 1 "${REPO_URL}" "${SRC}" --quiet || die "下载源码失败，请检查网络后重试。"
fi

APP_VERSION="$(cat "${SRC}/VERSION" 2>/dev/null || echo "未知")"
info "版本：${APP_VERSION}"

# ── 3. Python 环境 ───────────────────────────────────────────
if [[ -x "${VENV}/bin/python" ]]; then
  info "复用已有 Python 环境"
else
  info "创建 Python 环境：${VENV}"
  mkdir -p "${ASSET_ROOT}"
  "${PYTHON}" -m venv "${VENV}" || die "创建虚拟环境失败。"
fi

info "安装依赖（numpy、onnxruntime、opencv 等，首次约几分钟）"
"${VENV}/bin/python" -m pip install --quiet --upgrade pip
if ! "${VENV}/bin/python" -m pip install --quiet -r "${SRC}/engine/requirements.txt"; then
  die "依赖安装失败。国内网络可先设置代理：export https_proxy=http://127.0.0.1:7897 后重试。"
fi

# ── 4. 模型 ─────────────────────────────────────────────────
if [[ "${INSTALL_MODELS}" == "1" ]]; then
  bold "下载 AI 模型（共约 420 MB，已下载的会跳过）"
  fetch() { # fetch 地址 目标 最小字节数 说明
    local url="$1" dest="$2" min="$3" label="$4"
    mkdir -p "$(dirname "${dest}")"
    if [[ -f "${dest}" ]] && [[ "$(stat -f%z "${dest}")" -ge "${min}" ]]; then
      info "已存在：${label}"
      return 0
    fi
    info "下载：${label}"
    local curl_args=(-L --fail --silent --show-error -o "${dest}.part")
    [[ -n "${PROXY}" ]] && curl_args+=(-x "${PROXY}")
    if ! curl "${curl_args[@]}" "${url}"; then
      rm -f "${dest}.part"
      warn "${label} 下载失败，跳过（可在网络恢复后重新运行本脚本）"
      return 0
    fi
    mv "${dest}.part" "${dest}"
  }
  fetch "https://huggingface.co/Xenova/segformer-b2-finetuned-ade-512-512/resolve/main/onnx/model.onnx" \
        "${ASSET_ROOT}/segformer/model.onnx" 100000000 "分区识别模型（SEG）"
  fetch "https://huggingface.co/Xenova/segformer-b2-finetuned-ade-512-512/resolve/main/config.json" \
        "${ASSET_ROOT}/segformer/config.json" 5000 "分区识别配置"
  fetch "https://huggingface.co/Carve/LaMa-ONNX/resolve/main/lama_fp32.onnx" \
        "${ASSET_ROOT}/lama/lama_fp32.onnx" 190000000 "去杂物模型（LaMa）"
  fetch "https://huggingface.co/Xenova/swin2SR-classical-sr-x2-64/resolve/main/onnx/model.onnx" \
        "${ASSET_ROOT}/sr/swin2SR-classical-sr-x2-64.onnx" 50000000 "2 倍放大模型"
  fetch "https://huggingface.co/Xenova/swin2SR-realworld-sr-x4-64-bsrgan-psnr/resolve/main/onnx/model.onnx" \
        "${ASSET_ROOT}/sr/swin2SR-realworld-sr-x4-64-bsrgan-psnr.onnx" 50000000 "4 倍放大模型"
  if [[ ! -f "${ASSET_ROOT}/segformer/model.onnx" ]]; then
    warn "模型不完整，分区、去杂物、放大暂不可用；调色和导出不受影响。"
  fi
else
  info "已跳过模型下载：分区、去杂物、放大暂不可用"
fi

# ── 5. 编译与安装 ───────────────────────────────────────────
[[ "${DO_BUILD}" == "1" ]] || { bold "环境已准备好：${SRC}"; exit 0; }

bold "编译应用（首次约 3–8 分钟）"
if ! bash "${SRC}/script/build_and_run.sh" --build-only; then
  die "编译失败。请把上面的报错发到 https://github.com/chenmozhe008/SuiTone/issues 。"
fi

TARGET="${PREFIX}/${APP_NAME}.app"
info "安装到 ${TARGET}"
pkill -x SuiTone >/dev/null 2>&1 || true
mkdir -p "${PREFIX}"
rm -rf "${TARGET}"
cp -R "${SRC}/dist/SuiTone.app" "${TARGET}"
codesign --force --deep --sign - --identifier "local.photo-edit.app" "${TARGET}" >/dev/null 2>&1 || warn "临时签名失败，应用可能无法打开。"
xattr -dr com.apple.quarantine "${TARGET}" >/dev/null 2>&1 || true

bold "装好了"
info "应用：${TARGET}"
info "源码：${SRC}（应用从这里读取修图引擎，请勿删除；更新时重新运行本脚本）"
info "数据：${ASSET_ROOT}"
echo
info "首次打开：导入照片 → 右侧「调整」调色；要用对话修图，在「设置 → 对话和看图」中选择 AI 服务。"
if [[ "${PREFIX}" == "/Applications" ]]; then
  open -a "${TARGET}"
fi
