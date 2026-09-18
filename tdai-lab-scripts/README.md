# tdai-lab-scripts

本目录是 nileader/fork 之上的 **tdai-lab 本地私有脚本集**，跟随 fork 分发到多台机器，凡本机 clone 到 `~/workspace/install/TencentDB-Agent-Memory/` 都自动可用。

## 分支模型

| 分支 | 追踪 | 角色 |
|---|---|---|
| `feat/server_team` | `origin/feat/server_team` (nileader/fork) | fork 镜像，clean，禁改 |
| `linux/tdai-lab-patches` | 无 upstream | 干活分支：镜像 + 补丁 + pnpm 已应用 |
| `upstream/feat/server_team` (remote 只读) | 官方 TencentCloud | push URL = `no_push` 硬防误推 |

## 三个脚本

| 脚本 | 用途 |
|---|---|
| `apply-proxy-patches.sh` | 幂等把手册 §6.1/6.2/6.3 三条补丁打到 `MemoryProxy/src/anthropicHandler.ts`（Bearer / strip output_config / no-zstd） |
| `sync-from-fork.sh` | 一键工作流：拉 origin → 更新镜像 → 重设工作分支 → 重放补丁 → pnpm install → snapshot commit → (可选) 重启栈 |
| `self-check.sh` | 5 层自检：进程端口 / 补丁 marker / e2e / L0 记录 / L2 场景 |

## 日常工作流

```sh
# 1. GitHub 网页：nileader/fork ← 上游同步 (Sync fork 按钮)
# 2. 本机：
~/workspace/install/TencentDB-Agent-Memory/tdai-lab-scripts/sync-from-fork.sh
~/workspace/install/TencentDB-Agent-Memory/tdai-lab-scripts/self-check.sh
```

## 首装新机

```sh
git clone git@github.com:nileader/TencentDB-Agent-Memory.git ~/workspace/install/TencentDB-Agent-Memory
cd ~/workspace/install/TencentDB-Agent-Memory
git remote add upstream git@github.com:TencentCloud/TencentDB-Agent-Memory.git
git remote set-url --push upstream no_push
git checkout linux/tdai-lab-patches   # 已含补丁 + pnpm
cd MemoryProxy && pnpm install && cd ..
# 建 ~/.tdai-lab/ 骨架（proxy.yaml/user.key/凭证等）见搭建手册 §2-§5
tdai-lab-scripts/self-check.sh
```

## 关联

- 权威搭建手册：`~/workspace/tool/claude-brain-docs/tencentdb-agent-memory/tencentdb-agent-memory搭建 - 操作手册.md`
- `~/.tdai-lab/apply-proxy-patches.sh` 是本目录同名脚本的 **shim**（转发调用），保留是为向后兼容手册 §6 里的历史命令。
