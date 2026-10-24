#!/bin/zsh
# 发布构建：测试 → 打包 → 压缩为 zip，用于手动上传到 GitHub Releases（R15.6、R15.7）。
#
# 用法：TRANSPEEK_VERSION=0.1.0 TRANSPEEK_BUILD=1 Scripts/release.sh
#
# 发布版本必须使用固定的自签名证书，这样用户升级后屏幕录制权限仍然有效。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${TRANSPEEK_SIGN_IDENTITY:-TransPeek Self-Signed}"
VERSION="${TRANSPEEK_VERSION:-0.1.0}"

if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "✗ 未找到代码签名证书 \"$IDENTITY\"。发布版本不能使用临时签名，请先运行 Scripts/create_signing_cert.sh"
  exit 1
fi

echo "▸ swift test（TransPeekKit）"
(cd "$ROOT/Packages/TransPeekKit" && swift test)

TRANSPEEK_VERSION="$VERSION" "$ROOT/Scripts/bundle.sh"

ZIP="$ROOT/build/TransPeek-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/build/TransPeek.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$SHA  $(basename "$ZIP")"
echo "✓ 发布包：$ZIP"
echo "  上传到 GitHub Releases 时，请在说明中附上 SHA-256，并提示首次打开需要在“隐私与安全性”中点“仍要打开”。"
