# Claude Code 知识库层 —— qmd 搭建·操作手册

> **本文只管把 qmd 从零搭起来**。搭好后的日常操作（加新笔记、重新摄入、健康检查）见 `04-日常运维-操作手册.md`。
> 纯 step-by-step 操作。**为什么这么做、碰到的坑、原理**统一见 `03-首次搭建文档-补充说明.md`（下称「补充」）。
>
> **本机的完整记忆栈定位（2026-09-17 起生效）**：
> - **qmd** —— 知识库层（本文档），检索你在两个 md 目录里手写的笔记原文。**主 `claude` 与 `claude-mem` 两个命令都启用**。
> - **对话记忆层**：主 `claude` 命令仅靠 Claude Code 原生 auto-memory（`~/.claude/projects/-home-admin/memory/`）；`claude-mem` 命令走 TencentDB Agent Memory 栈（见同目录 `tencentdb-agent-memory/` 手册），跨 session 自动召回。
> - cognee 已彻底卸载（数据、源码、MCP 配置、CLAUDE.md 硬约束、相关 memory 全清）。
>
> 环境：Linux / Mac 单机；md 两个目录 `~/workspace/work-context`、`~/workspace/work-agent/work-note`。需 Node ≥22。

---

## 0. 前置准备

### 0.1 Node（≥22）
```sh
git clone https://github.com/nvm-sh/nvm.git ~/.nvm
. "$HOME/.nvm/nvm.sh"
nvm install 24
node -v && npm -v          # node 应 ≥ v22
```

### 0.2 Python
```sh
sudo apt update && sudo apt install -y python3 python3-pip python3-venv
python3 --version
```

### 0.3 jq
```sh
sudo apt install -y jq
jq --version
```

### 0.4 Claude Code
```sh
npm i -g @anthropic-ai/claude-code
claude --version
```

---

## 1. 知识库层：qmd

### 1.1 装 qmd + 接入 Claude Code
```sh
npm install -g --allow-scripts=node-llama-cpp,tree-sitter-go,tree-sitter-python,tree-sitter-rust,tree-sitter-typescript,tree-sitter-javascript @tobilu/qmd
qmd --version

claude plugin marketplace add tobi/qmd
claude plugin install qmd@qmd
```
> `--allow-scripts` 必带，否则 native binary 静默跳过 → 见「补充 §7」。

### 1.2 绑定两个 md 目录为 collection
```sh
qmd collection add ~/workspace/work-context        --name work-context
qmd collection add ~/workspace/work-agent/work-note --name work-note
```

### 1.3 首次索引
```sh
export HF_ENDPOINT=https://hf-mirror.com     # 国内镜像
qmd update          # 文本索引（不走外网）
qmd embed           # 生成向量，首跑自动下 GGUF 模型（约几百 MB）
```
> 日常改完笔记：**默认由守护进程每 1 小时自动跑一轮 `update → embed → cleanup`**（脚本在 `~/workspace/common-toolkit/ai/memory/qmd/`）。`update` 增量同步文件增删改，`embed` 给新文件生成向量，`cleanup` 回收"文件已删/改但向量残留"的孤儿 chunk（`update`+`embed` 覆盖不到，需 `cleanup` 兜底）。首次搭建时启一次即可：`~/workspace/common-toolkit/ai/memory/qmd/qmd-auto-start.sh`。手动增量仍可随时跑：`qmd update && qmd embed`（`cleanup` 低频手动跑或靠守护进程自动跑）。详见 `04-日常运维-操作手册.md` §1。

### 1.4 验证
```sh
qmd query "本地知识库" -n 5     # 应返回笔记相关段落
```

---

## 2. 验证 MCP 工具可见
```sh
claude
/mcp      # 应列出 qmd（query/get/multi_get 三个工具）
```

在 `claude-mem` 会话下同样应可见 qmd（qmd 是 Claude Code 全局 MCP，不区分 claude / claude-mem 命令）：
```sh
claude-mem
/mcp
```

---

## 3. 常驻层：CLAUDE.md 召回规约

`~/.claude/CLAUDE.md` 里已有 `## 知识召回规约（人脑式）` 小节，负责告诉 agent 何时调 qmd。若从零开始，参考如下最小版本追加到 `~/.claude/CLAUDE.md`：

```markdown
## 知识召回规约（人脑式）

1. 遇到不确定的术语/主题，先用 qmd 的 query 工具翻我写过的笔记原文下钻细节。
2. 主 claude 命令：学到新结论想写入 auto-memory（`~/.claude/projects/-home-admin/memory/`）前，先问我 yes/no。
3. claude-mem 命令：TencentDB 自动沉淀，无需手动 remember。若显式想写偏好，仍以对话方式让我确认。
4. 每月初提醒我跑一次记忆卫生（qmd `qmd update && qmd embed`、TencentDB 侧看操作手册对应章节）。

我的知识库目录：~/workspace/work-context、~/workspace/work-agent/work-note
```

---

## 4.（可选）UserPromptSubmit Hook — 自动召回

> 可选强化层。基础方案只靠第 3 节即可。原理与注意见「补充 §11」。在 `~/.claude/settings.json` 配。
>
> ⚠️ **默认建议不配 Hook**：它在**每次发话时同步阻塞**跑 qmd（★实测即便 `--no-rerank` 也要 ~4.5s，带 rerank 直接 >40s 超时被丢），而你并非每句话都需要召回——等于高频白付、拖慢整体交互。关掉后召回能力**不丢**：agent 会按第 3 节规约**按需**调 qmd，交互反而更快。想要"发话即自动撒网"的体验再配（且必带 `--no-rerank`）。

### 4.1 qmd 自动召回 Hook（唯一 Hook）

整份 `~/.claude/settings.json` 的 `hooks` 段：
```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [
        { "type": "command",
          "command": "jq -r '.prompt' | xargs -I{} qmd query {} --json -n 10 --no-rerank" }
      ] }
    ]
  }
}
```
> `--no-rerank` 必带（尤其 Linux/CPU-only）：rerank 在 CPU 上极慢，实测会把 hook 拖到 >30s 超时被丢；加上后 ~3-4s（★实测）。手动 `qmd query` 想要更准可去掉它。

> **注意**：这份 hook 对**主 `claude` 与 `claude-mem` 两个命令均生效**（共享 `~/.claude/settings.json`）。对 `claude-mem`，qmd 召回和 TencentDB 自动沉淀是**互补关系**——qmd 补笔记原文，TencentDB 补历史对话偏好，见本文档第 7 节 "qmd × TencentDB 协同关系"。

---

## 5. 验收 checklist

每项都是**可直接粘贴执行**的命令 + 预期结果。全绿即搭建完成。

> **Mac 用户**：把 ①⑤⑥ 里的 `claude` 换成 `openclaude`（Mac 用的是 idealab 套壳 CLI `openclaude`）。

**① 工具链版本**
```sh
node -v && jq --version && claude --version
```
> 预期：3 行版本号，`node` ≥ v22，无 `command not found`。

**② qmd 在 PATH**
```sh
qmd --version
```
> 预期：打印版本号（如 `qmd 2.8.x`）。

**③ qmd 能检索到笔记原文**
```sh
qmd query "本地知识库" -n 3
```
> 预期：返回 3 条笔记片段，带文件路径和相关度分。若报 `no embeddings` → 回 1.3 补跑 `qmd embed`。

**④ qmd status 正常**
```sh
qmd status
```
> 预期：`Documents Total: N files indexed`（N 应等于两个 md 目录的文件数之和），两个 collection 都列出。

**⑤ MCP 工具在 Claude Code 里可见**
```sh
claude mcp list
```
> 预期：`qmd ✓ Connected`。

**⑥ CLAUDE.md 召回规约已追加**
```sh
grep -q "知识召回规约" ~/.claude/CLAUDE.md && echo "✓ 已追加" || echo "✗ 缺失，回第 3 节补"
```
> 预期：`✓ 已追加`。

**⑦（可选）hook 被触发**（配了第 4 节才验；没配跳过）

先验 hook 命令本身能跑（非侵入）：
```sh
echo '{"prompt":"本地知识库"}' | jq -r '.prompt' | xargs -I{} qmd query {} --json -n 3
```
> 预期：吐出 JSON 检索结果 = hook 里那条命令逻辑 OK。

再验 CLI 是否真在发话时触发它——用「标记文件法」（格式无关、铁证，测完还原）：
```sh
cp ~/.claude/settings.json ~/.claude/settings.json.bak
jq '.hooks.UserPromptSubmit[0].hooks += [{"type":"command","command":"date >> /tmp/hook_fired.log"}]' \
   ~/.claude/settings.json > /tmp/oc.json && mv /tmp/oc.json ~/.claude/settings.json
rm -f /tmp/hook_fired.log && claude -p "测试" >/dev/null && cat /tmp/hook_fired.log
mv ~/.claude/settings.json.bak ~/.claude/settings.json       # 还原
```
> 预期：`/tmp/hook_fired.log` 里出现时间戳 = hook 已触发。

---

## 6. 每月记忆卫生

qmd 侧：
```sh
qmd update && qmd embed          # 增量摄入新增/改动
qmd cleanup                      # 回收孤儿向量（守护进程已每 1h 自动跑，月度再手跑一次兜底）
qmd status                       # 检查索引健康（看 Orphaned 是否归零）
```

TencentDB 侧（若启用 `claude-mem`）：见 `tencentdb-agent-memory/tencentdb-agent-memory搭建 - 操作手册.md` 对应章节。

Claude Code 原生 auto-memory（`~/.claude/projects/-home-admin/memory/`）侧：让 Claude 在月初提醒你查一次矛盾/过期/孤儿。

---

## 7. qmd × TencentDB 协同关系（重要，看完再往下）

两者**职责正交，不重叠**：

| 层 | 数据 | 何时产生 | 何时命中 | 覆盖哪个命令 |
|---|---|---|---|---|
| **qmd** | 你手写的 md 笔记（96 篇左右） | 你写笔记 → 手动 `qmd update && qmd embed` | agent 按 CLAUDE.md 规约按需调 `qmd query` | 主 `claude` + `claude-mem` |
| **TencentDB L0/L1/L2/L3** | 你和 CC 的对话沉淀 | 每次 `claude-mem` 会话结束自动抽取 | 新 `claude-mem` session 启动时自动召回注入 | **仅 `claude-mem`** |
| **auto-memory** | Claude 主动询问 + 你 yes/no 确认过的偏好 | 显式 remember 时才写 | 每次 CC 会话开头自动载入 `MEMORY.md` 索引 | 主 `claude` + `claude-mem` |

**典型协同场景**：

- 用户在 `claude-mem` 里问 "去年那个 GPU 库存核对方案的边界条件是啥来着？"
  - agent 先看 TencentDB L1/L2 自动召回结果（对话里的历史结论）
  - 若结论指向某篇笔记，再调 `qmd query` 拉笔记原文的具体段落
  - 两者**接力**，不重复

- 用户在主 `claude` 里问同样问题
  - 无 TencentDB 召回
  - agent 直接调 `qmd query` 从笔记里找
  - 若曾在 auto-memory 里显式存过相关偏好，也一起用

**一句话**：qmd 是"翻笔记"，TencentDB 是"想起旧对话"，auto-memory 是"记住已确认过的规则"。三者互不替代。

---

> 配套：`01-用户视角使用流程.md`（用起来什么感觉）、`03-首次搭建文档-补充说明.md`（坑与原理）、`04-日常运维-操作手册.md`（搭好后的日常）、`tencentdb-agent-memory/tencentdb-agent-memory搭建 - 操作手册.md`（`claude-mem` 命令搭建）。
