# TencentDB Agent Memory —— 搭建·操作手册

> 本文只给命令。**每一步含"探测 → 条件分支 → 执行"**。坑、原理、纠错、历史补丁全部在 `tencentdb-agent-memory搭建 - 补充说明.md`（下称「补充」）。
>
> 架构：**MemoryProxy（代理，:8096） + MemoryCore（内核，:8420）**。客户端把 API 地址指向 proxy。
>
> 密钥占位：`<idealab-token>` / `<sk-mem-admin-key>` 换成自己的值，**别写进任何被 git 跟踪的文件**。
>
> ⚠️ 全程遵守生命线原则：**不修改** `~/.zshrc` 与 `~/.claude/settings.json` 里指向 ducky 的既有值；`claude` 命令永远走 ducky。

---

## 0. 前置准备

### 0.1 Node —— 统一 v22

```sh
if ! command -v nvm >/dev/null 2>&1; then
  git clone https://github.com/nvm-sh/nvm.git ~/.nvm
  . "$HOME/.nvm/nvm.sh"
  nvm install 22
fi
. "$HOME/.nvm/nvm.sh"
nvm use 22
node -v          # 期望 v22.x
```

### 0.2 源码就位（fork 化的 submodule）

**关键事实**：`~/workspace/install/TencentDB-Agent-Memory` 是 `~` 主仓库的 **submodule**（在 `~/.gitmodules` 里登记）。fork 化之后仍然是 submodule，只是 url 从官方切成了个人 fork：

```
~/.gitmodules 中的 TDAI 段：
[submodule "workspace/install/TencentDB-Agent-Memory"]
        path = workspace/install/TencentDB-Agent-Memory
        url  = git@github.com:nileader/TencentDB-Agent-Memory.git   # fork 而非 TencentCloud
        branch = linux/tdai-lab-patches                             # 默认追踪工作分支
```

**架构说明**：本地不直接接官方仓库，而是通过个人 fork `nileader/TencentDB-Agent-Memory` 中转。上游变更 → GitHub 网页在 fork 里点 "Sync fork" → 本机拉 fork。

**submodule 内部**——分支模型（在 `~/workspace/install/TencentDB-Agent-Memory/` 里看到的）：

| 分支 | 追踪 | 角色 |
|---|---|---|
| `feat/server_team` | `origin/feat/server_team` (nileader/fork) | fork 镜像，clean，禁改 |
| `linux/tdai-lab-patches` | 无 | 干活分支：镜像 + 补丁 + pnpm 已应用 |
| remote `upstream` | 官方 TencentCloud（只读） | push URL 设为 `no_push`，防误推 |

**父仓库（`~`）看到的**：submodule pointer（gitlink，一个 160000 类型的 blob）指向 fork 上 `linux/tdai-lab-patches` 的最新 SHA。**每次 sync-from-fork.sh 之后**（submodule 里出了新提交），父仓库会显示 `M workspace/install/TencentDB-Agent-Memory`——需要 `git add + commit` 更新 pointer 才算落定（见 §7.11 尾部）。

首次搭建：

**情形 A · 已经有 `~` 主仓库、submodule 也已初始化**（当前机器）：什么都不用做。`~/.gitmodules` 的 url + `~/.git/modules/workspace/install/TencentDB-Agent-Memory/config` 里的 remote 已经切到 fork（用 `git submodule sync workspace/install/TencentDB-Agent-Memory` 幂等刷新即可）。

**情形 B · 换到一台新机器**：clone 主仓库时会带回 `.gitmodules` 里的 fork url，`git submodule update --init` 会直接从 fork 克隆到本地：

```sh
# 已经 clone 了 ~ 主仓库之后：
cd ~
git submodule update --init workspace/install/TencentDB-Agent-Memory
cd workspace/install/TencentDB-Agent-Memory

# 加官方为 upstream 只读（submodule 自身 remote，不是父仓库的事）
git remote add upstream git@github.com:TencentCloud/TencentDB-Agent-Memory.git
git remote set-url --push upstream no_push
git remote -v
#   origin    git@github.com:nileader/...          (fetch/push)
#   upstream  git@github.com:TencentCloud/...      (fetch)
#   upstream  no_push                              (push)

git checkout linux/tdai-lab-patches   # 已含补丁 + pnpm 白名单
git branch -a
```

**日常升级**：见 §7.11 —— `sync-from-fork.sh` 一条命令走完 fetch → patch → pnpm → snapshot commit；之后回到 `~` 主仓库 `git add workspace/install/TencentDB-Agent-Memory` 更新 pointer。

### 0.3 装依赖（pnpm，node 22 下）

```sh
. "$HOME/.nvm/nvm.sh" && nvm use 22
corepack enable
corepack prepare pnpm@latest --activate
pnpm -v          # 期望 >=12
```

写入 native 依赖白名单：

```sh
python3 - <<'PY'
from pathlib import Path
ROOT = Path.home() / "workspace/install/TencentDB-Agent-Memory"
ALLOW = ["esbuild", "better-sqlite3", "protobufjs", "tree-sitter-bash", "node-pty"]
DENY  = ["@google/genai", "es5-ext", "koffi", "mongodb-memory-server", "node-llama-cpp", "openclaw"]
for sub in ("MemoryCore", "MemoryProxy"):
    p = ROOT / sub / "pnpm-workspace.yaml"
    lines = ["allowBuilds:"]
    for k in ALLOW: lines.append(f"  {k}: true")
    for k in DENY:
        key = f"'{k}'" if any(c in k for c in "@/") else k
        lines.append(f"  {key}: false")
    p.write_text("\n".join(lines) + "\n")
    print(f"✓ {p}")
PY

cd ~/workspace/install/TencentDB-Agent-Memory/MemoryCore  && pnpm install
cd ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy && pnpm install
```

**如果** `pnpm install` 报 `ERR_PNPM_IGNORED_BUILDS` 且列出未在名单里的包，**则**把该包加入上面脚本的 `DENY` 数组重跑；**否则跳过**。

**验证 native 二进制齐备**（四行都应有输出）：

```sh
find ~/workspace/install/TencentDB-Agent-Memory -path "*esbuild/bin/esbuild" 2>/dev/null | head -1
find ~/workspace/install/TencentDB-Agent-Memory -path "*better-sqlite3*/build/Release/*.node" 2>/dev/null | head -1
ls ~/workspace/install/TencentDB-Agent-Memory/MemoryCore/node_modules/.bin/tsx
ls ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/node_modules/.bin/tsx
```

### 0.4 Ollama（embedding）

```sh
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
ollama pull bge-m3
curl -s http://localhost:11434/api/version    # 期望返回版本号
```

### 0.5 隔离数据目录

```sh
mkdir -p ~/.tdai-lab/data
```

---

## 1. 配置 MemoryCore

写 `~/.tdai-lab/tdai-gateway.yaml`：

```yaml
deployMode: standalone
stateBackend: local

server:
  port: 8420
  host: 127.0.0.1

data:
  baseDir: /home/admin/.tdai-lab/data

llm:
  baseUrl: "https://idealab.alibaba-inc.com/api/openai/v1"
  apiKey: "<idealab-token>"
  model: "Qwen3.8-Max-DogFooding"
  maxTokens: 32000
  timeoutMs: 300000

embedding:
  enabled: true
  provider: openai
  baseUrl: "http://localhost:11434/v1"
  apiKey: "ollama"
  model: "bge-m3"
  dimensions: 1024
  sendDimensions: false
  timeoutMs: 30000

memory:
  promptMode: chat
  capture: { enabled: true }
  extraction:
    enabled: true
    enableDedup: true
    maxMemoriesPerSession: 20
  persona:
    triggerEveryN: 3
    maxScenes: 10
  pipeline:
    everyNConversations: 3
    enableWarmup: true
    l1IdleTimeoutSeconds: 60
    l2DelayAfterL1Seconds: 30
    l2MinIntervalSeconds: 120
    l2MaxIntervalSeconds: 600
  recall:
    enabled: true
    maxResults: 5
    scoreThreshold: 0.01
    strategy: hybrid
    timeoutMs: 8000
  storeBackend: sqlite

skill:
  enabled: false
```

---

## 2. 配置 MemoryProxy

写 `~/.tdai-lab/proxy.yaml`：

```yaml
server:
  host: 0.0.0.0                     # ⚠️ 必须 0.0.0.0，见 §2.1 注释
  port: 8096
  forwardTimeoutMs: 600000

upstream:
  url: "http://127.0.0.1:8199"     # 验证期 mock；接主 CC 时切换到真 ducky（§7.1）
  apiKey: ""                        # 验证期留空；接主 CC 时灌 ducky token（§7.1）

log:
  file: ""
  level: debug
  backend: console

tdai:
  enabled: true
  endpoint: "http://127.0.0.1:8420"
  apiKey: "<sk-mem-admin-key>"     # §3.2 拿到 sk-mem 后回填
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true

auth:
  enabled: false

sessionInit:
  enabled: true
  debugForceIdentity:
    team_id: "tdai-lab"            # §7.2 会切换为 db 主键
    agent_id: "brain"              # §7.2 会切换为 db 主键
    task_id: "validate"

injection:
  enabled: true
  injectors:
    - tdai-memory

costGuard:
  enabled: false
redis:
  enabled: false
```

### 2.1 为什么 proxy 必须 `host: 0.0.0.0`（core 保持 127.0.0.1）

> **背景**：CC 在写 system prompt 时会把当前机器的**内网 IP**（如 `172.16.228.222`）作为 memory-bridge 的调用入口注入进来（见 `<tdai_memory_tools>` 里的 URL）。这个注入源在 CC / MCP 层，本手册不掌控。
>
> 若 proxy 仍绑 `127.0.0.1`：
> - `curl 127.0.0.1:8096` ✓ 通
> - `curl 172.16.228.222:8096` ✗ `Connection refused`
> - agent 在会话里调 `tdai_memory_search` 全失败——记忆栈"活着但没门"
>
> 因此**proxy 必须 `0.0.0.0`**，接受来自 loopback + 内网 IP 两侧的连接。
>
> **安全**：本机是阿里内网沙箱，暴露面仅限内网可达该机的调用方；且 proxy 上游 §6.1 Bearer 鉴权正常工作。
>
> **core 保持 `127.0.0.1`**：core (:8420) 只被 proxy 内部调用，不需要外露，维持最小暴露面。

---

## 3. 常驻托管脚本

三份脚本落 `~/.tdai-lab/`。写完后本文档不再出现手动 nohup。

### 3.1 `start-all.sh`

```sh
cat > ~/.tdai-lab/start-all.sh <<'SH'
#!/usr/bin/env bash
set -u

TDAI_HOME="$HOME/.tdai-lab"
REPO="$HOME/workspace/install/TencentDB-Agent-Memory"

export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh" >/dev/null
nvm use 22 >/dev/null || { echo "❌ nvm use 22 失败"; exit 1; }
echo "node=$(node -v)"

is_running() {
  local pidfile="$1"
  [[ -s "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

start_core() {
  if is_running "$TDAI_HOME/core.pid"; then
    echo "✓ core 已在跑 (pid=$(cat "$TDAI_HOME/core.pid"))"; return
  fi
  echo "→ 启动 core (:8420)"
  cd "$REPO/MemoryCore" || exit 1
  setsid nohup env TDAI_GATEWAY_CONFIG="$TDAI_HOME/tdai-gateway.yaml" \
    npx tsx src/gateway/server.ts >> "$TDAI_HOME/memory-core.log" 2>&1 </dev/null &
  disown
  sleep 5
  pgrep -af "tsx.*gateway/server.ts" | awk 'NR==1{print $1}' > "$TDAI_HOME/core.pid"
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8420/health || echo 000)
  echo "  core pid=$(cat "$TDAI_HOME/core.pid") health=$code"
}

start_mock() {
  if is_running "$TDAI_HOME/mock.pid"; then
    echo "✓ mock 已在跑 (pid=$(cat "$TDAI_HOME/mock.pid"))"; return
  fi
  [[ -f "$TDAI_HOME/mock-upstream.mjs" ]] || { echo "⚠ 无 mock-upstream.mjs，跳过"; return; }
  echo "→ 启动 mock (:8199)"
  setsid nohup node "$TDAI_HOME/mock-upstream.mjs" >> "$TDAI_HOME/mock.log" 2>&1 </dev/null &
  disown
  sleep 1
  pgrep -af "mock-upstream.mjs" | awk 'NR==1{print $1}' > "$TDAI_HOME/mock.pid"
  echo "  mock pid=$(cat "$TDAI_HOME/mock.pid")"
}

start_proxy() {
  if is_running "$TDAI_HOME/proxy.pid"; then
    echo "✓ proxy 已在跑 (pid=$(cat "$TDAI_HOME/proxy.pid"))"; return
  fi
  echo "→ 启动 proxy (:8096)"
  cd "$REPO/MemoryProxy" || exit 1
  setsid nohup node --import tsx/esm src/index.ts --config "$TDAI_HOME/proxy.yaml" \
    >> "$TDAI_HOME/proxy.log" 2>&1 </dev/null &
  disown
  sleep 4
  pgrep -af "node.*--import tsx/esm.*src/index.ts.*proxy.yaml" | awk 'NR==1{print $1}' > "$TDAI_HOME/proxy.pid"
  echo "  proxy pid=$(cat "$TDAI_HOME/proxy.pid")"
}

start_core
start_mock
start_proxy
echo
echo "─── 快速健康（判定以 status-all.sh 为准）───"
curl -sS -o /dev/null -w "core=%{http_code}\n" --max-time 3 http://127.0.0.1:8420/health
curl -sS -o /dev/null -w "proxy=%{http_code}\n" --max-time 3 http://127.0.0.1:8096/ 2>/dev/null || echo "proxy 无根路由 = 404 正常"
SH
chmod +x ~/.tdai-lab/start-all.sh
```

### 3.2 `stop-all.sh`

```sh
cat > ~/.tdai-lab/stop-all.sh <<'SH'
#!/usr/bin/env bash
set -u
TDAI_HOME="$HOME/.tdai-lab"

kill_by_pidfile() {
  local pidfile="$1" label="$2"
  if [[ -s "$pidfile" ]]; then
    local pid; pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      echo "→ 停 $label (pid=$pid)"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

kill_by_pattern() {
  local pattern="$1" label="$2"
  local pids
  pids=$(pgrep -af "$pattern" | awk '{print $1}' | tr '\n' ' ')
  if [[ -n "${pids// /}" ]]; then
    echo "→ 兜底杀 $label: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 1
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
}

kill_by_pidfile "$TDAI_HOME/proxy.pid" proxy
kill_by_pidfile "$TDAI_HOME/mock.pid"  mock
kill_by_pidfile "$TDAI_HOME/core.pid"  core

kill_by_pattern "node.*--import tsx/esm.*src/index.ts.*proxy.yaml" proxy
kill_by_pattern "mock-upstream.mjs" mock
kill_by_pattern "tsx.*gateway/server.ts" core

echo
ps -ef | grep -E "tsx.*gateway/server|mock-upstream|--import tsx/esm.*src/index" | grep -v grep || echo "无残留"
SH
chmod +x ~/.tdai-lab/stop-all.sh
```

### 3.3 `status-all.sh`

```sh
cat > ~/.tdai-lab/status-all.sh <<'SH'
#!/usr/bin/env bash
set -u
TDAI_HOME="$HOME/.tdai-lab"

probe() {
  curl -sS -o /dev/null -w "%{http_code}" --max-time 2 "$1" 2>/dev/null || echo 000
}

check() {
  local label="$1" pidfile="$2" pattern="$3" port="$4" health_url="$5"
  local pid=""
  [[ -s "$pidfile" ]] && pid=$(cat "$pidfile")
  local alive="✗"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    alive="✓"
  else
    pid=$(pgrep -af "$pattern" | awk 'NR==1{print $1}')
    [[ -n "$pid" ]] && alive="✓(pattern)"
  fi
  local port_code; port_code=$(probe "http://127.0.0.1:$port/")
  local port_open;  [[ "$port_code" == "000" ]] && port_open="✗" || port_open="✓"
  local http_code="$port_code"
  [[ -n "$health_url" ]] && http_code=$(probe "$health_url")
  printf "%-6s alive=%s pid=%-8s port(:%s)=%s http=%s\n" "$label" "$alive" "${pid:-N/A}" "$port" "$port_open" "$http_code"
}

check core  "$TDAI_HOME/core.pid"  "tsx.*gateway/server.ts"                            8420 http://127.0.0.1:8420/health
check mock  "$TDAI_HOME/mock.pid"  "mock-upstream.mjs"                                 8199 ""
check proxy "$TDAI_HOME/proxy.pid" "node.*--import tsx/esm.*src/index.ts.*proxy.yaml"  8096 ""
SH
chmod +x ~/.tdai-lab/status-all.sh
```

### 3.4 mock 上游

```sh
cat > ~/.tdai-lab/mock-upstream.mjs <<'EOF'
import http from "node:http";
import fs from "node:fs";
const CAP = "/home/admin/.tdai-lab/mock-headers.json";
http.createServer((req, res) => {
  let body = ""; req.on("data", c => body += c); req.on("end", () => {
    fs.appendFileSync(CAP, JSON.stringify({
      url: req.url, authorization: req.headers["authorization"] ?? null,
      "x-api-key": req.headers["x-api-key"] ?? null, bodyLen: body.length }) + "\n");
    if (req.method === "POST" && req.url.includes("messages"))
      fs.writeFileSync("/home/admin/.tdai-lab/mock-lastbody.json", body);
    res.writeHead(200, {"content-type":"application/json"});
    res.end(JSON.stringify({id:"msg_mock",type:"message",role:"assistant",
      content:[{type:"text",text:"ok from mock"}],usage:{input_tokens:12,output_tokens:6}}));
  });
}).listen(8199, "127.0.0.1", () => console.log("mock on 8199"));
EOF
```

### 3.5 起 + 探活

```sh
~/.tdai-lab/start-all.sh
sleep 10
~/.tdai-lab/status-all.sh
```

**期望**：`core alive=✓ http=200` / `mock alive=✓` / `proxy alive=✓ http=404`（proxy 无根路由 = 404 是活的证据）。

**如果** status 任一项 `alive=✗` 或 `http=000`，**则** `tail -50 ~/.tdai-lab/{memory-core,proxy,mock}.log`；**否则跳过**。

---

## 4. 初始化 admin key

### 4.1 写入 sk-mem

```sh
KEY="sk-mem-$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)"
RESP=$(curl -sS -X POST http://127.0.0.1:8420/v3/internal/meta/user/init-admin \
  -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
  -d "$(printf '{"username":"admin","user_key":"%s"}' "$KEY")")
echo "$RESP"

umask 077
printf '%s' "$KEY" > ~/.tdai-lab/user.key
cp ~/.tdai-lab/user.key ~/.tdai-lab/cc-authtoken.sk-mem
echo "user.key: $(cat ~/.tdai-lab/user.key)"
```

**期望**：`RESP` 里 `code=0`（新建）或 `code=409`（已存在）。

### 4.2 校验

```sh
curl -sS -X POST http://127.0.0.1:8420/v3/meta/auth/verify \
  -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
  -H "x-tdai-user-key: $(cat ~/.tdai-lab/user.key)" \
  -d "$(printf '{"user_key":"%s"}' "$(cat ~/.tdai-lab/user.key)")"
```

**期望**：`{"data":{"valid":true,"user":{...}}}`。

### 4.3 回填 proxy.yaml 的 `tdai.apiKey`

```sh
python3 - <<'PY'
import yaml, os
p = os.path.expanduser("~/.tdai-lab/proxy.yaml")
d = yaml.safe_load(open(p))
d["tdai"]["apiKey"] = open(os.path.expanduser("~/.tdai-lab/user.key")).read().strip()
open(p, "w").write(yaml.safe_dump(d, allow_unicode=True, sort_keys=False))
print("tdai.apiKey <- user.key")
PY

~/.tdai-lab/stop-all.sh && ~/.tdai-lab/start-all.sh && sleep 10 && ~/.tdai-lab/status-all.sh
```

---

## 5. 验证记忆闭环（mock 上游）

### 5.0 前置探测：upstream 必须是 mock

```sh
grep -E "^\s*url:" ~/.tdai-lab/proxy.yaml
```

- **如果**输出含 `127.0.0.1:8199`，**则**直接进 §5.1。
- **否则**（含 `ducky.code.alibaba-inc.com` 或其它），**执行切回 mock**：

```sh
sed -i.bak -E 's|^(\s*url:).*|\1 "http://127.0.0.1:8199"|' ~/.tdai-lab/proxy.yaml
~/.tdai-lab/stop-all.sh && ~/.tdai-lab/start-all.sh && sleep 10 && ~/.tdai-lab/status-all.sh
```

### 5.1 数据清零（可选）

**仅当**需要"从零重跑"（换语料 / 上一轮污染 / 换关键参数）**时执行**；**否则跳过**到 §5.2。

```sh
~/.tdai-lab/stop-all.sh
tar czf ~/tdai-lab-backup-$(date +%s).tar.gz -C ~/.tdai-lab data 2>/dev/null
rm -rf ~/.tdai-lab/data
rm -f  ~/.tdai-lab/memory-core.log ~/.tdai-lab/proxy.log ~/.tdai-lab/mock-upstream.log

# 保留项检查
ls -la ~/.tdai-lab/proxy.yaml ~/.tdai-lab/user.key ~/.tdai-lab/cc-authtoken.sk-mem \
        ~/.tdai-lab/start-all.sh ~/.tdai-lab/stop-all.sh ~/.tdai-lab/status-all.sh

~/.tdai-lab/start-all.sh
sleep 10
~/.tdai-lab/status-all.sh
```

清零后必须**重跑 §4.1 init-admin**（因为 db 已被清空）。

### 5.2 喂对话

```sh
FAKE="sk-ducky-FAKE-TOKEN"
send() { curl -sS -X POST http://127.0.0.1:8096/claude-code/default/v1/messages \
  -H "content-type: application/json" -H "authorization: Bearer $FAKE" -H "x-session-id: $1" \
  -d "$2" -o /dev/null -w "[$1 HTTP %{http_code}]\n"; }

send sess-1 '{"model":"claude-opus-4-8","max_tokens":64,"system":"You are Claude Code.","messages":[{"role":"user","content":"我叫银时，我只有 idealab 一个 key，禁止建议我切换 provider。"}]}'
send sess-1 '{"model":"claude-opus-4-8","max_tokens":64,"system":"You are Claude Code.","messages":[{"role":"user","content":"记住这条偏好。"}]}'
send sess-1 '{"model":"claude-opus-4-8","max_tokens":64,"system":"You are Claude Code.","messages":[{"role":"user","content":"以后新项目也照这个来。"}]}'
```

**期望**：三次都 HTTP 200。

### 5.3 验 L0 落盘

```sh
grep -aiE "conversation/add|L0-upsert" ~/.tdai-lab/memory-core.log | tail -10
```

**期望**：至少 3 行。

### 5.4 验 L1 抽取

```sh
sleep 30

grep -aiE "Extraction complete|L1 complete|extracted=[0-9]|stored=[0-9]" ~/.tdai-lab/memory-core.log | tail -10

curl -sS -X POST http://127.0.0.1:8420/v3/atomic/search \
  -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
  -H "authorization: Bearer $(cat ~/.tdai-lab/user.key)" \
  -d '{"query":"provider 切换","team_id":"tdai-lab","user_id":"u_debug","agent_id":"brain"}' \
  | head -c 1500; echo
```

**期望**：
- grep 至少 1 行 `Extraction complete: extracted=N`（N≥1）；
- `atomic/search` items 非空，含 instruction（提"provider/idealab"）+ persona（提"银时"）。

**如果** items 为空且 grep 也无 `Extraction complete`：**则** `sleep 60` 再看一次；仍空 → `tail ~/.tdai-lab/memory-core.log` 找 `429 / rate limit / LLM extraction failed`。

### 5.5 验跨会话召回

```sh
FAKE="sk-ducky-FAKE-TOKEN"
curl -sS -X POST http://127.0.0.1:8096/claude-code/default/v1/messages \
  -H "content-type: application/json" -H "authorization: Bearer $FAKE" -H "x-session-id: sess-NEW" \
  -d '{"model":"claude-opus-4-8","max_tokens":64,"system":"You are Claude Code.","messages":[{"role":"user","content":"建议我换个 provider 吗？"}]}' \
  -o /dev/null -w "[HTTP %{http_code}]\n"

wc -c ~/.tdai-lab/mock-lastbody.json
grep -aoE "银时|idealab|不要建议|tdai_profile_memory|Narrative Profile" ~/.tdai-lab/mock-lastbody.json | sort | uniq -c
```

**期望**：body 明显变大（数千字节以上），grep 命中"银时/idealab"等 —— 跨会话记忆成立。

### 5.6 主动召回通道

```sh
curl -sS -X POST http://127.0.0.1:8096/memory-bridge/v3/atomic/search \
  -H "content-type: application/json" -H "authorization: Bearer $FAKE" -H "x-session-id: sess-NEW" \
  -d '{"query":"用户能不能切换 provider"}' -w "\n[HTTP %{http_code}]\n" | head -c 800
```

**期望**：HTTP 200，返回归属 `team=tdai-lab/user=u_debug/agent=brain` 的原子。

### 5.7 人工核对沉淀质量

```sh
cd ~/workspace/install/TencentDB-Agent-Memory/MemoryCore
npm run build:read-local-memory
node ./bin/read-local-memory.mjs -d ~/.tdai-lab/data
node ./bin/read-local-memory.mjs -d ~/.tdai-lab/data -L L1
node ./bin/read-local-memory.mjs -d ~/.tdai-lab/data -L L0 -l 20
```

**期望**：L0 ≥ 6，L1 ≥ 2（含 instruction / persona 各 1）；L2=0、L3 不存在（首装样本量正常状态）。

L2/L3 也可直接 `cat`：

```sh
ls  ~/.tdai-lab/data/profiles/team%3Atdai-lab%7Cagent%3Abrain/ 2>/dev/null
cat ~/.tdai-lab/data/profiles/team%3Atdai-lab%7Cagent%3Abrain/persona.md 2>/dev/null
```

---

## 6. Proxy 源码 patch 汇总（一次性）

> 每次拉取 MemoryProxy 最新代码后，先来 review 这一节即可覆盖全部本地改动。
> 每个 patch 均遵循 **探测 → 条件分支 → 打 patch → 验证** 四步。
> 变量约定：`HANDLER=~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts`

### 6.0 首选路径：一键脚本（推荐）

**脚本随 fork 分发**，权威路径：

```sh
~/workspace/install/TencentDB-Agent-Memory/tdai-lab-scripts/apply-proxy-patches.sh
```

`~/.tdai-lab/apply-proxy-patches.sh` 是向后兼容的 **shim**，`exec` 转发到上面这份。两处任选其一即可。

**升级完整链路**（推荐用 §7.11 的 `sync-from-fork.sh` 一条命令走完）：

```sh
~/workspace/install/TencentDB-Agent-Memory/tdai-lab-scripts/sync-from-fork.sh
```

单独跑 patch（本机改完 fork 源码后想立刻验）：

```sh
~/.tdai-lab/apply-proxy-patches.sh              # 幂等打 §6.1/6.2/6.3 + 重启栈
~/.tdai-lab/apply-proxy-patches.sh --no-restart # 只打不重启
```

脚本行为：

- 依次幂等地打 §6.1 / §6.2 / §6.3 三条 patch（内部靠 marker 判重，重跑不双打）
- 打前自动备份原 `anthropicHandler.ts` 到 `${HANDLER}.bak-applypatches-<ts>`
- 打完自动 `stop-all.sh → start-all.sh → status-all.sh`（除非 `--no-restart`）

任一 patch 锚点匹配失败（说明上游把对应函数改结构了）→ 脚本非零退出并指向本节对应子节，此时**回落到下面 6.1 / 6.2 / 6.3 手动流程**逐条排查。

下面 §6.1 / §6.2 / §6.3 保留为**手动排查参考 + 原理留档**。

### 6.1 patch — Bearer 鉴权头（对齐 ducky 上游）

**背景**：ducky 上游只认 `Authorization: Bearer <key>`；proxy 默认发 `x-api-key`，会被 ducky 401。

#### 探测

```sh
grep -n 'authorization.*Bearer.*effectiveApiKey' \
  ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
```

- **如果**有输出（形如 `headers["authorization"] = \`Bearer ${effectiveApiKey}\`;`），**则跳过 6.1**。
- **如果**无输出，**则**执行下面 patch。

#### 打 patch

```sh
HANDLER=~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
cp "$HANDLER" "${HANDLER}.bak-preforkBearer-$(date +%Y%m%d)"

python3 - <<'PY'
import os
p = os.path.expanduser("~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts")
s = open(p).read()
old = '''  if (effectiveApiKey && !target.authHeaders) {
    headers["x-api-key"] = effectiveApiKey;
    delete headers["authorization"];
  }'''
new = '''  if (effectiveApiKey && !target.authHeaders) {
    headers["authorization"] = `Bearer ${effectiveApiKey}`;
    delete headers["x-api-key"];
  }'''
if old not in s:
    print("❌ 匹配失败：源码可能已改过 / 版本不同，需手工比对")
    raise SystemExit(1)
open(p, "w").write(s.replace(old, new))
print("✅ patch 6.1 done")
PY
```

#### 验证

```sh
grep -n 'authorization.*Bearer.*effectiveApiKey' \
  ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
```

**期望**：一行 `headers["authorization"] = \`Bearer ${effectiveApiKey}\`;`。

---

### 6.2 patch — 剥离 CC 客户端新字段 `output_config`

**背景**：CC 2.1.220+ 客户端在识别 base URL 是本地/新版 proxy 时会自动在 request body 里带 `output_config: {format: "text"}`；ducky 上游不认此字段，直接回 400 `Extra inputs are not permitted`，CC 端表现为 `API Error: Failed to parse JSON`。

**修法**：proxy 在 `buildUpstreamBody` 阶段（`sanitizeThinkingBlocks` 之前）把 `output_config` 从 body 中删掉，其他字段一字不动。

#### 探测

```sh
grep -n 'patch-6.2' ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
```

- **如果**有输出（形如 `// patch-6.2: ...`），**则跳过 6.2**。
- **如果**无输出，**则**执行下面 patch。

#### 打 patch

```sh
HANDLER=~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
cp "$HANDLER" "${HANDLER}.bak-stripOutputConfig-$(date +%Y%m%d)"

python3 - <<'PY'
import os
p = os.path.expanduser("~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts")
s = open(p).read()

# 锚点：sanitizeThinkingBlocks(result) 调用；在它之前浅 clone + 删 output_config
old = '''  const sanitized = sanitizeThinkingBlocks(result);
  return { body: sanitized.body, sanitizedCount: sanitized.removed };'''
new = '''  // patch-6.2: CC 2.1.220+ 客户端会自动加 output_config，ducky 上游不认，剥掉
  if ((result as Record<string, unknown>).output_config !== undefined) {
    result = { ...result };
    delete (result as Record<string, unknown>).output_config;
  }
  const sanitized = sanitizeThinkingBlocks(result);
  return { body: sanitized.body, sanitizedCount: sanitized.removed };'''

if "patch-6.2" in s:
    print("ℹ️ 已包含，跳过")
elif old not in s:
    print("❌ 匹配失败：buildUpstreamBody 结构变了，需手工比对")
    raise SystemExit(1)
else:
    open(p, "w").write(s.replace(old, new, 1))
    print("✅ patch 6.2 done")
PY
```

#### 验证

```sh
grep -nE 'patch-6\.2|output_config' ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
```

**期望**：连续几行显示 `patch-6.2` 注释 + `output_config` 判断 + delete 三行都在。

---

### 6.3 patch — 出站请求禁 zstd（accept-encoding 白名单）

**背景**：Node.js `fetch()` 只 auto-decompress `gzip / br / deflate`，**不支持 zstd**。ducky 上游在客户端 `Accept-Encoding` 包含 `zstd` 时会挑 zstd（response header `content-encoding: zstd`）。proxy 拿到的 body 已是 zstd 二进制；即便剥掉 `content-encoding` 转发给下游，客户端（CC/Bun undici）也只能拿到二进制流 → JSON.parse 首字节即失败，SSE `TextDecoder` 也切不出任何 event。表现：`Stream ended without receiving any events` + `Failed to parse JSON at <parse> (:0)`。

**修法**：`buildUpstreamHeaders` 强制设置 `accept-encoding: gzip, deflate, br`（不含 zstd），让 ducky 只用 fetch 认得的编码回。原客户端如果带了自己的 `Accept-Encoding`，会被这行覆盖。

#### 探测

先跑一次 §7.8 探测 5 的 probe，或直接 grep：

```sh
grep -n 'patch-6.3' ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
```

- **如果**有输出，**则跳过 6.3**。
- **如果**无输出，**则**执行下面 patch。

#### 打 patch

```sh
HANDLER=~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
cp "$HANDLER" "${HANDLER}.bak-noZstd-$(date +%Y%m%d)"

python3 - <<'PY'
import os
p = os.path.expanduser("~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts")
s = open(p).read()

# 锚点：buildUpstreamHeaders 末尾的 return headers 之前
old = '''  if (sessionKey) {
    headers["x-vertex-ai-session-id"] = sessionKey;
  }
  return headers;
}'''
new = '''  if (sessionKey) {
    headers["x-vertex-ai-session-id"] = sessionKey;
  }
  // patch-6.3: Node fetch 不解 zstd；ducky 支持 zstd。若不限制，上游返回 zstd 二进制
  // 会原样透传给客户端 → JSON.parse 失败 / SSE 切不出 event。锁死到 fetch 认的编码集。
  headers["accept-encoding"] = "gzip, deflate, br";
  return headers;
}'''

if "patch-6.3" in s:
    print("ℹ️ 已包含，跳过")
elif old not in s:
    print("❌ 匹配失败：buildUpstreamHeaders 结构变了，需手工比对")
    raise SystemExit(1)
else:
    open(p, "w").write(s.replace(old, new, 1))
    print("✅ patch 6.3 done")
PY
```

#### 验证

```sh
grep -nE 'patch-6\.3|accept-encoding' ~/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts
```

**期望**：显示 `patch-6.3` 注释 + `headers["accept-encoding"] = "gzip, deflate, br";` 两行。

---

### 6.4 打完所有 patch 后重启

```sh
~/.tdai-lab/stop-all.sh && ~/.tdai-lab/start-all.sh && sleep 10 && ~/.tdai-lab/status-all.sh
```

**期望**：MemoryCore / MemoryProxy 两个 UP。

---

## 7. 接入主 CC（可逆切换）

> **动手前必读**：
> - `~/.zshrc` / `~/.claude/settings.json` 里指向 ducky 的既有 `ANTHROPIC_*` 值**一字不改**。
> - 主 CC 命令 `claude` 全程走 ducky，作为生命线。
> - 本节新增独立命令 `claude-mem` 走 proxy。

### 7.1 上游切到真 ducky

**探测当前 upstream**：

```sh
grep -E "^\s*url:" ~/.tdai-lab/proxy.yaml
```

- **如果**含 `ducky.code.alibaba-inc.com` 且 `upstream.apiKey` 已非空，**则跳过**切换、进 §7.2 前置探测。
- **否则**执行下面切换。

```sh
sed -i.bak -E 's|^(\s*url:).*|\1 "https://ducky.code.alibaba-inc.com/proxy/v1"|' ~/.tdai-lab/proxy.yaml

[ -n "$ANTHROPIC_AUTH_TOKEN" ] || { echo "❌ ANTHROPIC_AUTH_TOKEN 为空，先 source ~/.zshrc"; return 1; }

python3 - <<PY
import yaml, os
p = os.path.expanduser("~/.tdai-lab/proxy.yaml")
d = yaml.safe_load(open(p))
d["upstream"]["apiKey"] = os.environ["ANTHROPIC_AUTH_TOKEN"]
open(p, "w").write(yaml.safe_dump(d, allow_unicode=True, sort_keys=False))
print("upstream.apiKey len =", len(d["upstream"]["apiKey"]))
PY

~/.tdai-lab/stop-all.sh && ~/.tdai-lab/start-all.sh && sleep 10 && ~/.tdai-lab/status-all.sh
```

**验证连通**：

```sh
grep -aE "server.starting|server.listening|connectivity.check" ~/.tdai-lab/proxy.log | tail -5
```

**期望**：
- `server.starting ... "upstream":"https://ducky.code.alibaba-inc.com/proxy"`
- `server.listening {"address":"0.0.0.0","port":8096}`（若日志里仍是 `127.0.0.1`，见 §2.1 —— 需要改 `server.host: 0.0.0.0`）
- `connectivity.check ... "upstream":"ok (XXms)"`

### 7.2 admin user 自检

**探测**：

```sh
DB=~/.tdai-lab/data/metadata/tdai_metadata_default/metadata.db
sqlite3 "$DB" "SELECT count(*) AS users FROM meta_users; SELECT count(*) AS keys FROM meta_user_keys;"
```

- **如果** users≥1 且 keys≥1，**则跳过**。
- **如果** users=0，**则**重跑 init-admin：

```sh
KEY=$(cat ~/.tdai-lab/user.key)
[ -n "$KEY" ] || { KEY="sk-mem-$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)"
  umask 077; printf '%s' "$KEY" > ~/.tdai-lab/user.key; }

curl -sS -X POST http://127.0.0.1:8420/v3/internal/meta/user/init-admin \
  -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
  -d "$(printf '{"username":"admin","user_key":"%s"}' "$KEY")"

umask 077
cp ~/.tdai-lab/user.key ~/.tdai-lab/cc-authtoken.sk-mem

curl -sS -X POST http://127.0.0.1:8420/v3/meta/auth/verify \
  -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
  -H "x-tdai-user-key: $KEY" \
  -d "$(printf '{"user_key":"%s"}' "$KEY")"
```

**期望**：`auth/verify` 返回 `{"data":{"valid":true,...}}`。

### 7.3 手工冒烟

```sh
SKMEM=$(cat ~/.tdai-lab/cc-authtoken.sk-mem)
SID="sess-smoke-$(date +%s)"

curl -sS -X POST http://127.0.0.1:8096/claude-code/default/v1/messages \
  -H "content-type: application/json" \
  -H "authorization: Bearer $SKMEM" \
  -H "x-session-id: $SID" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-opus-4-8",
    "max_tokens": 512,
    "system": "You are Claude Code.",
    "messages": [{"role":"user","content":"用一句话告诉我：如果我遇到当前 provider 限流，你会建议我做什么？"}]
  }' | tee ~/.tdai-lab/smoke-resp.json | head -c 1500; echo
```

**六条判据**：

```sh
# ① HTTP 层
python3 -c "
import json
d = json.load(open('/home/admin/.tdai-lab/smoke-resp.json'))
print('resp keys:', list(d.keys()))
print('content preview:', str(d.get('content'))[:400])
"
# ② + ③ 注入
grep -aiE "tdai|memory|inject|profile|recall" ~/.tdai-lab/proxy.log | tail -20
# ④ 沉淀
grep -aiE "conversation/add|L0-upsert" ~/.tdai-lab/memory-core.log | tail -5
# ⑤ core ACL
grep -acE "unauthorized: invalid_user_key" ~/.tdai-lab/proxy.log
# ⑥ hook-cache
grep -acE "FOREIGN KEY constraint failed" ~/.tdai-lab/proxy.log
```

| 判据 | 绿的标志 |
|---|---|
| ① 链路 | `resp keys` 含 `content`；`content preview` 是一段自然语言 |
| ② 记忆内容 | preview 里出现「银时」「idealab」「不建议切换 provider」至少一个 |
| ③ 注入过 | grep 里有 `text preview: <tdai_profile_memory>` 开头行 |
| ④ 沉淀 | 至少 1 行 `conversation/add` 或 `L0-upsert`，时间戳是本次 curl 之后 |
| ⑤ core ACL | 计数 = `0` |
| ⑥ hook-cache | 计数 = `0` |

**如果**判据③ preview 开头是 `<memory-tools-guide>` 而非 `<tdai_profile_memory>`，**则**执行 §7.4 确诊；**否则跳过** §7.4，进 §7.5。

### 7.4 hook preview 退化确诊（条件执行）

连做 3 次「冷启动 + 新 session」：

```sh
SKMEM=$(cat ~/.tdai-lab/cc-authtoken.sk-mem)
for i in 1 2 3; do
  echo "=========== 第 $i 次 ==========="
  ~/.tdai-lab/stop-all.sh
  ~/.tdai-lab/start-all.sh
  sleep 3

  SID="sess-smoke-cold-$i-$(date +%s)"
  curl -sS -X POST http://127.0.0.1:8096/claude-code/default/v1/messages \
    -H "content-type: application/json" \
    -H "authorization: Bearer $SKMEM" \
    -H "x-session-id: $SID" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-opus-4-8","max_tokens":128,"system":"You are Claude Code.","messages":[{"role":"user","content":"ping"}]}' \
    > /dev/null
  sleep 2
done

grep -aE 'text preview:.*(tdai_profile_memory|memory-tools-guide)' ~/.tdai-lab/proxy.log | tail -6
```

| `<tdai_profile_memory>` 行数 | `<memory-tools-guide>` 行数 | 判定 | 动作 |
|---|---|---|---|
| 3 | 0 | ✅ 通过 | 进 §7.5 |
| 1~2 | 1~2 | ⚠️ 启动竞态 | 把 `start-all.sh` 里 `sleep 5` 改成 `sleep 20`，再冷启 3 次 |
| 0 | 3 | ❌ 稳定退化 | 停止流程，查「补充 §14」 |

### 7.5 消除 `agent_not_found: brain` 404

**探测**：

```sh
grep -aE "agent_not_found.*brain" ~/.tdai-lab/proxy.log | tail -3
```

- **如果**无输出，**则跳过**本节，进 §7.6。
- **如果**有输出，**则**依次执行下面 4 步。

**Step 1：读 db 真实主键**

```sh
DB=~/.tdai-lab/data/metadata/tdai_metadata_default/metadata.db
sqlite3 "$DB" "SELECT team_id, name FROM meta_teams;"
sqlite3 "$DB" "SELECT agent_id, team_id, owner_user_id, name FROM meta_agents;"
```

**期望**：`team-xxxxxxxxxx|default-team` + `agt-xxxxxxxxxx|team-xxxxxxxxxx|usr-xxxxxxxxxx|default-agent-admin`。

**Step 2：把 debugForceIdentity 换成真实主键**

```sh
DB=~/.tdai-lab/data/metadata/tdai_metadata_default/metadata.db
TEAM=$(sqlite3 "$DB" "SELECT team_id FROM meta_teams LIMIT 1;")
AGENT=$(sqlite3 "$DB" "SELECT agent_id FROM meta_agents LIMIT 1;")
[ -n "$TEAM" ] && [ -n "$AGENT" ] || { echo "❌ team/agent 缺失，回 §7.2"; return 1; }

python3 - "$TEAM" "$AGENT" <<'PY'
import sys, yaml, os
team, agent = sys.argv[1], sys.argv[2]
p = os.path.expanduser("~/.tdai-lab/proxy.yaml")
d = yaml.safe_load(open(p))
ident = d.setdefault("sessionInit", {}).setdefault("debugForceIdentity", {})
ident["team_id"]  = team
ident["agent_id"] = agent
ident["task_id"]  = "validate"
open(p, "w").write(yaml.safe_dump(d, allow_unicode=True, sort_keys=False))
print("debugForceIdentity ->", ident)
PY
```

**Step 3：清 proxy 持久化 session 状态**

```sh
STATE=~/.memory-tencentdb/proxy-state/nottl
find "$STATE" -name binding.json 2>/dev/null | wc -l

~/.tdai-lab/stop-all.sh
rm -rf "$STATE"
~/.tdai-lab/start-all.sh && sleep 10 && ~/.tdai-lab/status-all.sh
```

**Step 4：以本次 SID 为锚点的两条验证**

```sh
SKMEM=$(cat ~/.tdai-lab/cc-authtoken.sk-mem)
SID="sess-smoke-verify-$(date +%s)"
curl -sS -X POST http://127.0.0.1:8096/claude-code/default/v1/messages \
  -H "content-type: application/json" -H "authorization: Bearer $SKMEM" \
  -H "x-session-id: $SID" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-opus-4-8","max_tokens":64,"system":"You are Claude Code.","messages":[{"role":"user","content":"ping"}]}' > /dev/null

# ① 本次 SID 是否走了 debugForceIdentity 分支（必须按 $SID 过滤，别 tail -3 会串历史）
grep -aE "session-init:cc.*DEBUG bypass.*force identity" ~/.tdai-lab/proxy.log | grep -F "$SID"

# ② 本次 SID 及其 request 是否还有 agent_not_found
grep -aE "agent_not_found" ~/.tdai-lab/proxy.log | grep -F "$SID"
```

**期望**：
- ① 恰好 1 行，含 `team=team-xxxx agent=agt-xxxx`（真主键、非 `tdai-lab/brain`）；
- ② 无输出。

**如果** ① 无输出或依然含 `team=tdai-lab agent=brain`，**则**回 Step 2 / Step 3 重跑；**否则**通过，进 §7.6。

> `~/.memory-tencentdb/proxy-state/` 清完后可能不重建（未被 flush 到磁盘也算正常），**不作为判据**。以上两条日志锚点足够。

### 7.6 确认 ducky 生命线在哪

```sh
env | grep -E "^ANTHROPIC_(BASE_URL|AUTH_TOKEN)" | sed 's/=.*/=<REDACTED>/'
grep -E "^export ANTHROPIC_(BASE_URL|AUTH_TOKEN)" ~/.zshrc | sed 's/=.*/=<REDACTED>/'
python3 -c "
import json,os
p=os.path.expanduser('~/.claude/settings.json')
if os.path.exists(p):
    d=json.load(open(p)).get('env',{})
    print({k:'<REDACTED>' for k in d if k.startswith('ANTHROPIC_')})
"
```

| zshrc 有值 | settings 有值 | 判定 | 动作 |
|---|---|---|---|
| ✅ | / | 生命线在 zshrc | **不改** zshrc，继续 §7.7 |
| ❌ | ✅ | 生命线在 settings | **不改** settings.json，继续 §7.7 |
| ❌ | ❌ | 仅当前终端有值 | 先在 zshrc 里补一份 ducky 直连，重开终端确认，再继续 §7.7 |

### 7.7 新增 `claude-mem` 命令

```sh
if ! grep -q "^claude-mem()" ~/.zshrc; then
cat >> ~/.zshrc <<'EOF'

claude-mem() {
  (
    export ANTHROPIC_BASE_URL="http://127.0.0.1:8096/claude-code/default"
    export ANTHROPIC_AUTH_TOKEN="$(cat ~/.tdai-lab/cc-authtoken.sk-mem)"
    exec claude "$@"
  )
}
EOF
fi

source ~/.zshrc
type claude-mem      # 期望：claude-mem is a shell function ...
type claude          # 期望：claude is /...（原样）
```

### 7.8 试跑

```sh
claude-mem
```

进入 CC 后问："我叫什么？我用哪个 provider？"

| 现象 | 判定 / 处置 |
|---|---|
| 答复含「银时」「idealab」「不换 provider」中至少一项 | ✅ 通过 |
| `API Error: Failed to parse JSON` | 见下方【故障 A: parse JSON】 |
| 完全不知道你是谁（能答，但没记忆内容） | 回 §7.3 复查判据②③ |

**另开一个新终端**（不要 `claude-mem`）跑 `echo $ANTHROPIC_BASE_URL` —— **期望为空**，证明生命线未污染。

#### 故障 A：`API Error: Failed to parse JSON`

**探测 1 — 上游是否报错**：

```sh
grep -aE "UPSTREAM_4xx|Extra inputs are not permitted|output_config" ~/.tdai-lab/proxy.log | tail -5
```

- **如果**看到 `output_config.format: Extra inputs are not permitted`，**则** patch 6.2 未打（或已被新版覆盖）→ 回 §6.2 打 patch。
- **否则**跳过这一路，转探测 2。

**探测 2 — proxy 与 upstream 是否完全正常**：

```sh
tail -80 ~/.tdai-lab/proxy.log | grep -aE "\[[0-9a-f]{8}\]" | grep -E "→ REQ|FORWARD status|✓ (STREAM|RESP) done|✗|error" | tail -20
```

- **如果**全是 `FORWARD status=200` 且 `✓ STREAM/RESP done`，**则**问题在 **CC 客户端 ↔ proxy** 这段，转探测 3。
- **否则**（有 `✗` 或非 200 上游），把这几行贴回会话。

**探测 3 — 直接 curl 打 proxy 端口能否拿到完整 SSE**：

```sh
AUTH="$(cat ~/.tdai-lab/cc-authtoken.sk-mem)"
curl -sS --http1.1 --noproxy '*' -o /tmp/proxy-smoke.txt \
  -w "http=%{http_code} ct=%{content_type} size=%{size_download}\n" \
  -X POST "http://127.0.0.1:8096/claude-code/default/v1/messages" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-opus-4-6","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"ping"}]}'
tail -c 200 /tmp/proxy-smoke.txt
```

- **如果**看到 `http=200 ct=text/event-stream…` 且末尾有 `data: [DONE]`，**则** proxy 完全 OK，CC 客户端才是问题所在，转探测 4。
- **否则**：curl 都失败说明 proxy 本身有问题，把 `/tmp/proxy-smoke.txt` 全文贴回来。

**探测 4 — 用 CC 客户端 debug 日志抓 CC↔proxy 的真实错误**：

```sh
mkdir -p ~/.tdai-lab/cc-debug
DBGFILE=~/.tdai-lab/cc-debug/claude-mem-$(date +%s).log

# 只这一次用带 debug 的方式启动 claude-mem，不要动 zshrc
(
  export ANTHROPIC_BASE_URL="http://127.0.0.1:8096/claude-code/default"
  export ANTHROPIC_AUTH_TOKEN="$(cat ~/.tdai-lab/cc-authtoken.sk-mem)"
  export ANTHROPIC_LOG=debug
  claude --debug --debug-file "$DBGFILE"
)
# 进 CC 后问一句 "我叫什么？我用哪个 provider？"，报错后退出

# 抓错误位置
grep -aE "parse|error|Error|400|401|500|abort|SSE|stream|content-type" "$DBGFILE" | tail -30
```

- 把上一步 `grep` 的输出贴回会话，我按错误定位下一步。
- **如果** debug 显示是 body 字段被拒（类似 §6.2）→ 需要新增 patch 6.x 剥字段。
- **如果** debug 显示 SSE 解析异常 / content-type 不符 → 贴回会话，可能要 patch proxy 响应转发路径（参考 §6.3 的定位方式：临时探针不落文档，助手带你打）。
- **如果** debug 显示鉴权 401 → 回 §7.2/§7.7 复查 `cc-authtoken.sk-mem` 与主 CC token 是否搞混。

### 7.9 记忆闭环真跑验证（真 ducky 上游 + `claude-mem` 客户端）

**目的**：§5 是 mock 上游冒烟；本节是**真链路**下走一遍「喂偏好 → 抽取 → 跨 session 召回 → 沉淀质量」，回答"这套记忆栈到底有没有感"。

#### 7.9.1 数据清零（可选）

**仅当**要"从零重跑"时执行；否则跳过到 7.9.2。

```sh
~/.tdai-lab/stop-all.sh
tar czf ~/tdai-lab-backup-$(date +%s).tar.gz -C ~/.tdai-lab data 2>/dev/null
rm -rf ~/.tdai-lab/data
rm -f  ~/.tdai-lab/memory-core.log ~/.tdai-lab/proxy.log
~/.tdai-lab/start-all.sh && sleep 10 && ~/.tdai-lab/status-all.sh
```

清零后必须重跑 §4.1 init-admin。

#### 7.9.2 喂对话（用 `claude-mem` 客户端，不是 curl）

`claude-mem` 进 REPL 后，**一次 session 内**连着问下面 5～8 条，每条等 CC 回话再输下一条：

```
我叫银时，我只有 idealab 一个 key，禁止建议我切换 provider。
我讨厌括号里放中文冒号，比如「银时（备注：xxx）」这种。
以后新项目也照这两条来。
我目前主要在做 TencentDB Agent Memory 的接入验证。
项目目录约定是 ~/workspace/install/xxx，安装类源码都放这里。
```

问完退出 REPL（Ctrl+D 或 `/exit`）。

**期望**：每条都能正常回话，无 `Failed to parse JSON`。

#### 7.9.3 验 L0 落盘

```sh
grep -aiE "write-l0|conversation/add|L0-upsert" ~/.tdai-lab/proxy.log ~/.tdai-lab/memory-core.log 2>/dev/null | tail -10
```

**期望**：至少 5 行（对应 5 条对话）。

#### 7.9.4 验 L1 抽取（异步，最长 warmup 后触发）

Warmup 序列 `1→2→4→N` + 空闲 flush（默认 600s）。若不想等 flush，可以先 stop-all 一次强制冷启后再验。

```sh
sleep 30  # 若无 L1 再 sleep 60 重试

grep -aiE "Extraction complete|L1 complete|extracted=[0-9]|stored=[0-9]" ~/.tdai-lab/memory-core.log | tail -10

# 直查 L1 索引
curl -sS -X POST http://127.0.0.1:8420/v3/atomic/search \
  -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
  -H "authorization: Bearer $(cat ~/.tdai-lab/user.key)" \
  -d '{"query":"provider 切换 括号 中文冒号","team_id":"tdai-lab","user_id":"u_debug","agent_id":"brain"}' \
  | head -c 2000; echo
```

**期望**：`Extraction complete: extracted=N` (N≥2)；`atomic/search` items 命中 instruction/persona 若干（"idealab / 不切 provider / 讨厌括号中文冒号"）。

**如果** `sleep 90` 后仍 0 抽取：`tail -60 ~/.tdai-lab/memory-core.log` 找 `429 / rate limit / LLM extraction failed`（idealab 限流约 5 请求/60s；触发就等一会儿再看）。

#### 7.9.5 跨会话召回（Phase 3 核心判据）

**开新终端**跑 `claude-mem`，问一条**必须命中记忆**的问题：

```
建议我换个 provider 吗？
```

**期望**：CC 回话时明确提到"idealab / 不换 provider / 银时"三者中至少两个 → **跨会话记忆成立**。

反向探针（同一新 session 内再问）：

```
括号里放中文冒号可以吗？
```

**期望**：CC 提醒你"你讨厌这种写法"。

**如果**新 session CC 完全"失忆"：

```sh
# 看 proxy 侧是否有做注入
grep -aE "injection\.pipeline\.done|tdai-profile-memory-injector|Narrative Profile|before-user|system\.suffix" ~/.tdai-lab/proxy.log | tail -20
```

- **如果**看到 `injection.pipeline.done blockCount>0` 但 CC 仍失忆 → 注入内容质量差（L1 抽的不准），回 7.10.4 看抽的什么
- **如果**看到 `blockCount=0` 或没有 `injection` 行 → proxy 未启用注入，检查 `~/.tdai-lab/proxy.yaml` 里 `injectL2L3: true` / `recallL1: true`

#### 7.9.6 人工核对沉淀质量

```sh
cd ~/workspace/install/TencentDB-Agent-Memory/MemoryCore
npm run build:read-local-memory 2>/dev/null || true
node ./bin/read-local-memory.mjs -d ~/.tdai-lab/data
node ./bin/read-local-memory.mjs -d ~/.tdai-lab/data -L L1
node ./bin/read-local-memory.mjs -d ~/.tdai-lab/data -L L0 -l 20

ls  ~/.tdai-lab/data/profiles/team%3Atdai-lab%7Cagent%3Abrain/ 2>/dev/null
cat ~/.tdai-lab/data/profiles/team%3Atdai-lab%7Cagent%3Abrain/persona.md 2>/dev/null
```

**期望**：
- L0 ≥ 5，L1 ≥ 2（instruction + persona 各 1）
- 首装 L3 persona **可能还没生成**（默认门槛：每 50 条新记忆触发一次）；量不够是正常的
- 人工读 L1 内容：是否**准确抽出偏好**（"用 idealab / 禁切 provider / 讨厌括号中文冒号"）？内容像不像自然语言的偏好卡片？

#### 7.9.7 结论

- ✅ **有感**：跨会话召回明确命中偏好；L1 内容读起来是"人话"式偏好卡片；耗时可接受
- ⚠️ **半通**：能召回但抽的偏好被拆碎、语义漂了；或注入生效但 CC 不采信 → 记录问题贴回讨论
- ❌ **无感**：完全不召回，L1 空或全是无关内容 → 记录抽取时 `memory-core.log` 里的具体报错

### 7.10 回退

- 撤销 `claude-mem`：删掉 `~/.zshrc` 里那段函数，`source ~/.zshrc`。
- 紧急止损：`claude` 命令直连 ducky 恒可用。

### 7.11 自检脚本（cc-statusline-tdai-check.sh）

**权威路径**：

```sh
~/workspace/common-toolkit/ai/memory/tdai/cc-statusline-tdai-check.sh          # 精简输出
~/workspace/common-toolkit/ai/memory/tdai/cc-statusline-tdai-check.sh -v       # 详细（含 e2e body 前 400B、每篇场景名）
~/workspace/common-toolkit/ai/memory/tdai/cc-statusline-tdai-check.sh --oneline # 单行、跳过 e2e，供 statusline 集成
```

Layer 0 环境指示 + 5 层自检覆盖：

| Layer | 内容 | FAIL 判据 |
|---|---|---|
| 0 · CC 环境变量指向 | 当前 shell 是否严格指向记忆代理：`ANTHROPIC_BASE_URL` == `http://127.0.0.1:8096/claude-code/default` **且** `ANTHROPIC_AUTH_TOKEN` == `~/.tdai-lab/cc-authtoken.sk-mem` 文件内容 | **不计 FAIL**（仅指示灯 on✓/off✗）。主 CC 常态即 off（走 ducky），只有 claude-mem 会话内才 on |
| 1 · 进程 & 端口 | core :8420、proxy :8096、mock :8199 pidfile 存活 + http 探活 | pid 不存在或 http=000 |
| 2 · 补丁 marker | `anthropicHandler.ts` 三条 marker（Bearer / patch-6.2 / patch-6.3） | 任一缺失 → 提示重跑 `apply-proxy-patches.sh` |
| 3 · 端到端调用 | 用 `cc-authtoken.sk-mem` 打真实 `/v1/messages`（`claude-opus-4-6` + 16 tokens） | http != 200 |
| 4 · L0 当日记录 | `data/records/<today>.jsonl` + `data/conversations/<today>.jsonl` 是否有行 | 空 → WARN（今天没 claude-mem 聊天是正常的） |
| 5 · L2 场景 + L3 persona | `data/profiles/**/scene_blocks/*.md` 篇数 + `persona.md` 份数 | 场景为 0 → WARN |

**退出码**：任一 FAIL → 1；只 WARN 或全通 → 0。可放到日常巡检脚本里。

**典型使用场景**：

- 换台机器：clone fork → `checkout linux/tdai-lab-patches` → 建 `~/.tdai-lab/` 骨架 → `cc-statusline-tdai-check.sh` 一次到底
- 每次 `sync-from-fork.sh` 之后：脚本尾行会提示跑自检
- proxy / core 报错时：先 `cc-statusline-tdai-check.sh -v` 定位是第几层坏，再针对性排查

**关键实现细节**：

- Layer 0 环境指示灯是**独立着色**（on→青✓ / off→红✗），刻意**不参与** `TDAI` 头标签的严重度判定、不计 PASS/FAIL、不改退出码。原因：主 CC 常态即 off，若计入 FAIL 会导致每个主 CC 会话的 statusline 都变红、退出码恒为 1。
- Layer 0 判据是**严格相等**：两个 env 必须同时精确等于目标值，任一不符（含大小写、末尾斜杠、token 不一致）即 off。token 走文件实时 `cat` 比对，文件为空也判 off。
- Layer 0 反映的是 **CC 进程启动时继承的环境变量**——statusline 子进程只能读到 CC 拉起那一刻的 env，中途在别的终端 `export` 不会改变已运行 CC 的显示。因此该灯的真实语义是「**本 CC 会话是不是用 `claude-mem` 起的**」。
- `--oneline` 单行格式：`TDAI [环境参数 on✓] [core✓ proxy✓ mock✓] [补丁 3/3] [今日 L0 N行 L2 N篇 L3 N份]`，已被 `~/workspace/common-toolkit/claude/statusline.sh`（软链 `~/.claude/statusline.sh`）在第 2 行集成，装了点亮、`timeout` 超时或脚本不存在则静默。`--oneline` 跳过 Layer 3 e2e（e2e curl 常耗 1-2s，不适合高频探针）。
- Layer 3 的 e2e 只支持 `claude-opus-4-6`（ducky 上游对 haiku / sonnet 返回 400，已实测），别改回 haiku
- Layer 4 的 today 用 `date +%F`，机器时区必须对（东八区）；不对就把 L0 写到另一个日期的文件里，会误报
- Layer 5 只按 `scene_blocks/` 路径 + `persona.md` 名字过滤，`profiles/` 下如果自定义了目录结构（例如导入了 imported_from），可能落进不同 team%3A... 目录，脚本会一起统计

**关联脚本**：

- `sync-from-fork.sh` —— fork 同步一条命令；见 §0.2 + §6.0
- `apply-proxy-patches.sh` —— 幂等打补丁；见 §6.0

**父仓库 pointer 更新（跟 `~` 主仓库同步）**：

`~/workspace/install/TencentDB-Agent-Memory` 是 `~` 的 submodule（详见 §0.2）。`sync-from-fork.sh` 在 submodule 内部 commit 出了新 SHA 后，父仓库看到的是 `M workspace/install/TencentDB-Agent-Memory`——**pointer 还是旧的**。刷 pointer：

```sh
cd ~
git add workspace/install/TencentDB-Agent-Memory
git status --short workspace/install/TencentDB-Agent-Memory
#   M  → 变成没有输出就代表 index 里对齐了新 SHA
# 是否 commit 由你自己决定；submodule 内部 SHA 已经在 fork 上（如果推了 fork）多机可拉
```

不推 fork 的时候，pointer commit 只在本机有意义（另一台机器不认这个未推的 SHA）；推了 fork 之后，pointer commit + `~` 主仓库推送才能让另一台机器 `git submodule update` 拿到同一份状态。

---

## 8. 验收 checklist

> 💡 推荐首选 `~/workspace/common-toolkit/ai/memory/tdai/cc-statusline-tdai-check.sh`，一条命令覆盖下面全部字段（见 §7.11）。下面这份保留为**手工逐条核对**版本，脚本 FAIL 时按行排查。

```sh
node -v                                                                          # v22.x
curl -s -o /dev/null -w "core=%{http_code}\n" http://127.0.0.1:8420/health       # 200
curl -s -o /dev/null -w "proxy=%{http_code}\n" http://127.0.0.1:8096/ 2>/dev/null # 404
curl -s -X POST http://127.0.0.1:8420/v3/meta/auth/verify \
  -H "x-tdai-service-id: default" -H "Content-Type: application/json" \
  -H "x-tdai-user-key: $(cat ~/.tdai-lab/user.key)" \
  -d "$(printf '{"user_key":"%s"}' "$(cat ~/.tdai-lab/user.key)")" \
  -o /dev/null -w "verify=%{http_code}\n"                                        # 200
tail -1 ~/.tdai-lab/mock-headers.json                                            # authorization=Bearer...
grep -ac "conversation/add" ~/.tdai-lab/memory-core.log                          # >0
grep -ac "银时" ~/.tdai-lab/mock-lastbody.json                                    # >0
```

---

## 9. 清理

```sh
~/.tdai-lab/stop-all.sh
rm -rf ~/.tdai-lab
rm -rf ~/.memory-tencentdb/proxy-state
```

---

> 配套：`用户视角tencentdb-agent-memory业务流程.md`（体验层）、`tencentdb-agent-memory搭建 - 补充说明.md`（坑与原理，本文所有 `补充 §N` 引用都在那）。
