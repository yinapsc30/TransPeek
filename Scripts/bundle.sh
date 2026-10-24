#!/bin/zsh
# 打包可直接运行的 build/TransPeek.app（R15.7）。
#
# 用法：
#   Scripts/bundle.sh                         # Release，arm64
#   TRANSPEEK_VERSION=0.2.0 Scripts/bundle.sh # 指定版本号
#
# 需要 Xcode 和 XcodeGen（brew install xcodegen）。
#
# 签名：钥匙串中存在 "TransPeek Self-Signed" 证书时使用它（重新构建后屏幕录制权限保持有效），
# 否则退回临时签名（ad-hoc），每次构建后都需要重新授权。创建证书：Scripts/create_signing_cert.sh
#
# 安装包只提供 Apple 芯片（arm64）版本（R15.5）。需要通用包时去掉下面的 ARCHS=arm64。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/TransPeek.app"
DERIVED="$ROOT/build/DerivedData"
IDENTITY="${TRANSPEEK_SIGN_IDENTITY:-TransPeek Self-Signed}"
VERSION="${TRANSPEEK_VERSION:-0.1.0}"
BUILD_NUMBER="${TRANSPEEK_BUILD:-1}"
ENTITLEMENTS="$ROOT/App/Resources/TransPeek.entitlements"

cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ 未找到 xcodegen，请先运行：brew install xcodegen"
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ xcodebuild 不可用。请安装 Xcode，并运行：sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

echo "▸ xcodegen generate"
xcodegen generate --quiet

echo "▸ xcodebuild Release（arm64，版本 $VERSION ($BUILD_NUMBER)）"
LOG="$ROOT/build/xcodebuild.log"
mkdir -p "$ROOT/build"
if ! xcodebuild -project TransPeek.xcodeproj -scheme TransPeek -configuration Release \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > "$LOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$LOG" | head -20
  echo "✗ 构建失败，完整日志：$LOG"
  exit 1
fi

echo "▸ 复制到 $APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INTERMEDIATE="$DERIVED/Build/Products/Release/TransPeek.app"
rm -rf "$APP"
ditto "$INTERMEDIATE" "$APP"
# 删除并注销 DerivedData 里的中间产物。它是临时签名的，如果留着，系统按 Bundle ID 重新打开应用时
# （例如授权后系统提示“退出并重新打开”）可能会打开这一份，而屏幕录制授权记录的是 build/TransPeek.app 的签名，
# 导致授权一直不生效。
"$LSREGISTER" -u "$INTERMEDIATE" >/dev/null 2>&1 || true
rm -rf "$INTERMEDIATE"

echo "▸ 签名"
# 自签名证书不受系统信任，find-identity -v 会把它隐藏，因此用 find-certificate 查找；codesign 可以正常使用它
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  echo "  使用证书：$IDENTITY"
else
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
  echo "⚠︎ 未找到证书 \"$IDENTITY\"，已使用临时签名。重新构建后需要重新授予屏幕录制权限。"
  echo "  运行 Scripts/create_signing_cert.sh 创建固定证书，之后的构建不会再丢失权限。"
fi
codesign --verify --deep --strict "$APP"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
echo "  架构：$(lipo -archs "$APP/Contents/MacOS/TransPeek")"
echo "✓ 完成：$APP"
echo "  运行：open \"$APP\""
