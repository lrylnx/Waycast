#!/bin/bash
# 由 Resources/AppIcon.icon（macOS 26 Icon Composer 源文件）编译出 Resources/Assets.car。
#
# 为什么要这一步：
#   macOS 26 Tahoe 起，系统会检查 App 自带图标的形状。旧式 .icns（自带留白/投影的圆角矩形）
#   会被判定为「不合规」，**缩小约 20% 并塞进一个灰色托盘**（icon jail）。
#   要让图标满格显示，必须像 Safari / Xcode / ToDesk 那样提供 Assets.car + Info.plist 里的
#   CFBundleIconName（见 Resources/Info.plist）。
#
#   编译需要 Xcode 的 actool。产物 Assets.car 已入库，所以普通构建不需要装 Xcode；
#   只有改动图标素材（Resources/AppIcon.icon/）之后才需要重跑本脚本。
#
# 用法：
#   ./icon.sh          # 重新编译 Assets.car
#   ./icon.sh --preview  # 额外导出默认/深色/单色三种外观的预览 PNG
#
# 改图标素材的方法：用 Xcode 自带的 Icon Composer 打开 Resources/AppIcon.icon
#   （/Applications/Xcode.app/Contents/Applications/Icon Composer.app）
# 目录结构：AppIcon.icon/icon.json + AppIcon.icon/Assets/*.png
set -euo pipefail
cd "$(dirname "$0")"

ICON_SRC="Resources/AppIcon.icon"
LEGACY_ICNS="Resources/AppIcon.icns"
OUT_DIR="Resources"
APP_ICON_NAME="AppIcon"

if [ ! -f "${ICON_SRC}/icon.json" ]; then
  echo "✗ 找不到 ${ICON_SRC}/icon.json"
  exit 1
fi

if ! xcrun --find actool >/dev/null 2>&1; then
  echo "✗ 找不到 actool（需要安装 Xcode）。"
  echo "  已有 Resources/Assets.car 可直接使用，不必重编。"
  exit 1
fi

# ⚠️ actool 会往 --compile 目录里同时写 Assets.car 和一份它自己生成的 AppIcon.icns。
#    那份 icns 只有 256px 上限，会覆盖掉我们完整的旧版图标。
#    所以先编到临时目录，只把 Assets.car 取回来，AppIcon.icns 保持原样。
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

LEGACY_MD5_BEFORE="$(md5 -q "${LEGACY_ICNS}" 2>/dev/null || echo none)"

echo "==> actool 编译 ${ICON_SRC}"
xcrun actool "${ICON_SRC}" \
  --compile "${TMP}" \
  --output-format human-readable-text --notices --warnings --errors \
  --output-partial-info-plist "${TMP}/partial.plist" \
  --app-icon "${APP_ICON_NAME}" \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 14.0 \
  --platform macosx

cp "${TMP}/Assets.car" "${OUT_DIR}/Assets.car"

LEGACY_MD5_AFTER="$(md5 -q "${LEGACY_ICNS}" 2>/dev/null || echo none)"
if [ "${LEGACY_MD5_BEFORE}" != "${LEGACY_MD5_AFTER}" ]; then
  echo "✗ 警告：${LEGACY_ICNS} 被改动了，请检查（本脚本不应碰它）"
  exit 1
fi

echo "    ✓ ${OUT_DIR}/Assets.car  ($(du -h "${OUT_DIR}/Assets.car" | cut -f1))"

# 顺带打印系统期望的 Info.plist 键，方便核对
echo "    Info.plist 需要：CFBundleIconName = ${APP_ICON_NAME}"
echo "    当前值：$(/usr/bin/plutil -extract CFBundleIconName raw Resources/Info.plist 2>/dev/null || echo '（缺失！）')"

if [ "${1:-}" = "--preview" ]; then
  ICT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
  if [ ! -x "${ICT}" ]; then
    echo "✗ 找不到 ictool，跳过预览"
    exit 0
  fi
  mkdir -p "${TMP}/preview"
  for r in Default Dark TintedLight ClearLight; do
    "${ICT}" "${ICON_SRC}" --export-image \
      --output-file "${TMP}/preview/${r}.png" \
      --platform macOS --rendition "${r}" \
      --width 512 --height 512 --scale 1 \
      --design-generation 27 \
      --tint-color 0.25 --tint-strength 1.0 >/dev/null
  done
  mkdir -p build
  for r in Default Dark TintedLight ClearLight; do
    cp "${TMP}/preview/${r}.png" "build/icon-preview-${r}.png"
  done
  echo "    ✓ 预览图 → build/icon-preview-*.png"
fi

echo ""
echo "✅ 完成。运行 ./build.sh 重新组装 App。"
echo "   注意：装好后如果 Dock / 启动台还显示旧图标，重启一次 Dock 清缓存："
echo "   killall Dock"
