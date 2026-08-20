#!/bin/bash
# 编译 → 安装到 /Applications → 重签 → 重启
#
# 屏幕录制授权只需要点一次。TCC 记的 designated requirement 是
#     identifier "dev.lizardbyte.app.Sunshine" and ... certificate leaf[subject.CN] = "Apple Development: …"
# 里面没有 cdhash,所以二进制内容随便变,只要 bundle ID 和这张证书不变,授权就一直有效。
# 重新编译之后要做的只是重签——新编出来的二进制没签名,DR 才对不上。
set -euo pipefail
cd "$(dirname "$0")"

# 签名身份不写进仓库——这个分支也在公开 fork 上。
# 放在 .sign-identity(已 gitignore)里,或者用环境变量覆盖:
#     security find-identity -v -p codesigning     # 查指纹
#     echo <SHA-1> > .sign-identity
IDENTITY="${SUNSHINE_SIGN_IDENTITY:-$(cat .sign-identity 2>/dev/null || true)}"
if [ -z "$IDENTITY" ]; then
  echo "缺少签名身份。把 Apple Development 证书的 SHA-1 写进 .sign-identity,"
  echo "或者设 SUNSHINE_SIGN_IDENTITY 环境变量。用下面这条查:"
  echo "    security find-identity -v -p codesigning"
  exit 1
fi

echo "==> 编译"
ninja -C build

echo "==> 停掉正在跑的"
pkill -f "Sunshine.app/Contents/MacOS/Sunshine" 2>/dev/null || true
sleep 2

echo "==> 安装到 /Applications"
rm -rf /Applications/Sunshine.app
cp -R build/Sunshine.app /Applications/Sunshine.app

# bundle ID 必须改成 .patched。三项 TCC 授权(屏幕录制、辅助功能、PostEvent)都记在
# dev.lizardbyte.app.Sunshine.patched 这个身份上——当初这么改就是为了和上游原版分开授权。
# 2026-08-20 我直接把构建产物拷过来、没改这个 ID,结果画面能串但键盘打不进去:
# 少的正是 kTCCServicePostEvent,而合成键盘事件靠的就是它。
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.lizardbyte.app.Sunshine.patched' \
  /Applications/Sunshine.app/Contents/Info.plist

# 不要加 --options runtime:强化运行时会启用库验证,而 Sunshine 链接的
# Homebrew dylib 是 ad-hoc 签名的,Team ID 对不上会被 dyld 直接拒载。
echo "==> 重签"
codesign --force --sign "$IDENTITY" /Applications/Sunshine.app
codesign -v /Applications/Sunshine.app && echo "    签名有效"

echo "==> 启动"
open /Applications/Sunshine.app
sleep 8

if grep -q "No screen capture permission" <(tail -40 ~/.config/sunshine/sunshine.log); then
  echo "!!  屏幕录制授权没生效——检查证书是否换过,或 bundle ID 是否变了"
  exit 1
fi
grep -E "Found .* encoder|Configuration UI" ~/.config/sunshine/sunshine.log | tail -3
echo "==> 完成"
