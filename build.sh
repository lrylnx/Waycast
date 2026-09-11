#!/bin/bash
# Build Waycast.app from the SPM package and ad-hoc sign it.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Waycast"
BUILD_DIR=".build"
APP_DIR="build/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN=$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "${APP_DIR}"

echo "==> done: $(pwd)/${APP_DIR}"
echo "   首次运行需要授权：系统设置 › 隐私与安全性 › 屏幕录制"
echo ""
echo "发布打包请运行 ./package.sh（不要手动在 Finder 里压缩 .app，容易丢掉外层目录）"
