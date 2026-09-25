# TencentDB Agent Memory —— 搭建·补充说明（坑与原理）

> 配套 `tencentdb-agent-memory搭建 - 操作手册.md`。操作手册只给命令，本文解释**为什么这么做、碰到的坑、背后原理**。
> 编写原则：**按需增补**——银时按操作手册跑到哪里碰到坑，就把根因/对策写进这里对应小节。未踩到的章节保留占位标题，不硬写。
> 章节编号与操作手册里的「见补充 §N」指向对应，请勿随意重排。

---

## §1. 转发·透传链路（占位）

> 待补：`upstream.apiKey:""` 让入站 Bearer 原样透传的实现路径（`anthropicHandler.ts` 里 `buildUpstreamHeaders` 的分支），以及为什么这条能保住 ducky 的 Bearer-only 鉴权。

---

## §2. 关鉴权 + 静态身份的"无 fork 单用户配方"（占位）

> 待补：`auth.enabled:false` 的作用范围（proxy 入站校验，不影响 core 数据面）、为什么必须搭配 `sessionInit.debugForceIdentity` 才能让沉淀/召回落到稳定命名空间。

---

## §3. 身份门禁：为什么 debugForceIdentity 是唯一稳态方案（占位）

> 待补：core 侧对 `team_id/agent_id/user_id` 的空值容忍度、缺身份时记忆去哪、为什么 POC 不走 core 的 issue-key 流程。

---

## §4. 三条密钥通道（占位）

> 待补：转发链路（入站 Bearer 透传）/ 沉淀链路（`tdai.apiKey` = admin sk-mem）/ 召回链路（同 sk-mem）—— 三者互相独立，混淆会产生什么症状。

---

## §5. 注入只往 `system` 里塞（占位）

> 待补：`tdai-memory` injector 的注入点（`system` 字段头部），空 system 时静默跳过的现象、为什么不能往 messages 里塞。

### 5.2 §4.2 两处坑：`grep -a` 与 `user_id` 的"两个域" ★首装实测

现象（首装踩过）：
- `grep -iE ... memory-core.log`  只回一行 `Binary file /home/admin/.tdai-lab/memory-core.log matches`，不给具体行。
- `curl .../v3/atomic/search  -d '{...,"user_id":"u_debug",...}'`  返回 `{"code":0,"data":{"items":[]}}`，看起来什么都没抽到；改成 admin uid `usr-opzvurfrev` 后**依然空返**，最终发现要用回 `u_debug` 才命中——一度以为 `u_debug` 是占位。

#### 坑一：grep 二进制误判
`memory-core.log` 里混了终端色码 / 进度条 / 少量非 UTF-8 字节，GNU grep 默认把这类文件识别成 binary → 只打印一行 "matches" 而不打印匹配内容。加 `-a`（`--text`）强制按文本处理即可，日志本来就是给人看的。操作手册 4.2 / 4.3 / 验收 ⑤⑥ 涉及日志/body 的 grep 已统一加 `-a`。

#### 坑二：`user_id` 有**两个域**，别混

首装最容易翻车的一点。TencentDB 里有两个都叫 `user_id` 的东西，值可以完全不同：

| 域 | 值来自 | 典型形态 | 干嘛用 |
|---|---|---|---|
| **鉴权 uid** | `init-admin` 响应的 `data.user_id` / `verify` 响应的 `data.user.user_id` | `usr-opzvurfrev` | 校验 sk-mem 是不是这个 admin 账号的合法凭证 |
| **记忆命名空间键** | proxy `sessionInit.debugForceIdentity.user_id`（未设时默认 `u_debug`） | `u_debug` | L0/L1/L2/L3 全套记忆的挂载键；`atomic/search` 的过滤字段 |

两者**没有联动**——admin 账号只负责数据面鉴权，记忆本身按 `team_id/user_id/agent_id` 三元组落盘和查询。本机实测：

- L1 succeeded log 里 `"user_id":"u_debug"` → 记忆确实落在 `u_debug` 命名空间。
- `atomic/search` 传 `user_id: "u_debug"` → 200 命中两条原子（`instruction: 银时禁止切 provider` + `persona: 用户叫银时`）。
- 传 `user_id: "usr-opzvurfrev"`（admin uid）→ 200 但 `items:[]`——因为这个命名空间下压根没写过任何东西。

**结论**：
- 操作手册 2.2 只存 `~/.tdai-lab/user.key`（sk-mem），**不再存** `user.id` —— admin uid 除了鉴权没别的用，存下来只会诱导后续查询误用。
- 操作手册 4.2 的 `user_id` 就是**字面量 `u_debug`**，不是占位——它是 proxy 3.1 配置里 `sessionInit.debugForceIdentity` 没显式设 `user_id` 时的**默认值**。
- 想改成别的（比如 `yinshi`）：在 proxy.yaml 的 `debugForceIdentity` 里加 `user_id: "yinshi"`，重启 proxy，之后新写入的记忆就落 `yinshi` 命名空间；老的 `u_debug` 数据不会自动搬。

#### 附坑 A：`init-admin` vs `verify` 响应结构不一致
两个 endpoint 都在返 user 信息，但路径不同：
- `POST /v3/internal/meta/user/init-admin` → `data.user_id`（顶层直挂）
- `POST /v3/meta/auth/verify`              → `data.user.user_id`（多包一层 user 对象）

写工具脚本抽 admin uid 时要留心（虽然按上面结论我们不再存这个值，但你未来若要用到它，别只按一条路径抽）。

#### 附坑 B：变量名千万别用 `UID`
`UID` 是 zsh/bash 的**只读内置变量**（当前用户的 numeric uid），赋值会触发 `failed to change user ID: operation not permitted`（zsh 会尝试真去 setuid）。同类雷区：`PWD`、`SHELL`、`PPID`、`GROUPS`、`HOME`、`EUID`。

#### 附坑 C：`items:[]` ≠ 沉淀失败
即使 `items:[]`，只要 grep 能看到 `conversation/add` / `L1` / `extract` 关键字在滚，就说明 L0 落盘 + L1 抽取管线在跑，只是**后台异步**——`memory.pipeline.everyNConversations:3` + `l1IdleTimeoutSeconds:60` 决定了抽 L1 至少要"攒够 3 轮或空闲 60s"，加上 idealab 5 req/60s 限流（见 §12），首装等 1~3 分钟才见 items 是正常的。判定"沉淀失败"的标准是**日志里根本没有 `conversation/add` / `L1` 关键字滚**，或者 `~/.tdai-lab/data/instances/default/memory-generation-logs/v1/layer=l1/**/*_succeeded_*.json` 一个都没有——不是 items 空返。

---

### 5.1 memory-bridge 与转发路径的顺序耦合 ★首装实测

现象（首装踩过）：proxy 启动完 curl 探 `/memory-bridge/v3/atomic/search`，即使带全 `authorization: Bearer <sk-mem>` + `x-session-id: xxx`，仍然返：
```
{"code":40101,"message":"[memory-bridge] session not initialized; cannot derive identity"}
```

根因：
- `sessionInit.debugForceIdentity` 的身份注入**只发生在 `/claude-code/*` 转发中间件里**——一次 `POST /claude-code/default/v1/messages` 才会把 `team_id/agent_id/user_id/task_id` 打进这个 `x-session-id` 对应的会话状态。
- `/memory-bridge/*` 是独立路由，**不经过 sessionInit 中间件**，它进来时只查会话状态、不建。所以在从未经过转发的新 session id 上直接查 bridge，永远拿不到身份 → 40101。

结论：
- **不要在启动后直接单独探 bridge 判断链路健康**（我 3.2.1 早期文档给的这条探针是错的，已删）。
- bridge 的正确验法：**先经过一次 `/claude-code/*` 转发**（哪怕上游返 5xx，session 也建了），再用**同一个 `x-session-id`** 去查 bridge。这就是 §4.4 的顺序。
- 想在完全无转发的场景查记忆，绕开 bridge、直连 core 的 `/v3/atomic/search`（走 `http://127.0.0.1:8420`，Bearer 用 sk-mem，自己在 body 里带 `team_id/user_id/agent_id`——见 §4.2 的第二条 curl）。

---

## §6. 混合召回架构：L3 自动 + L1 按需（占位）

> 待补：per-turn 自动注 L3 画像 + L2 场景索引，L0/L1 通过 `tdai_memory_search` 工具按需拉——KV cache 友好的设计取舍。

---

## §7. node / ABI / pnpm workspace / native 依赖坑合集 ★本次实测

本节汇集从 0.1 到 0.3 装依赖阶段所有踩过的原理性问题，操作手册的命令块都是这些原理的**结果**。

### 7.1 为什么必须 node v22.x（v24 也不行）

- MemoryProxy 入口 `src/index.ts:3` 硬编码 `if (!process.version.startsWith("v22.")) process.exit(1)` —— **字符串前缀匹配**，不是 `engines` 的 semver `>=22`。
- 后果：v24.20 也被 `startsWith("v22.")` 判 false → 进程立刻退出。低版本被拦可以理解，高版本被拦是**作者只在 v22 上测过所做的非技术性硬约束**。
- MemoryCore 用的是 `engines: ">=22.16.0"`（能跑 v24），但为了 core 与 proxy 编出来的 native 模块 ABI 一致（better-sqlite3 之类），**两个都在 v22 下 install + 运行**是最省心的路径。跨版本 install 会踩 `NODE_MODULE_VERSION mismatch`（v22=127 / v24=131）导致 proxy 加载 sqlite 崩掉。

结论：`nvm use 22` 一步搞定，操作手册 0.1 就这么写。

### 7.2 为什么用 pnpm 而不是 npm

- 仓库里 MemoryCore/、MemoryProxy/、MemoryPanel/ 各带一个 `pnpm-workspace.yaml` —— 这是 **pnpm workspace 项目**，`packages:` 声明的子包互相通过 workspace-link 消费。
- 用 `npm install` 会在 `@npmcli/arborist` 的 `#loadPeerSet` 里崩掉：`TypeError: Cannot read properties of null (reading 'edgesOut')`。根因是 arborist 处理 workspace protocol（`workspace:*`）+ 项目内 peerDep 图时，某些边解析出 null 节点，它没做空指针保护。
- pnpm 天生识别 `workspace:*` + 有 CAS 存储（`.pnpm-store`）避免重复解压，是这套工程唯一稳的装依赖器。

**关于「一把装」的破除**：网上老攻略说「pnpm workspace 从仓库根 `pnpm install` 一把装即可」——这仅当**仓库根有 `pnpm-workspace.yaml`** 时成立。本仓库根**没有**这个文件，仓库根只是普通 git 目录；`pnpm-workspace.yaml` 分散在三个子包里，各自是**独立的 workspace 根**。所以命令要在 `MemoryCore/` 和 `MemoryProxy/` 里各跑一次，不能偷懒。

### 7.3 pnpm 12 的两个破坏性变更（本次核心坑）

**变更 A：拒绝执行第三方 postinstall 脚本（`ERR_PNPM_IGNORED_BUILDS`）**

pnpm 从 10 起、到 12 已经默认打开：**所有第三方包的 build/preinstall/postinstall 脚本都被拒绝执行**（供应链攻击防护）。首装会看到：
```
ERR_PNPM_IGNORED_BUILDS  Ignored build scripts: esbuild, better-sqlite3, protobufjs, tree-sitter-bash, ...
```
这不是错误、是提醒。但**必须放行**其中几个否则运行时坏掉：
- `esbuild`：postinstall 会把架构对应的原生二进制拷进 `node_modules/@esbuild/linux-x64/bin/esbuild`，`tsx` 跑 TS 全靠它。被拦 → tsx 报 `Cannot find module @esbuild/...`。
- `better-sqlite3`：postinstall 编译 native binding（`.node` 文件），proxy 会话缓存表用它落 sqlite。被拦 → proxy 启动降级到 in-memory，重启丢缓存（不致命但异常）。
- `protobufjs`、`tree-sitter-bash`：类似，语法解析 / 二进制协议用。
- `node-pty`：MemoryProxy 独有依赖，postinstall 编伪终端 native binding。proxy 运行时会 import，不放行则运行崩（首装实测在 MemoryProxy 报 `ERR_PNPM_IGNORED_BUILDS ... node-pty@1.1.0`）。

**变更 B：`package.json` 的 `pnpm.onlyBuiltDependencies` 已废弃**

pnpm 12 起，`package.json` 的 `pnpm` 字段整个不再读，明确警告：
```
WARN  The "pnpm" field in package.json is no longer read by pnpm.
The following keys were ignored: "pnpm.onlyBuiltDependencies".
See https://pnpm.io/settings for the new home of each setting.
```
新家是 `pnpm-workspace.yaml` 里的 **`allowBuilds:` map**：每个包显式指定 `true`（放行）/ `false`（明示拒绝，pnpm 就不再警告）。

MemoryCore 子包自带的 `pnpm-workspace.yaml` 已经预留了 `allowBuilds:` 段，但每个值填的是占位 `set this to true or false` —— 这是作者留给用户的白名单模板。操作手册 0.3 的 python 脚本就是把这个模板具体化：4 个我们要用的置 `true`，5 个用不到的（node-llama-cpp / openclaw / google-genai / koffi / mongodb-memory-server —— 我们走 idealab + Ollama，不需要本地 LLM/私有云 SDK/MongoDB）置 `false`。

### 7.4 为什么走源码模式（tsx）而不是 build

- 本机 Docker 不可用（构建镜像不通、无 daemon），也没时间等 `pnpm build` 出完整 dist。
- core 和 proxy 都用 `tsx`（TypeScript → 内存态 loader，esbuild 驱动）**直接跑 .ts**：
  - core：`npx tsx src/gateway/server.ts`
  - proxy：`node --import tsx/esm src/index.ts`（proxy 用 ESM 入口，要走 `--import tsx/esm` 而不是 `tsx src/...`）
- 代价：每次启动多花几百 ms 做 in-memory 转译，长跑无感；换来的是**改一行代码不用 rebuild、日志直接映射到源码行号**。
- 前置条件：tsx 是 core 的 devDep、proxy 也各自装了自己那份（`node_modules/.bin/tsx` 都存在，这就是操作手册 0.3 末尾要 `ls` 验证两处 tsx 二进制的原因）。若 proxy 目录漏装，报 `Cannot find package 'tsx'` —— 补跑一次 `cd MemoryProxy && pnpm install` 即可。

### 7.5 为什么 `find` 校验 native binding 而不是 `npm ls`

- pnpm workspace 里 `npm ls` 会因为 workspace protocol 报错或输出误导（把 workspace-linked 的包标成 `UNMET`）。
- `find -path "*better-sqlite3*/build/Release/*.node"` 是**物理验证**：只要文件存在，native 就编好了；不存在，就是 postinstall 被拦或编译失败。这比查 package manager 元数据可靠。

### 7.6 补充：从错误状态恢复的最小路径

如果照旧文档跑坏了状态（package.json 被塞过 pnpm.onlyBuiltDependencies、node_modules 是 npm 装了一半的、node 版本切来切去），最快恢复：
```sh
# 1. 切 node
. "$HOME/.nvm/nvm.sh" && nvm use 22

# 2. 清所有残留（node_modules + lockfile）
cd ~/workspace/install/TencentDB-Agent-Memory
find . -maxdepth 3 -name package-lock.json -delete 2>/dev/null
rm -rf node_modules MemoryCore/node_modules MemoryProxy/node_modules

# 3. 清 package.json 里可能残留的失效 pnpm 字段（操作手册 0.3 已带此 python 脚本）
# 4. 用 pnpm-workspace.yaml 的 allowBuilds 白名单（操作手册 0.3 已带）
# 5. 分子包 pnpm install
```
如果连 `pnpm store` 也想清零：`pnpm store prune`（一般不需要）。

---

## §8. 数据布局：多租户目录 vs `read-local-memory` CLI 不匹配 ★首装实测

现象（首装踩过）：跑 `read-local-memory -d ~/.tdai-lab/data` 概览，结果：
```
📂  L0 · conversations   总条数: 8       ✓
📂  L1 · records         总条数: 2       ✓
📂  L2 · scene_blocks    文件数: 0   总热度: 0      ✗（明明有）
📂  L3 · persona         （文件不存在）              ✗（明明有）
```
L0/L1 正确，L2/L3 却报 0/不存在——但直接 `cat` 是能读到 persona.md 和 scene block 的。

根因：**core 与 CLI 对 L2/L3 的存储路径约定不一致**。
- **core 实际写在**：`<data>/profiles/team%3A<team_id>%7Cagent%3A<agent_id>/{scene_blocks/*.md, persona.md, .metadata/scene_index.json}`
  - 目录名是 `team:tdai-lab|agent:brain` 的 URL 编码（`:` → `%3A`, `|` → `%7C`）
  - 这是**多租户布局**——同一台 core 可以承载多个 team/agent 组合，各自独立目录不打架
- **CLI `read-local-memory` 找的是**：`<data>/scene_blocks/`、`<data>/persona.md`（根目录扁平布局）

也就是说，CLI 是给"单租户 flat 目录"设计的、还没跟上 core 的多租户目录演进。L0/L1 走 SQLite（`vectors.db`）所以不受影响；L2/L3 走文件所以踩坑。

对我们的判定不构成阻塞：
- L1 内容质量：直接 `-L L1` 看 SQLite 已够核对
- L2/L3 内容质量：直接 `cat ~/.tdai-lab/data/profiles/team%3Atdai-lab%7Cagent%3Abrain/{persona.md,scene_blocks/*.md}`
- 或用 `atomic/search` / bridge 端点查（走 core 内存里的完整视图，不受 CLI 路径规则影响）

如果非要让 CLI 也看到 L2/L3，两条路（都不建议在验证期折腾）：
- 软链把多租户目录里的 `scene_blocks` 和 `persona.md` 链到 `<data>/` 根，`ln -s profiles/team%3Atdai-lab%7Cagent%3Abrain/scene_blocks scene_blocks` 之类——CLI 就能读到（但会污染 core 的路径判断，不推荐）
- 等 CLI 支持 `--team-id/--agent-id` 参数（源码 `scripts/read-local-memory/` 里 grep 一下 `scene_blocks`，改成拼多租户前缀即可，是个可接受的 PR）

结论：首装 §4.5 看到 L2/L3 显示 0，**别慌**，直接进多租户目录 `cat` 或走 API 查，看到内容就是通的。

---

## §8b. 常驻托管：为什么走 setsid+脚本，不走 systemd ★首装实测

现象（首装踩过）：`nohup ... &` 起完的 core/proxy/mock，切一个终端窗口后**全都消失**——`ps -ef | grep tsx` 空、`ss -tlnp | grep 8420` 空。日志尾巴戛然而止在切窗口那一刻附近，无堆栈、无 exit code。

### 根因：nohup 单飞挡不住的两条链路
`nohup` 只做了一件事：把 SIGHUP 从默认动作改成忽略。**但它挡不住这两条**：
1. **stdin/stdout/stderr 依然连着终端**——终端窗口关闭时，如果这几个 fd 没被完全断开，某些 tsx-loader 场景下会顺着 fd 收到关闭事件传导退出。
2. **子进程仍在父 shell 的进程组（PGID）里**——如果父 shell 是登录 shell、终端关闭发的 SIGHUP 是发给**整个进程组**的，`nohup` 只让当前 pid 忽略，但 tsx 会 spawn 出 worker 子进程，那些 worker **不继承忽略状态**，它们收到 SIGHUP 照样死；worker 一挂主进程也就跟着挂了。

### 对策：三件套 `setsid + </dev/null + disown`
- `setsid`：把进程**脱出当前 shell 的进程组**、成为新 session 的组长。之后终端发的 SIGHUP 传不到它。
- `</dev/null`：把 stdin 显式断开重定向到 `/dev/null`，避免 fd 关闭事件传导。
- `disown`：从 shell 的 jobs 表里摘掉这个后台作业，shell 退出时不再向它发 SIGHUP。

三条同时上，进程的父 pid 变成 1（被 init 接管），`ps -o pid,pgid,sid,ppid` 里 PGID/SID 都是它自己——这是**真正意义上的脱离终端**。本机实测：切两次终端窗口 core/mock/proxy 依然在。

### 为什么不用 systemd --user
本机（阿里内部开发容器）跑 `systemctl --user status` 直接报：
```
Failed to connect to bus: No medium found
```
探测原因：
- `$XDG_RUNTIME_DIR` 为空
- `/run/user/1001/` 不存在
- `loginctl` 命令自身也不可用

即容器里没跑 `systemd-logind` / `user@.service`，用户级 systemd bus 根本没建。这不是配置问题，是**运行环境不支持**——只能退到脚本方案。

### 为什么也不用 PM2 / supervisord
- PM2：能装、能起，但它自己也要靠 `pm2 startup` → 底层还是 systemd 才能实现"机器重启自愈"，systemd 不可用等于白装。相当于多套一层没换来收益。
- supervisord：需要单独装 Python 组件、独立配置格式，收益/复杂度不划算。

### 脚本方案的定位：**跨终端存活，机器重启不自愈**
操作手册 §3.4 的 `start-all.sh` / `stop-all.sh` / `status-all.sh` 解决的是"关终端 = 死"这个每天都会碰到的痛点，**不解决**"机器/容器重启后自动拉起"。后者需要 systemd 或类似 init 集成——本机不支持，等到切到有 systemd 的机器再做。

对 POC 阶段：这条能力**已经够用**——容器重启是极低频事件，重启后再手动跑一次 `start-all.sh` 是可以接受的成本。等主 CC 真常态挂过来，再谈自愈。

---

## §9. `scoreThreshold: 0.01` 为什么调这么低（占位）

> 待补：本地 bge-m3 嵌入的分布区间实测（大量命中落在 0.05~0.2）与默认 0.3 阈值的矛盾；调 0.01 后召回率飙升的实测数据。

---

## §10. 未装的子服务（Panel / Knowledge / Hub）如何静默降级（占位）

> 待补：`injection.injectors` 里只留 `tdai-memory`、其它 injector 需 memory-hub → 未装即降级为空实现，对主链路 0 影响的代码路径。

---

## §11. 接主 CC 的可逆切换（占位）

> 待补：为什么用临时 shell env 而不写 `~/.zshrc`（用户硬约束：不动主 CC 的持久化配置，保生命线）、`ANTHROPIC_BASE_URL` 的作用域、回退步骤。

---

## §12. 提炼脑限流（idealab 5 req/60s）（占位）

> 待补：`everyNConversations` / `persona.triggerEveryN` 与限流的耦合；`promptMode: chat` vs `code` 对空对话抽取率的影响。

---

## §13. upstream URL 必须自带 `/v1`（proxy 会砍 `/v1` 前缀）★首装实测

现象（首装踩过）：切上游到真 ducky（`upstream.url: https://ducky.code.alibaba-inc.com/proxy`）后，curl 打 `/claude-code/default/v1/messages` 拿回一个 HTML 502：
```html
<title>502 Bad Gateway</title>
<td>URL:</td><td>https://ducky.code.alibaba-inc.com/proxy/messages</td>
```
但**直连 ducky**打 `https://ducky.code.alibaba-inc.com/proxy/v1/messages` 是 200。差异一目了然：proxy 转发出去时**丢了 `/v1`**。

### 根因：proxy 白名单 + upstreamEndpoint 拼接规则
读 `MemoryProxy/src/routes/whitelist.ts:45-53`：
```ts
{
  pathSuffix: "/v1/messages",       // ← 匹配入站请求
  upstreamEndpoint: "/messages",    // ← 拼给上游的"裸端点"，不含 /v1
  protocol: "anthropic",
  isPrimary: true,
}
```
再看 `anthropicHandler.ts:1246-1249`：
```ts
const targetUrl = ... config.upstream.url;
const forwardEndpoint = matchWhitelistEndpoint(c.req.path)?.upstreamEndpoint ?? "/messages";
// 最终转发 URL = targetUrl + forwardEndpoint
```
即 proxy 假设你在 `upstream.url` 里**已经写好含 `/v1`（或该厂商任何自定义前缀）的基址**——因为不同厂商的 `/v1` 位置不同：
- 官方 Anthropic：`https://api.anthropic.com/v1`
- 阿里 ducky：`https://ducky.code.alibaba-inc.com/proxy/v1`
- 某些内部代理可能是 `https://gw.internal/api/anthropic/v2/xxx`

proxy 自己**不加也不猜** `/v1`，全由你在 upstream.url 里控制。

### 为什么 mock 阶段没暴露
mock 服务器（`mock-upstream.mjs`）对**任何 URL 都回 200**（`if (req.url.includes("messages"))` 的判断只影响是否保存 lastbody），所以 mock 阶段 `upstream.url: http://127.0.0.1:8199` 不带 `/v1` 也能通。切到真 ducky 才卡。首装文档也是这里踩的——mock 通了就误以为 URL 拼接对了，其实是 mock 太宽松。

### 结论
- 操作手册 3.1 / 5.1 的 upstream url 必须写到含 `/v1` 一层。mock 阶段可省，但要在配置里显式注释"生产必须加 /v1"，否则复现路径必踩。
- 如果换到别的上游（比如某个内部 anthropic gateway），先直连试出**能 200 的完整 URL**，砍掉尾部 `/messages` 就是要填进 `upstream.url` 的值。

### 快速定位这类拼接错误
proxy 报 `UPSTREAM_4xx status=502` 时，同一行 error body 里会带 tengine/nginx 回的 URL：
```
<td>URL:</td><td>https://ducky.code.alibaba-inc.com/proxy/messages</td>
```
把这个 URL 和你**直连试通的 URL** 对齐一比，差在哪就是 upstream.url 该补哪。**不要看 proxy 侧的 forward log**（那只印 upstream.url 值，不印完整拼接结果，看不出问题）。

---

## §14. 画像注入退化为"工具指南"——★已结案（不是 bug，是空记忆时的正确降级）

**结案时间**：2026-09-16 10:19。**结论**：这不是 bug，是 hook 在 L2/L3 全空时的**正确降级动作**——降级后返回 `MEMORY_TOOLS_GUIDE`（工具指南）让 CC 至少知道"有个记忆工具可以主动查"，比什么都不塞更有用。

**判定证据**（§5.2 Step 4 冷启 3 次冒烟）：

| 时间 | 场景 | 注入结果 | 说明 |
|---|---|---|---|
| 09:36:25 (×3) | §4.1 首次喂 3 轮 对话时 | DEGRADED | ★这就是当初 22:11 记录的"退化"——彼时 L1 还未抽出、L3 未生成，**记忆确实为空**，走 fallback 是**正确行为** |
| 09:44:42 | §4.3 mock 跨会话召回 | REAL | L1 已抽出 2 条 |
| 10:11:36 | §5.2 单发冒烟 | REAL | 真 ducky 上游 |
| 10:18:29 / 10:18:51 / 10:19:14 | §5.2 Step 4 冷启 3 次 | REAL / REAL / REAL | ★★**3/3 全命中，启动竞态假设也证伪**——冷启后 core warm-up 完毕再放请求，稳定返真画像 |

**真正的判定条件应该是**：
- L1/L2/L3 **有内容** + 注入退化 = 真 bug（本次未观察到）
- L1/L2/L3 **确实为空** + 注入 `MEMORY_TOOLS_GUIDE` = **正确降级**（这才是当初看到的现象）

原先"启动竞态 + session_init cache 固化"的假设是**误判**——真正的原因是我们观察 22:11 那次的时候，忘了检查"当时 L3 是不是真的还没抽出来"。首装喂完对话后 L1 至少要 5~30s，喂前 30s 内的任何请求都会看到 DEGRADED，这**不是应该修的东西**。

**对后续的启示**：
- 判定退化前，先看 `~/.tdai-lab/data/profiles/team%3Atdai-lab%7Cagent%3Abrain/persona.md` 是否存在 + 有内容，以及 SQLite 里 L1 是否有条目——都空的话看到 `<memory-tools-guide>` 是**预期的**，别当 bug。
- 只有当 persona/L1 有内容、但注入的仍是 `<memory-tools-guide>`——那才是真 bug，回到 `tdai-profile-memory-injector.ts:82-90` 的 fallback 分支排查 `readL3ForCtx` / `listL2ForCtx` 为什么返空。

---

## §14-老 (归档). 原疑难登记（保留作历史）

**现象登记时间**：2026-09-15 22:11:48。**当前尚未解决**，先如实记录，避免后来的人（包括未来的银时）以为已经通了。

### 现象
同一台机器、同一份 proxy.yaml、同一份 core 数据，**两次冒烟 `tdai-profile-memory-injector` 这个 hook 返回了两种不同内容**：

| 冒烟时间 | session | hook preview 开头 | 判断 |
|---|---|---|---|
| 22:10:16 | sess-smoke-1789481416 | `<tdai_profile_memory> 以下是 TDAI 为当前 agent 维护的长期工作记忆...L3 core_memory... **Archetype**: 一位在协作开始前就把规则钉死的"边界先行者"...` | ✅ 真画像被注入 |
| 22:11:48 | sess-smoke-1789481508 | `<memory-tools-guide> ## ⚠️ 重要：这不是文档，这是你的可用能力 以下 `<tdai_memory_tools>` 中列出的...` | ✗ 只是工具使用指南，画像内容丢失 |

**后果**：ducky 收到的 system 里只有"教你怎么调 memory 工具"，**没有你的具体画像**。所以问它"我限流该怎么办"，它答"考虑切换到备用 provider"——这条建议**直接违反 [[no-provider-switch]]**，端到端"记得你"链路失败。

### 已收集的证据
1. **多租户目录里画像真实存在**：`~/.tdai-lab/data/profiles/team%3Atdai-lab%7Cagent%3Abrain/persona.md` 有完整的 User Narrative Profile（包含 idealab 唯一 key、禁止切 provider）。所以**画像本身没丢**。
2. **22:10 那次能拉到真画像**：hook preview 有 "Archetype ... 边界先行者" 字样——和 persona.md 完全对得上。
3. **两次的区别**：22:11 前**重启了 core + proxy**（为了给 upstream 加 `/v1` 生效）。重启后 22:11:47 proxy log 出现：
   ```
   [hook-cache] prewarm session=sess-smoke-1789481508: clearBefore=true, cleared existing entries
   [hook-cache] prewarm session=sess-smoke-1789481508: cached=2 skipped=0 durationMs=9
   ```
   即 proxy 在处理请求**前**就 prewarm 了 hook 缓存；prewarm 只花了 9ms，可疑得很——正常情况从 core 拉 L3 画像应该更久。
4. **两次 hook 都是同一个 hookId** `tdai-profile-memory-injector`（priority=110、cacheStrategy=session_init），配置上完全一样。差别不在 hook 定义，在 prewarm 那一刻**从 core 拉到了什么**。

### 代码路径已定位（读源码确认，非猜测）

`MemoryProxy/src/injection/injectors/tdai-profile-memory-injector.ts:82-90`：
```ts
const hasAnything = groups.some((g) => g.l3 || g.l2Entries.length > 0);
if (!hasAnything) {
  return [{ type: "text", content: MEMORY_TOOLS_GUIDE,
            metadata: { ..., mode: "tools-only" } }];   // ← 就是我们看到的退化输出
}
```

即 hook 内部**有一条 explicit fallback 分支**：只要"当前 agent + 借入 agent 的 L3 和 L2 全为空"，就直接返 memory-tools-guide 骨架（对应 metadata `mode:"tools-only"` 与 preview 里 `<memory-tools-guide>` 开头）。这与我们两次冒烟观测到的现象**完全对应**——假设 B 在**代码层面**成立。

`hasAnything=false` 的上游可能来自三条路径（同文件 57-80 行）：

| # | 路径 | 触发点 | 观测手段 |
|---|---|---|---|
| P1 | `resolveFixedAssetCtxs` 返回不含任何 ctx（连 self 都无） | 极罕见：identity 解析失败 | 不太可能，identity 从 sessionInit 稳定注入 |
| P2 | `client.readL3ForCtx(tdaiCtx)` 返 null / 空 | core 侧 persona 存储读不到（租户错 / 文件缺失 / 静默错误吞掉） | core log 里 grep `readL3` / `persona` 相关行 |
| P3 | `client.listL2ForCtx(tdaiCtx)` 返 [] **且** P2 同时空 | 同上，L2 scene 索引读不到 | core log 里 grep `listL2` / `scene_index` |

**关键租户参数**（74-77 行）：
```ts
serviceId: spaceId || this.baseConfig.serviceId,
```
- `spaceId` 来自 session 注册时的 `/proxy/<spaceId>/...` 段。
- 我们冒烟用的 URL 是 `/claude-code/default/v1/messages`——没有 `/proxy/<spaceId>/` 段，所以 `session.space_id` 大概率是空的，fallback 到 `baseConfig.serviceId = "default"`。
- **两次冒烟 spaceId 都同为空/default，租户一致**，所以问题**不在租户漂移**，而在 P2/P3——core 侧同一租户下的 L3/L2 读取行为在两次冒烟之间发生了变化。

### 为什么两次冒烟结果不同

现在把 22:10（成功）vs 22:11（退化）的差别摊平：
- **22:11 之前重启过 core + proxy**（为了给 upstream 加 `/v1` 生效）
- 22:11:47 prewarm cache 只花 **9ms**——正常从 core 拉画像 + L2 索引不可能这么快，很像"接口调了但快速返空"
- 22:11:48 proxy 里还看到不相关的 `CREDIT_REPORT error=fetch failed`——说明 proxy↔core 之间**部分接口存在偶发失败**

这两条弱证据指向：**重启后 core 的 storeBackend 尚未 warm-up 时被 prewarm 请求命中，`readL3ForCtx` / `listL2ForCtx` 返 null/空，被 hook 缓存进 session-init cache**（cacheStrategy=session_init 意味着**这一次的空结果会被复用到整个会话**——一旦 cache 了工具指南，同 session 后续都不会再查 core，画像永远回不来）。

### 下一步（唯一动作，最小代价）

三选一里最能确诊路径的动作：**冷启动 3 次冒烟，看退化是否稳定复现**。
- 若 3/3 全退化 → 稳定复现，可以直接改动源码验证 hook（比如临时把 fallback 关掉看会不会崩、或加打印）
- 若 1~2/3 退化、其余成功 → 随机性证实"启动竞态 + session_init cache 固化"，对策是加大 `start-all.sh` 里 core 起完到 proxy 起之间的 sleep（5s → 20s）
- 若 0/3 退化（都成功） → 22:11 那次是一次性巧合，直接进 §5.3 挂 CC

**别急着改代码**——`cacheStrategy: session_init` 意味着我们每次冒烟都得开新 sessionId（`sess-smoke-<timestamp>`）才能真正观察最新 core 状态，否则拿到的都是缓存。三次冷启动都要用不同 sessionId。

**此刻结论**：**判据②③在链路层面通了，但注入内容退化，端到端"记得你"未成立**。§5.2 不能标"全绿"，也不能进 §5.3 挂 CC——挂了也没记忆效果。冷启动 3 次的执行步骤见操作手册 §5.2 Step 3（新增）。

### 2026-09-16 复测更新（清零重跑后 mock 上游一次通过，未复现退化）

背景：操作手册 §4.0 新增了「数据清零重跑」，加上 §4-前置 把 upstream 切回 mock。银时按新流程跑完 §4.1（喂 3 轮）+ 等 30s + §4.3（sess-NEW 新会话）：

- `wc -c ~/.tdai-lab/mock-lastbody.json` = **10294 字节**（对比：不注入时 body 大约几百字节量级）
- `grep -aoE ... mock-lastbody.json`：
  - `idealab` × 5
  - `Narrative Profile` × 1
  - `tdai_profile_memory` × 2
  - `银时` × 5
- 完全没有出现 `<memory-tools-guide>` / `mode:"tools-only"` 相关字样

结论：**清零后一次冷启动即命中真画像分支**。这与"启动竞态 + session_init cache 固化"假设一致——上一次 22:11 那次退化的**必要条件是 core 尚未 warm-up 时被 hook prewarm 命中**，本次数据清零后是「先起 core → 等 status-all 全绿（内含 sleep 10）→ 再走请求」，避开了竞态窗口。

**但 §14 尚不能关闭**——本次是 mock 上游、单次冷启，不是 ducky 上的 3 次冷启动。真判定要看操作手册 §5.2 Step 4 的冷启 3 次测试：
- 3/3 命中真画像 → §14 关闭
- 1~2/3 退化 → 竞态假设坐实，把 start-all.sh 的 core→proxy 之间 sleep 从 5s 加到 20s
- 3/3 退化 → 说明 mock/ducky 路径本身影响 hook 行为（不太可能，但要看到才放心）

在 §5.2 之前，此节维持"待验"状态，勿口头判定已解决。

---

## §15. 两个 key 不能同源：`upstream.apiKey`（对 ducky）vs `x-tdai-user-key`（对 core）★2026-09-16 血泪实测

### 现象

`claude-mem` 进入 CC 后，`~/.tdai-lab/proxy.log` 里出现大量 401：

```
[wb-debug] metadata-client req path=/v3/meta/agent-fixed-asset/list-with-detail
  status=401 userKey.len=28 userKey.prefix=dXF4eTc3OXV4OXgzS0pp
  body.head={"code":401,"message":"unauthorized: invalid_user_key"}
[fixed-asset] kernel error, injecting only self: ...
[session-init:cc] getAgent failed / getTask failed / participation-log append failed
[hook-cache] put failed: FOREIGN KEY constraint failed
```

但上游 ducky 却回答正常（`text preview` 里含"银时"/"idealab"）。判据看着全绿，实则**一半链路 401 在裸奔**。

### 根因（一句话）

**proxy 是"双身份"服务，它对上游（ducky）和对下游（core）用两个域的凭证；一旦客户端把 ducky token 直接作为 `Authorization: Bearer` 送进来，proxy 会把这**一个** token 同时用到两个场景，其中至少一个场景是错的。**

具体：

| 场景 | proxy 用的字段 | 应该是什么 |
|---|---|---|
| 出站到 ducky | `config.upstream.apiKey`（proxy.yaml `upstream.apiKey`）；**若空则透传入站 Bearer** | ducky token |
| 出站到 core `/v3/meta/*` | 入站 Bearer 作为 `x-tdai-user-key`（代码 `anthropicHandler.ts:686` 写死 `callerUserKey = apiKey`，**不 fallback 到 `tdai.apiKey`**） | sk-mem key（tdai 自签发） |

- 首装时 `upstream.apiKey` **空** → 出站到 ducky 透传入站 Bearer → 如果入站是 ducky token，ducky 认；
- 但入站 Bearer 也被强制当 sk-mem 送到 core → 401；
- 401 后 fixed-asset 静默 degrade 到 selfCtx（画像还能勉强渲染出来，所以 §5.2 表面判据不炸）；
- 后续 `hook-cache put` 因 session/agent 未成功入库触发 FK 约束失败——**hook 结果无法缓存**，每次冷启动都要重跑注入 pipeline。

### 为什么代码要写死 "入站 Bearer = sk-mem"，不 fallback

`handler.ts:861-866` 注释原话：

> kernel /v3/meta/\* 走 x-tdai-user-key 鉴权，需要 sk-mem-\* 用户 key。**优先级：客户端 Authorization bearer > config.tdai.apiKey**。之所以不 fallback 到 config.tdai.apiKey，是因为 config.tdai.apiKey 常被本地/测试环境设成占位符（如 "local"），fallback 会覆盖真实用户 key，导致 401。

结论：**proxy 强制要求客户端 Authorization 送的必须是 sk-mem key**。ducky token 是必须往 `upstream.apiKey` 里灌的。

### 正确的两个 key 摆放

| 位置 | 内容 | 长度参考 |
|---|---|---|
| `~/.tdai-lab/proxy.yaml` 的 `upstream.apiKey` | ducky token（`uqxy779ux9x3KJi...`） | 28 字节 |
| CC 侧 `ANTHROPIC_AUTH_TOKEN` | sk-mem key（`~/.tdai-lab/user.key` 内容，`sk-mem-...`） | 39 字节 |

两个 key 一"内"一"外"，各就各位。

### 判定它有没有配对的一句 grep

```sh
grep -acE "unauthorized: invalid_user_key|FOREIGN KEY constraint failed" ~/.tdai-lab/proxy.log
# 修复前：>0（脏），修复后：0（净）
```

### 修复动作被固化到操作手册

- 操作手册 §5.1（切 ducky 时同步灌 `upstream.apiKey`）
- 操作手册 §5.2 Step 1（客户端存的 token 语义反转：ducky token → sk-mem key）
- 操作手册 §5.3 Step 1（`claude-mem` 函数读 `cc-authtoken.sk-mem`）
- 操作手册 §5.2 Step 3/4 判据（新增"proxy 401 计数 == 0"，"无 FK 约束"）

---

## §16. 3 行 fork：出站到 ducky 用 Bearer，不用 x-api-key ★2026-09-16 血泪实测

### 现象

§15 把 `upstream.apiKey` 灌成 ducky token 后重跑 §5.2，client 收到：

```json
{"message":"get token from header error","trace_id":""}
```

上游 ducky 说"从 header 里拿不到 token"。同时 proxy 侧一切正常（`pipeline.forward.start` upstream=ok、injection 全跑完）。

### 根因

`MemoryProxy/src/anthropicHandler.ts` 函数 `buildUpstreamHeaders`（原 357-360 行）把 `effectiveApiKey` **写进 `x-api-key`**、**删掉 `authorization`**：

```ts
if (effectiveApiKey && !target.authHeaders) {
  headers["x-api-key"] = effectiveApiKey;
  delete headers["authorization"];
}
```

**但 ducky 是 Bearer-only**（`Authorization: Bearer ...`）—— `x-api-key` 头它根本不看。所以 upstream.apiKey 灌得再对，也传不到 ducky。

`plan.md` 早在 Context 里就预告过这条：「ducky 是 Bearer-only；开源 proxy 默认只发 x-api-key → CC→proxy→ducky **需要额外胶水**」。**这就是那个胶水**。

### 修复（3 行 fork）

改成写 `authorization: Bearer <key>`、删 `x-api-key`：

```ts
// ★ tdai-lab fork: ducky 上游是 Bearer-only（x-api-key 会 401 / get token from header error），
//   出站用 Authorization: Bearer 替代 x-api-key。见 补充说明 §16。
if (effectiveApiKey && !target.authHeaders) {
  headers["authorization"] = `Bearer ${effectiveApiKey}`;
  delete headers["x-api-key"];
}
```

### 备份 & 未来升级怎么合

- **备份**：改动前已把源文件复制为 `anthropicHandler.ts.bak-preforkBearer-20260916`。
- **未来 upstream 升级**：`git pull` MemoryProxy 后，若 `buildUpstreamHeaders` 函数有变动，先看 diff：
  - 如果**它自己已经改成 Bearer**（或加了配置开关）→ 直接采用 upstream，删掉我们的 fork。
  - 如果**它仍是 x-api-key**（大概率，因为主线可能接的不是 ducky）→ 用我们的 3 行覆盖回去。
- **不建议做的**：把 fork 抽成 `~/.tdai-lab/proxy.yaml` 里的配置开关——那要动 config schema，改动面反而大。3 行代码 fork 最省事。

### 兼容影响

- **只影响 anthropic 协议链路**（`anthropicHandler.ts`）。`codexHandler.ts` 本来就走 Bearer（`codexHandler.ts:252-253`），未受影响。
- **只影响 `effectiveApiKey && !target.authHeaders` 分支**：如果 costGuard 用了 `target.authHeaders` 覆盖，那个 else 分支保持原状（既允许 x-api-key 也允许 authorization），未受影响。
- **只影响出站到 ducky 的场景**：如果未来把 upstream 换回 mock（§4-前置），mock 侧 x-api-key / Bearer 都能收，也没影响。

### 判定它有没有生效

```sh
grep -aE "get token from header error" ~/.tdai-lab/proxy.log
# 应为空
```

配合 §15 的一句 grep（`unauthorized: invalid_user_key|FOREIGN KEY constraint failed` 计数不再新增），整条链路才算干净。

---

## §17. `meta_users` 表为空 → 所有 `/v3/meta/*` 401（纠正一次误判）★2026-09-16 血泪实测

### 症状

- proxy.log 里 `unauthorized: invalid_user_key` 计数一路涨
- proxy.log 里 `FOREIGN KEY constraint failed` 计数一路涨
- 直接对 core 打 `/v3/meta/auth/verify`（把 `~/.tdai-lab/user.key` 用 `x-tdai-user-key` 传 或 body 里 `user_key` 字段传），返回 `{"data":{"valid":false,"user":null}}`

### 根因

代码路径（read-only 追踪）：

1. `MemoryCore/src/metadata/router/auth.ts:47-69` `authenticateV3(userKey, service)`：
   - `service.verifyAuth(userKey)` 返回 null → 401 `invalid_user_key`。
2. `MemoryCore/src/metadata/service/metadata-service.ts:745-750` `verifyAuth`：
   - 先查 `lookupMemorySystemUser`（未配 `TDAI_MEMORY_SYSTEM_USER_KEY` → 恒 null）
   - 再 `this.store.getUserByKey(userKey)`。
3. `MemoryCore/src/metadata/store/sqlite-adapter.ts:530` `getUserByKey`：
   - `SELECT ... FROM meta_user_keys WHERE key_value=? AND status='active'`
   - **表里没有这一行 → 直接 null**。

**决定性证据**（直接 sqlite3 查 db）：
```sh
DB=~/.tdai-lab/data/metadata/tdai_metadata_default/metadata.db
sqlite3 "$DB" "SELECT count(*) FROM meta_users; SELECT count(*) FROM meta_user_keys;"
# 观察到：0 / 0
```

### 为什么表会空

三种已知触发：

1. **§2.2 curl 实际没成功**：`user_key` 传参格式错误 / core 未 ready / Bearer gate 意外开启，返回 4xx 但没抛断言，本地脚本继续把生成的 KEY 写入 `~/.tdai-lab/user.key`——看起来一切正常，实际 db 里啥都没有。
2. **db 目录后来被清了**：`§4.0 数据清零重跑` 清 `~/.tdai-lab/data/**` 后忘记补跑 §2.2。
3. **首装时 `data/` 目录初始化竞态**：core 首次启动会自建 `metadata.db` 空库，紧接着调 init-admin 若中途 panic，事务回滚 → 表 schema 已建但没数据。

### 修复流程（收敛版）

见操作手册 **§5.0**——把「自检 + 补跑 init-admin + 校验」封装成三步。

一句话动作：
```sh
DB=~/.tdai-lab/data/metadata/tdai_metadata_default/metadata.db
if [ "$(sqlite3 "$DB" 'SELECT count(*) FROM meta_users')" = "0" ]; then
  KEY=$(cat ~/.tdai-lab/user.key)
  curl -sS -X POST http://127.0.0.1:8420/v3/internal/meta/user/init-admin \
    -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
    -d "$(printf '{"username":"admin","user_key":"%s"}' "$KEY")"
fi
```

### 与 §15、§16 的分工

- **§15**：`upstream.apiKey`（对 ducky）vs `x-tdai-user-key`（对 core）**是两个 key、不能同源**——回答"哪把 key 该放哪里"。
- **§16**：出站到 ducky 用 `Authorization: Bearer`，不是 `x-api-key`（3 行 fork）——回答"key 用什么头发出去"。
- **§17**：即使 key 放对了、Bearer fork 也打了，如果 db 里根本没有那把 key，还是全 401——回答"那把 key 有没有在 db 里存在"。

### 纠正：之前把根因误判成 `auth.ts:55` 的 admin 拦截

`auth.ts:55` 的 `isConfiguredMemorySystemUserKey` 只匹配 **通过 `TDAI_MEMORY_SYSTEM_USER_KEY` / yaml `systemUser.memory` 显式注入的那把「memory 静态 key」**（见 `system-user.ts:127`）。

我们的 `~/.tdai-lab/tdai-gateway.yaml` 里**没有 `systemUser.memory` 配置**、环境变量也没设 → `memorySystemUser` 是 undefined → `isConfiguredMemorySystemUserKey` 恒返回 false。所以那条分支从来不会命中，"admin key 被 /v3/meta/* 拒绝"是**当前配置下的错误结论**。

真正拦截发生在下一行 `service.verifyAuth(userKey)` 返回 null 之处——纯粹是 db 里没这把 key。

### 判定它有没有修好

```sh
# 一次干净的冒烟应该：
sqlite3 ~/.tdai-lab/data/metadata/tdai_metadata_default/metadata.db "SELECT username, user_type FROM meta_users;"
# 至少输出一行 admin|system_admin

grep -acE "unauthorized: invalid_user_key|FOREIGN KEY constraint failed" ~/.tdai-lab/proxy.log
# 冒烟后计数不再新增（若已有历史行，看 tail -20 时间戳未更新即可）
```

---

## §18. 改了 `debugForceIdentity` 不生效 → proxy-state 持久化坑 ★2026-09-16 血泪实测

**症状**：把 `~/.tdai-lab/proxy.yaml` 里 `sessionInit.debugForceIdentity` 从 `team_id:tdai-lab / agent_id:brain` 改成 db 真主键 `team-xxxx / agt-xxxx`，重启 proxy，`grep sessionInit ~/.tdai-lab/proxy.log` 也确认 `sessionInit=enabled`；但新发起的冒烟请求日志里仍然是：

```
[wb-debug] metadata-client req path=/v3/meta/agent/get status=404 ...
body.head={"code":404,"message":"agent_not_found: not found: brain","request_id":"req-<新id>"}
```

**根因（分支被跳过）**：

`MemoryProxy/src/session/claude-code/init.ts:631`：

```ts
if (config.debugForceIdentity && (!state || state.status !== "initialized")) {
  const forced = config.debugForceIdentity;
  // ...用 forced.team_id / forced.agent_id 走 completeRegistration
}
```

条件 `!state || state.status !== "initialized"` —— **已 initialized 的 session 不再走这条分支**。

proxy 有一个**磁盘持久化**的 session 状态目录：

```
~/.memory-tencentdb/proxy-state/nottl/default/<session-id>/binding.json
{"outcome":"initialized","userId":"u_debug","teamId":"tdai-lab","agentId":"brain","taskId":"validate",...}
```

历史冒烟（sess-B3 / sess-NEW / 本 CC 的 session-id 等）在首次 init 时就把 `teamId:"tdai-lab", agentId:"brain"` 钉进磁盘。重启 proxy 不会清这个目录 → 老 session 再来时 `state.status === "initialized"`，`debugForceIdentity` 分支被短路，proxy 用磁盘上的旧绑定继续请求 core 的 `/v3/meta/agent/get?agent_id=brain`，404。

**修法**：yaml 改主键 **+** 停 proxy → `rm -rf ~/.memory-tencentdb/proxy-state/nottl` → 起 proxy。已在《操作手册 §5.2b》Step 2.5 落地。

**验证是否真走了 debugForceIdentity 分支的可观测点**：

```sh
grep -aE "session-init:cc.*DEBUG bypass.*force identity" ~/.tdai-lab/proxy.log | tail -3
# 至少 1 行含 team=team-xxxx agent=agt-xxxx —— 才代表分支进了
```

**为什么容易踩**：多数人下意识以为「重启 proxy = 会话状态清零」；实际 proxy 走 append-wins 持久化（`nottl` 语义 = 不 TTL、不到期），只清进程内存不清磁盘。yaml 是"新会话的默认蓝图"，磁盘 binding 是"已开会话的现实"，两者冲突时**现实赢**——这是一处反直觉设计（好处：进程重启不掉状态；坏处：调 debugForceIdentity 时特别坑）。

**与相邻踩坑的分工**：
- §15：两把 key 位置错乱 → curl 层 401
- §16：Bearer/x-api-key 协议错乱 → 出站到 ducky 401
- §17：`meta_users` 表空 → core 侧全 401
- §18：proxy-state 磁盘持久化 → yaml 改身份三元组不生效（不是 401，是 404 + 命名空间没换）

---

> 每次踩坑后回到本文对应小节补写，操作手册保持"只给命令"。
