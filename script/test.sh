#!/usr/bin/env bash
# Swift 与 Python 测试一起跑。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/swift_env.sh"
swift test --package-path "$ROOT_DIR/app" --disable-sandbox "${SWIFT_TEST_FLAGS[@]}" 2>&1 | grep -v "deprecated and will be removed"
"$HOME/.cache/photo-edit/venv/bin/python" -B -m unittest discover -s "$ROOT_DIR/engine/tests"
