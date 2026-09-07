#!/bin/bash
# 我们叠在上游之上的功能,逐条点名检查还在不在。
#
# 为什么需要这个:2026-08-26 一次上游 rebase 把 src/platform/macos/input.cpp 从 756 行
# 换成 61 行(上游 #5368 改用 libvirtualhid),中文/emoji 输入就此消失。**编译照样通过,
# 一条错误日志都没有**,是用户发现打不出字才知道。rebase 的静态检查和编译都拦不住
# "文件被整体替换、我们的东西随之蒸发"这种情况——只有点名检查能。
#
# 数量只作参考,重点是"不能变成 0"。为 0 说明那个功能整块没了。
set -uo pipefail
cd "$(dirname "$0")" || exit 1
fail=0
check() {  # 名字  最少出现次数  符号  文件...
  local label="$1" min="$2" sym="$3"; shift 3
  local n=0 f
  for f in "$@"; do
    [ -f "$f" ] || continue
    n=$((n + $(/usr/bin/grep -c -- "$sym" "$f" 2>/dev/null || echo 0)))
  done
  if [ "$n" -lt "$min" ]; then
    printf "  ✗ %-24s %s 处 (要 >= %s)  符号 %s\n" "$label" "$n" "$min" "$sym"
    fail=1
  else
    printf "  ✓ %-24s %s 处\n" "$label" "$n"
  fi
}

echo "==> 功能存活检查"
check "中文/emoji 输入"   1 "unicode_native"           src/platform/macos/input.cpp src/platform/virtualhid_input.cpp
check "caret 跟随"        8 "caret"                    src/platform/macos/misc.mm src/platform/macos/misc.h src/nvhttp.cpp
check "熄屏唤醒"          2 "wake_display"             src/video.cpp
check "睡死结束会话"      2 "display_sleep_patience"   src/platform/macos/display.mm
check "指针跟随显示器"    1 "place_pointer_on_display" src/platform/common.h
check "libvirtualhid 指针" 1 "libvirtualhid"           .gitmodules

if [ "$fail" -ne 0 ]; then
  echo
  echo "!! 有功能不见了。上游很可能整体替换了某个文件——去看那个文件的 git log,"
  echo "   别只看编译过没过。参考 traceone.io/notes/sunshine-macos-cert-and-rebase-traps.md 坑二"
  exit 1
fi
echo "    全部在位"
