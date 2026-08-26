#!/bin/bash
# 编译 → 安装到 /Applications → 重签 → 重启
#
# 屏幕录制授权只需要点一次。TCC 记的 designated requirement 是
#     identifier "dev.lizardbyte.app.Sunshine.patched" and ... certificate leaf[subject.CN] = "Apple Development: …"
# 里面没有 cdhash,所以二进制内容随便变,只要 bundle ID 和这张证书不变,授权就一直有效。
# 重新编译之后要做的只是重签——新编出来的二进制没签名,DR 才对不上。
#
# ⚠️ **换成另一张证书,上面这句就不成立了。** DR 匹配的是证书的 CN:续期换指纹但 CN 不变,
# 授权能活;换一张 CN 不同的证书,屏幕录制、辅助功能、PostEvent 三项**同时作废**。
# 而 Apple Development 证书是一年期,所以这件事迟早会发生——2026-08-22 就发生过一次。
#
# 症状极具迷惑性:Sunshine 说 `No screen capture permission!`,而系统设置里它明明勾着;
# 或者画面能串但键盘完全打不进去。**系统设置里那条旧记录点了没用**——它绑着旧证书的 DR,
# 必须删掉重加。完整的处置步骤(含查 csreq 绑哪张证书的 sqlite 命令)见
# traceone.io/notes/sunshine-macos-cert-and-rebase-traps.md。
#
# 换证书之后要做的:
#     tccutil reset ScreenCapture dev.lizardbyte.app.Sunshine.patched
#     tccutil reset Accessibility dev.lizardbyte.app.Sunshine.patched
#     tccutil reset PostEvent     dev.lizardbyte.app.Sunshine.patched
#     # (不带 .patched 的旧条目也要清一遍)
# 然后重启 Sunshine,到系统设置里用 + 重新添加 /Applications/Sunshine.app。
set -euo pipefail
cd "$(dirname "$0")"

# 签名身份不写进仓库——这个分支也在公开 fork 上。
# 放在 .sign-identity(已 gitignore)里,或者用环境变量覆盖:
#     security find-identity -v -p codesigning     # 查指纹
#     echo <SHA-1> > .sign-identity
IDENTITY="${SUNSHINE_SIGN_IDENTITY:-$(cat .sign-identity 2>/dev/null || true)}"

# 先确认这张证书现在还能签。不查的话,过期证书会让下面的重签步骤失败,
# 而那时 /Applications/Sunshine.app 已经被删掉重拷了——留下一个 ad-hoc 签名、
# bundle ID 还没改的半残安装,三项 TCC 授权全对不上。2026-08-22 就是这么坏的。
# `security find-certificate` 连过期的也返回,只有 `find-identity -v` 才只列有效的。
if [ -n "$IDENTITY" ] && ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "✗ .sign-identity 里的证书已失效(过期或私钥不在):$IDENTITY"
  echo
  echo "  当前可用的签名身份:"
  security find-identity -v -p codesigning | sed 's/^/  /'
  echo
  echo "  换证书会让屏幕录制/辅助功能/PostEvent 三项授权同时失效——"
  echo "  处置步骤见 traceone.io/notes/sunshine-macos-cert-and-rebase-traps.md"
  exit 1
fi

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
