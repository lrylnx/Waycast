#!/bin/bash
# Build Waycast.app from the SPM package and sign it with the stable local
# identity ("Waycast Developer"). A fixed signature keeps TCC permissions
# (screen recording, files & folders) across rebuilds — ad-hoc signing would
# invalidate them on every update. The identity lives in the login keychain;
# backup cert: codesign/waycast_codesign.p12 (pass: waycast-local).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Waycast"
BUILD_DIR=".build"
APP_DIR="build/${APP_NAME}.app"
SIGN_IDENTITY="${WAYCAST_SIGN_IDENTITY:-Waycast Developer}"

# 图标素材改过就先重编 Assets.car（需要 Xcode；产物已入库，普通构建用不着）
if [ -f Resources/AppIcon.icon/icon.json ]; then
  if [ ! -f Resources/Assets.car ] || [ -n "$(find Resources/AppIcon.icon -type f -newer Resources/Assets.car 2>/dev/null | head -n1)" ]; then
    echo "==> 图标素材有更新，重新编译 Resources/Assets.car"
    ./icon.sh
  fi
fi

echo "==> swift build -c ${CONFIG}"
# --disable-sandbox: inside restricted environments swift-build's own
# sandbox-exec fails with "Operation not permitted"; the outer build
# environment already provides isolation.
swift build -c "${CONFIG}" --disable-sandbox

BIN=$(swift build -c "${CONFIG}" --show-bin-path --disable-sandbox)/${APP_NAME}

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
# macOS 26+ 的原生图标。缺了它 Tahoe 会把图标缩小 20% 塞进灰色托盘。
[ -f Resources/Assets.car ] && cp Resources/Assets.car "${APP_DIR}/Contents/Resources/Assets.car"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> codesign (identity: ${SIGN_IDENTITY})"
xattr -cr "${APP_DIR}" 2>/dev/null || true
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}"

echo "==> done: $(pwd)/${APP_DIR}"
echo "   首次运行需要授权：系统设置 › 隐私与安全性 › 屏幕录制"
echo ""
echo "发布打包请运行 ./package.sh（不要手动在 Finder 里压缩 .app，容易丢掉外层目录）"
