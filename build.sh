#!/bin/bash
# Build Waycast.app from the SPM package and sign it with the stable local
# identity ("Waycast Developer"). A fixed signature keeps TCC permissions
# (screen recording, files & folders) across rebuilds — ad-hoc signing would
# invalidate them on every update.
#
# 2026-10-18：那张证书已不在钥匙串里了，本机改签过几次 ad-hoc —— 结果是
# 每次重新构建都要去「系统设置 › 隐私与安全性 › 屏幕录制」里**手动删掉旧条目
# 再重新添加**才能截图。现在重建了一张**自签**证书（CN=Waycast Developer，
# 有效期 10 年，codeSigning EKU），签出来的 designated requirement 是
#   identifier "com.waycast.macos" and certificate root = H"4e13aa…"
# —— 挂在**证书**上而不是 cdhash 上，所以以后重新构建**不用再授权**。
#
# 证书私钥备份：codesign/waycast_codesign.p12（口令 waycast-local，`codesign/`
# 已在 .gitignore 里，**绝不进公开仓库**）。换机器时：
#   security import codesign/waycast_codesign.p12 -k ~/Library/Keychains/login.keychain-db \
#            -P waycast-local -T /usr/bin/codesign
# 注意它不是 Apple 签发的 ⇒ 未公证、首次打开仍要右键「打开」绕 Gatekeeper，
# 这一点与以前的 ad-hoc 签名没区别。
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
