#!/bin/bash
# 推之前跑一遍 CI 会做的静态检查。CI 一轮要 20 分钟,这里几十秒。
#
# 这三样上游 CI 都会直接判失败:
#   clang-format  common lint 用 --Werror,一处换行不对就算错误
#   doxygen       macOS 构建的 Build 步骤里跑,@param 对不上就算错误
#                 (2026-08-20 踩过:新函数的注释块插在了别人的注释和函数之间,
#                  于是 doxygen 认为它有 3 个 @param、而下一个函数没有文档)
#   shell 检查    common lint 会扫仓库里所有 .sh——包括这个脚本自己。
#                 它第一版就因为 SC2164 和 SC2015 把 lint 弄挂了:
#                 一个专门用来防 CI 失败的脚本,自己没过 CI。
#                 (注释里也不能让 "# shellcheck" 单独打头,那会被当成指令解析)
set -uo pipefail
cd "$(dirname "$0")" || exit 1
fail=0

echo "==> clang-format (CI 用 22.1.8)"
CF=$(command -v clang-format || echo /tmp/cfvenv/bin/clang-format)
if [ -x "$CF" ]; then
  cf_bad=0
  for f in $(git diff --name-only origin/master...HEAD | grep -E '\.(cpp|h|mm|m)$'); do
    [ -f "$f" ] || continue
    if ! "$CF" --dry-run --Werror "$f" 2>/dev/null; then
      echo "    $f 格式不合规"
      cf_bad=1
      fail=1
    fi
  done
  if [ "$cf_bad" -eq 0 ]; then
    echo "    全部合规"
  fi
else
  echo "    跳过:未装。python3 -m venv /tmp/cfvenv && /tmp/cfvenv/bin/pip install clang-format==22.1.8"
fi

echo "==> shellcheck"
if command -v shellcheck >/dev/null; then
  # 只查我们自己加的两个,上游那些脚本不归我们管
  if sh_out=$(shellcheck check-before-push.sh install-local.sh sync-upstream.sh 2>&1); then
    echo "    无问题"
  else
    echo "$sh_out" | head -20
    fail=1
  fi
else
  echo "    跳过:未装 (brew install shellcheck)"
fi

echo "==> doxygen"
if command -v doxygen >/dev/null; then
  # 只看我们改过的文件。上游自己的文件在本地会报一堆 @examples / @seealso
  # "unknown command"——那是他们在 Doxyfile 里定义的别名,本地 doxygen 版本不认识
  # 而已,不是问题也不该由我们修。第一版没限定范围,rebase 完 17 个上游提交之后
  # 立刻被这些告警淹了,还误报成"静态检查没过"。
  ours=$(git diff --name-only origin/master...HEAD | grep -E '\.(cpp|h|mm|m)$' | sed 's|.*/||' | sort -u)
  dox_all=$(cd docs && doxygen Doxyfile 2>&1 | grep -iE "warning|error" | grep -vE "third-party|node_modules")
  if [ -n "$ours" ]; then
    dox_out=$(echo "$dox_all" | grep -F "$ours" || true)
  else
    dox_out=""
  fi
  if [ -n "$dox_out" ]; then
    echo "$dox_out" | head -20
    fail=1
  else
    echo "    无告警"
  fi
else
  echo "    跳过:未装 (brew install doxygen)"
fi

if [ "$fail" -eq 0 ]; then
  echo "==> 可以推"
else
  echo "==> 有问题,先修"
  exit 1
fi
