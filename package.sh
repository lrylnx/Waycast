#!/bin/bash
# Package build/Waycast.app into a distributable zip, then verify the archive layout.
#
# 为什么需要这个脚本：
#   一个可运行的 macOS 程序必须是 "Waycast.app/Contents/..." 这样的 bundle 结构。
#   如果压缩时把 Contents 目录本身当作压缩包的根（比如在 Finder 里选中 Contents 后
#   右键压缩，或先 cd 进 .app 再 zip -r），解压出来就是一个普通文件夹，
#   Finder 不显示 App 图标，双击也无法运行。
#
#   这里统一用 ditto --keepParent 打包：--keepParent 会把 Waycast.app 这一层
#   保留为压缩包的根目录，从根源上避免打错包。脚本最后还会自动校验结构。
#
# 用法：
#   ./build.sh          # 先编译并组装 build/Waycast.app
#   ./package.sh        # 再打包成 dist/Waycast.zip

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Waycast"
APP_DIR="build/${APP_NAME}.app"
DIST_DIR="dist"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"

if [ ! -d "${APP_DIR}" ]; then
  echo "✗ 找不到 ${APP_DIR}，请先运行 ./build.sh"
  exit 1
fi

VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "${APP_DIR}/Contents/Info.plist")

echo "==> 打包 ${APP_DIR}（版本 ${VERSION}）"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# --keepParent 保证压缩包最外层是 Waycast.app，而不是它里面的 Contents
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "==> 校验压缩包结构"
FIRST_ENTRY=$(unzip -Z1 "${ZIP_PATH}" | head -n 1)
if [ "${FIRST_ENTRY}" != "${APP_NAME}.app/" ]; then
  echo "✗ 打包结构错误：压缩包最外层是 '${FIRST_ENTRY}'，应为 '${APP_NAME}.app/'"
  exit 1
fi
echo "    ✓ 最外层为 ${APP_NAME}.app/"

echo "==> 校验可执行权限"
if [ ! -x "${APP_DIR}/Contents/MacOS/${APP_NAME}" ]; then
  echo "✗ ${APP_NAME} 缺少可执行权限"
  exit 1
fi
echo "    ✓ 可执行权限正常"

echo "==> 校验代码签名"
codesign --verify --deep --strict "${APP_DIR}"
echo "    ✓ 签名有效"

echo ""
echo "✅ 完成：${ZIP_PATH}"
echo "   sha256: $(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo ""
echo "上传到 GitHub Release（v${VERSION}）："
echo "   gh release upload v${VERSION} \"${ZIP_PATH}\" --clobber"
