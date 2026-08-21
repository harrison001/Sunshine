#!/bin/bash
# 每周把我们的改动重新叠到上游最新之上。
#
# 为什么用 rebase 而不是 merge:我们的改动本来就是"叠在上游之上的一层",
# rebase 一直保持这个形状,冲突小批量早暴露,而不是攒成一团。
#
# 必然会遇到的那个冲突:third-party/libvirtualhid 是子模块。上游会往前推它,
# 我们钉在自己 fork 的分支上,两边每次都打架。所以顺序必须是先 libvirtualhid、
# 后 Sunshine:先把我们那两个 macOS 提交叠到 libvirtualhid 上游最新之上,拿到新
# 的提交号,再用它解 Sunshine 这边的子模块冲突。反过来做的话,解完还是旧的。
#
# 默认只在本地做完并验证,不推。确认没问题再 --push。
set -uo pipefail
cd "$(dirname "$0")" || exit 1

PUSH=0
if [ "${1:-}" = "--push" ]; then PUSH=1; fi

SUB=third-party/libvirtualhid
say() { echo "$*"; }
die() { echo "!! $*"; exit 1; }

# ---------------------------------------------------------------- 前置检查
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "工作区不干净,先提交或 stash"
fi
[ "$(git rev-parse --abbrev-ref HEAD)" = "macos-work" ] || die "请先切到 macos-work"

say "==> 抓上游"
git fetch origin --quiet || die "fetch origin 失败"
(cd "$SUB" && git fetch origin --quiet) || die "fetch 子模块上游失败"

behind=$(git rev-list --count macos-work..origin/master)
say "    Sunshine 落后上游 $behind 个提交"
if [ "$behind" -eq 0 ]; then
  say "==> 已经是最新,无事可做"
  exit 0
fi

# ---------------------------------------------------------------- 先 libvirtualhid
say "==> 先把 libvirtualhid 叠上去"
sub_behind=$(cd "$SUB" && git rev-list --count HEAD..origin/master)
say "    子模块落后 $sub_behind 个提交"
if [ "$sub_behind" -gt 0 ]; then
  if ! (cd "$SUB" && git rebase origin/master >/tmp/sub-rebase.log 2>&1); then
    (cd "$SUB" && git rebase --abort 2>/dev/null)
    grep -iE "CONFLICT" /tmp/sub-rebase.log | head -5
    die "libvirtualhid 有冲突,要人工解。解完再跑一次这个脚本"
  fi
  say "    子模块 rebase 干净"
fi
NEW_SUB=$(cd "$SUB" && git rev-parse HEAD)
say "    子模块现在在 ${NEW_SUB:0:8}"

# ---------------------------------------------------------------- 再 Sunshine
say "==> 叠 Sunshine"
git branch -f _sync_backup macos-work            # 出事能退回来
if ! git rebase origin/master >/tmp/rebase.log 2>&1; then
  # 子模块冲突是预料之中的,用刚 rebase 好的那个提交解掉,继续。
  if grep -q "CONFLICT (submodule)" /tmp/rebase.log; then
    say "    子模块冲突(意料之中),取我们刚叠好的那个"
    git -C "$SUB" checkout "$NEW_SUB" --quiet
    git add "$SUB"
    if ! GIT_EDITOR=true git rebase --continue >>/tmp/rebase.log 2>&1; then
      git rebase --abort 2>/dev/null
      grep -iE "CONFLICT" /tmp/rebase.log | head -8
      die "还有别的冲突要人工解。备份在 _sync_backup"
    fi
  else
    git rebase --abort 2>/dev/null
    grep -iE "CONFLICT" /tmp/rebase.log | head -8
    die "有冲突要人工解。备份在 _sync_backup"
  fi
fi
say "    rebase 完成"

# ---------------------------------------------------------------- 验证
say "==> 静态检查"
./check-before-push.sh || die "静态检查没过。备份在 _sync_backup"

say "==> 编译"
if ! ninja -C build >/tmp/build.log 2>&1; then
  grep -iE "error|FAILED" /tmp/build.log | head -10
  die "编译失败。备份在 _sync_backup"
fi
say "    编译通过"

# ---------------------------------------------------------------- 推
if [ "$PUSH" -eq 1 ]; then
  say "==> 推送(rebase 改写了历史,必须 force-with-lease)"
  (cd "$SUB" && git push --force-with-lease fork macos-text-input) || die "推子模块失败"
  git push --force-with-lease nas macos-work || die "推 nas 失败"
  git push --force-with-lease fork macos-work || die "推 fork 失败"
  git push fork "origin/master:master" || say "    (fork/master 快进失败,不影响)"
  git branch -D _sync_backup --quiet
  say "==> 完成并已推送"
else
  say "==> 本地完成,已验证。确认后跑 ./sync-upstream.sh --push"
  say "    出事回退: git reset --hard _sync_backup"
fi
