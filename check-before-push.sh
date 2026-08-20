#!/bin/bash
# 推之前跑一遍 CI 会做的静态检查。CI 一轮要 20 分钟,这里几十秒。
#
# 两样都是上游 CI 里会直接判失败的:
#   clang-format  common lint 用 --Werror,一处换行不对就算错误
#   doxygen       macOS 构建的 Build 步骤里跑,@param 对不上就算错误
#                 (2026-08-20 踩过:新函数的注释块插在了别人的注释和函数之间,
#                  于是 doxygen 认为它有 3 个 @param、而下一个函数没有文档)
set -uo pipefail
cd "$(dirname "$0")"
fail=0

echo "==> clang-format (CI 用 22.1.8)"
CF=$(command -v clang-format || echo /tmp/cfvenv/bin/clang-format)
if [ -x "$CF" ]; then
  for f in $(git diff --name-only origin/master...HEAD | grep -E '\.(cpp|h|mm|m)$'); do
    [ -f "$f" ] || continue
    if ! "$CF" --dry-run --Werror "$f" 2>/dev/null; then
      echo "    $f 格式不合规"; fail=1
    fi
  done
  [ $fail -eq 0 ] && echo "    全部合规"
else
  echo "    跳过:未装。python3 -m venv /tmp/cfvenv && /tmp/cfvenv/bin/pip install clang-format==22.1.8"
fi

echo "==> doxygen"
if command -v doxygen >/dev/null; then
  out=$(cd docs && doxygen Doxyfile 2>&1 | grep -iE "warning|error" | grep -vE "third-party|node_modules")
  if [ -n "$out" ]; then echo "$out" | head -20; fail=1; else echo "    无告警"; fi
else
  echo "    跳过:未装 (brew install doxygen)"
fi

[ $fail -eq 0 ] && echo "==> 可以推" || { echo "==> 有问题,先修"; exit 1; }
