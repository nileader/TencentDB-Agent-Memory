#!/usr/bin/env bash
# self-check.sh
# 一键自检 TDAI 记忆体系 —— 5 层。
#
# 使用：
#   self-check.sh          # 默认
#   self-check.sh -v       # 详细（含 e2e body 前 400B、每篇场景名）
#
# 退出码：任一 Layer FAIL → 1；仅 warn → 0。

set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

REPO="$HOME/workspace/install/TencentDB-Agent-Memory"
HANDLER="$REPO/MemoryProxy/src/anthropicHandler.ts"
LAB="$HOME/.tdai-lab"
DATA="$LAB/data"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
PASS=0; FAIL=0; WARN=0

ok()   { printf "  ${GREEN}[✓]${RESET} %s\n" "$*"; PASS=$((PASS+1)); }
bad()  { printf "  ${RED}[✗]${RESET} %s\n" "$*";   FAIL=$((FAIL+1)); }
warn() { printf "  ${YELLOW}[!]${RESET} %s\n" "$*"; WARN=$((WARN+1)); }

# ─── Layer 1: 进程 & 端口 ───────────────────────
echo "── Layer 1: 进程 & 端口 ────────────────────"
check_port() {
  local name=$1 port=$2 pidfile=$3
  local pid=""
  [ -s "$pidfile" ] && pid=$(cat "$pidfile") || pid=""
  local alive="no"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive="yes"; fi
  local http
  http=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null || echo 000)
  if [ "$alive" = "yes" ] && [ "$http" != "000" ]; then
    ok "$name pid=$pid :$port http=$http"
  elif [ "$alive" = "yes" ]; then
    warn "$name pid=$pid alive 但 :$port 不响应 (http=$http)"
  else
    bad "$name 未运行（pidfile=$pidfile, pid=${pid:-N/A}）"
  fi
}
check_port core  8420 "$LAB/core.pid"
check_port proxy 8096 "$LAB/proxy.pid"
check_port mock  8199 "$LAB/mock.pid"

# ─── Layer 2: 补丁 marker ───────────────────────
echo ""
echo "── Layer 2: 补丁 marker ────────────────────"
if [ ! -f "$HANDLER" ]; then
  bad "anthropicHandler.ts 不存在: $HANDLER"
else
  grep -q 'headers\["authorization"\] = `Bearer ${effectiveApiKey}`' "$HANDLER" \
    && ok "patch-6.1 Bearer auth" || bad "patch-6.1 Bearer 缺失（跑 sync-from-fork.sh 或 apply-proxy-patches.sh）"
  grep -q 'patch-6.2' "$HANDLER" \
    && ok "patch-6.2 strip output_config" || bad "patch-6.2 缺失"
  grep -q 'patch-6.3' "$HANDLER" \
    && ok "patch-6.3 no-zstd" || bad "patch-6.3 缺失"
fi

# ─── Layer 3: 端到端 (proxy → core → ducky) ─────
echo ""
echo "── Layer 3: 端到端调用 ────────────────────"
SK=""
[ -s "$LAB/cc-authtoken.sk-mem" ] && SK=$(cat "$LAB/cc-authtoken.sk-mem")
if [ -z "$SK" ]; then
  bad "cc-authtoken.sk-mem 为空，跳过 e2e"
else
  BODY=/tmp/tdai-selfcheck-body
  resp=$(curl -sS -o "$BODY" -w "%{http_code} %{time_total}" \
    --max-time 30 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SK" \
    -H "x-conversation-id: self-check-$(date +%s)" \
    -X POST "http://127.0.0.1:8096/claude-code/default/v1/messages" \
    -d '{
      "model": "claude-opus-4-6",
      "max_tokens": 16,
      "messages": [{"role":"user","content":"reply with the single word ok"}]
    }' 2>&1) || resp="000 timeout"
  code=$(echo "$resp" | awk '{print $1}')
  dur=$(echo "$resp" | awk '{print $2}')
  case "$code" in
    200) ok "e2e /v1/messages → 200 (${dur}s)" ;;
    401|403) bad "e2e 鉴权失败 http=$code：核对 cc-authtoken.sk-mem 与 proxy.yaml.apiKey" ;;
    000)     bad "e2e 无响应：proxy 是否在跑？ss -ltnp | grep 8096" ;;
    *)       warn "e2e http=$code (${dur}s)：看 $BODY 前几行" ;;
  esac
  if [ "$VERBOSE" = 1 ] && [ -s "$BODY" ]; then
    echo "    --- body head (400B) ---"
    head -c 400 "$BODY"; echo
  fi
fi

# ─── Layer 4: L0 当日记录 ───────────────────────
echo ""
echo "── Layer 4: L0 当日对话落盘 ────────────────"
today=$(date +%F)
for kind in records conversations; do
  f="$DATA/$kind/$today.jsonl"
  if [ -s "$f" ]; then
    lines=$(wc -l < "$f")
    ok "$kind/$today.jsonl 存在, $lines 行"
  else
    warn "$kind/$today.jsonl 不存在或空（今天可能还没通过 claude-mem 聊过）"
  fi
done

# ─── Layer 5: L2 profiles 场景 ──────────────────
echo ""
echo "── Layer 5: L2 profiles 场景 ────────────────"
if [ ! -d "$DATA/profiles" ]; then
  bad "$DATA/profiles 不存在"
else
  scenes=$(find "$DATA/profiles" -name '*.md' -path '*/scene_blocks/*' 2>/dev/null | wc -l)
  personas=$(find "$DATA/profiles" -name persona.md 2>/dev/null | wc -l)
  if [ "$scenes" -gt 0 ]; then
    ok "L2 场景 $scenes 篇, L3 persona $personas 份"
    if [ "$VERBOSE" = 1 ]; then
      find "$DATA/profiles" -name '*.md' -path '*/scene_blocks/*' | sed 's|.*/scene_blocks/||; s|^|      |'
    fi
  else
    warn "L2 场景为 0（还没沉淀过 claude-mem 会话）"
  fi
fi

# ─── 总结 ──────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
printf "总计: %s%d passed%s / %s%d warned%s / %s%d failed%s\n" \
  "$GREEN" "$PASS" "$RESET" "$YELLOW" "$WARN" "$RESET" "$RED" "$FAIL" "$RESET"
exit $(( FAIL > 0 ? 1 : 0 ))
