#!/usr/bin/env bash
# sync-from-fork.sh
# 从 nileader/fork 拉取最新 → 更新镜像分支 → 重设工作分支 → 重放补丁 → pnpm install
# → snapshot commit → (可选) 重启 TDAI 栈
#
# 分支模型：
#   feat/server_team        —— 跟踪 origin/feat/server_team（nileader/fork 镜像，clean）
#   linux/tdai-lab-patches  —— 干活分支（补丁 + pnpm 已应用的物化快照）
#   upstream/feat/server_team —— 官方只读参考
#
# 使用：
#   sync-from-fork.sh              # 全套：拉 → 补丁 → 装 → 提交 → 重启栈
#   sync-from-fork.sh --dry        # 只显示差异，不动
#   sync-from-fork.sh --no-restart # 补丁 + 提交，不重启栈

set -euo pipefail

REPO="$HOME/workspace/install/TencentDB-Agent-Memory"
SCRIPTS="$REPO/tdai-lab-scripts"
APPLY="$SCRIPTS/apply-proxy-patches.sh"
LAB="$HOME/.tdai-lab"
WORK_BRANCH="linux/tdai-lab-patches"
MIRROR_BRANCH="feat/server_team"

DRY=0
RESTART=1
for arg in "$@"; do
  case "$arg" in
    --dry) DRY=1 ;;
    --no-restart) RESTART=0 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg (see --help)"; exit 1 ;;
  esac
done

cd "$REPO"

echo "==> pre-flight"
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作树不干净，先处理未提交改动："
  git status --short
  exit 1
fi
current=$(git branch --show-current)
if [ "$current" != "$WORK_BRANCH" ]; then
  echo "ℹ️  当前分支 $current，切到 $WORK_BRANCH"
  git checkout "$WORK_BRANCH"
fi

echo ""
echo "==> git fetch origin (nileader/fork)"
git fetch origin --prune
git fetch upstream --prune 2>/dev/null || echo "  (upstream fetch 失败，忽略)"

echo ""
echo "==> divergence check"
local_sha=$(git rev-parse "$MIRROR_BRANCH")
remote_sha=$(git rev-parse "origin/$MIRROR_BRANCH")
if [ "$local_sha" = "$remote_sha" ]; then
  echo "ℹ️  origin/$MIRROR_BRANCH 无新提交，nothing to sync"
  echo "   （强制重放补丁：$APPLY --no-restart）"
  exit 0
fi
echo "本地  $MIRROR_BRANCH: $local_sha"
echo "远端 origin/$MIRROR_BRANCH: $remote_sha"
echo ""
echo "新增提交（origin 领先本地）："
git log --oneline "$local_sha..$remote_sha" | head -20
echo ""
echo "变更文件（stat）："
git diff --stat "$local_sha..$remote_sha" | tail -20

if [ "$DRY" = 1 ]; then
  echo ""
  echo "==> --dry: 仅显示，不动"
  exit 0
fi

echo ""
echo "==> fast-forward $MIRROR_BRANCH → origin/$MIRROR_BRANCH"
git checkout "$MIRROR_BRANCH"
git merge --ff-only "origin/$MIRROR_BRANCH"

echo ""
echo "==> reset $WORK_BRANCH → $MIRROR_BRANCH (旧 snapshot 丢弃)"
git checkout "$WORK_BRANCH"
git reset --hard "$MIRROR_BRANCH"

echo ""
echo "==> apply patches (idempotent)"
if [ ! -x "$APPLY" ]; then
  echo "❌ $APPLY 不存在或不可执行"
  exit 1
fi
"$APPLY" --no-restart

if command -v pnpm >/dev/null 2>&1; then
  echo ""
  echo "==> pnpm install (MemoryProxy)"
  (cd "$REPO/MemoryProxy" && pnpm install --prefer-offline) || echo "⚠️  pnpm install 报错，稍后手工看"
else
  echo ""
  echo "⚠️  找不到 pnpm，跳过依赖安装（source $HOME/.nvm/nvm.sh && nvm use 后再跑）"
fi

echo ""
echo "==> snapshot commit"
git add -A
if git diff --cached --quiet; then
  echo "ℹ️  无 diff（补丁 idempotent，pnpm-lock 无变化），跳过提交"
else
  upstream_short=$(git rev-parse --short "origin/$MIRROR_BRANCH")
  upstream_subject=$(git log -1 --format='%s' "origin/$MIRROR_BRANCH")
  git commit -m "linux/tdai-lab-patches: sync from origin/$MIRROR_BRANCH @ $upstream_short

Upstream head: $upstream_subject

Patches re-applied by apply-proxy-patches.sh (§6.1/6.2/6.3).
DO NOT push to origin."
fi

if [ "$RESTART" = 1 ]; then
  echo ""
  echo "==> restart TDAI stack"
  "$LAB/stop-all.sh"
  "$LAB/start-all.sh"
  sleep 8
  "$LAB/status-all.sh" || true
else
  echo ""
  echo "ℹ️  --no-restart：未重启。手动：$LAB/stop-all.sh && $LAB/start-all.sh"
fi

echo ""
echo "✅ sync 完成。运行 $SCRIPTS/self-check.sh 做 5 层自检。"
