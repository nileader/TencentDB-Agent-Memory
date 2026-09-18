#!/usr/bin/env bash
# apply-proxy-patches.sh
# 一键幂等地把手册 §6.1 / §6.2 / §6.3 三条 patch 打到 MemoryProxy 源码上，然后重启。
# 每条 patch 内部已通过 grep marker 判重，重复执行不会双打。
# 打完自动 stop-all → start-all → status-all。
#
# 使用：
#   ~/.tdai-lab/apply-proxy-patches.sh          # 打全部 + 重启
#   ~/.tdai-lab/apply-proxy-patches.sh --no-restart  # 只打不重启（调试用）
#
# 依赖：python3、bash。node/nvm 由 start-all.sh 自己处理，此脚本不涉及。

set -euo pipefail

HANDLER="$HOME/workspace/install/TencentDB-Agent-Memory/MemoryProxy/src/anthropicHandler.ts"
LAB="$HOME/.tdai-lab"

if [[ ! -f "$HANDLER" ]]; then
  echo "❌ 找不到 $HANDLER —— 请先 clone MemoryProxy 到该路径"
  exit 1
fi

echo "==> target: $HANDLER"
echo "==> backup: ${HANDLER}.bak-applypatches-$(date +%Y%m%d-%H%M%S)"
cp "$HANDLER" "${HANDLER}.bak-applypatches-$(date +%Y%m%d-%H%M%S)"

# ---------------- patch 6.1: Bearer 鉴权头 ----------------
echo ""
echo "==> [6.1] Bearer 鉴权头"
python3 - "$HANDLER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'headers["authorization"] = `Bearer ${effectiveApiKey}`' in s:
    print("ℹ️  patch 6.1 已在，跳过")
    sys.exit(0)
old = '''  if (effectiveApiKey && !target.authHeaders) {
    headers["x-api-key"] = effectiveApiKey;
    delete headers["authorization"];
  }'''
new = '''  if (effectiveApiKey && !target.authHeaders) {
    headers["authorization"] = `Bearer ${effectiveApiKey}`;
    delete headers["x-api-key"];
  }'''
if old not in s:
    print("❌ patch 6.1 锚点匹配失败：源码结构可能改了，需手工比对手册 §6.1")
    sys.exit(2)
open(p, "w").write(s.replace(old, new, 1))
print("✅ patch 6.1 done")
PY

# ---------------- patch 6.2: 剥 output_config ----------------
echo ""
echo "==> [6.2] 剥 CC 客户端 output_config"
python3 - "$HANDLER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if "patch-6.2" in s:
    print("ℹ️  patch 6.2 已在，跳过")
    sys.exit(0)
old = '''  const sanitized = sanitizeThinkingBlocks(result);
  return { body: sanitized.body, sanitizedCount: sanitized.removed };'''
new = '''  // patch-6.2: CC 2.1.220+ 客户端会自动加 output_config，ducky 上游不认，剥掉
  if ((result as Record<string, unknown>).output_config !== undefined) {
    result = { ...result };
    delete (result as Record<string, unknown>).output_config;
  }
  const sanitized = sanitizeThinkingBlocks(result);
  return { body: sanitized.body, sanitizedCount: sanitized.removed };'''
if old not in s:
    print("❌ patch 6.2 锚点匹配失败：buildUpstreamBody 结构变了，需手工比对手册 §6.2")
    sys.exit(2)
open(p, "w").write(s.replace(old, new, 1))
print("✅ patch 6.2 done")
PY

# ---------------- patch 6.3: 出站禁 zstd ----------------
echo ""
echo "==> [6.3] 出站 accept-encoding 白名单（禁 zstd）"
python3 - "$HANDLER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if "patch-6.3" in s:
    print("ℹ️  patch 6.3 已在，跳过")
    sys.exit(0)
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
if old not in s:
    print("❌ patch 6.3 锚点匹配失败：buildUpstreamHeaders 结构变了，需手工比对手册 §6.3")
    sys.exit(2)
open(p, "w").write(s.replace(old, new, 1))
print("✅ patch 6.3 done")
PY

# ---------------- 验证三个 marker 都在 ----------------
echo ""
echo "==> verify markers"
grep -nE 'authorization.*Bearer.*effectiveApiKey|patch-6\.2|patch-6\.3' "$HANDLER" \
  || { echo "❌ 三处 marker 缺失，检查上面输出"; exit 3; }

# ---------------- 重启 ----------------
if [[ "${1:-}" == "--no-restart" ]]; then
  echo ""
  echo "==> --no-restart 指定，跳过 restart。手工重启：$LAB/stop-all.sh && $LAB/start-all.sh"
  exit 0
fi

echo ""
echo "==> restart proxy stack"
"$LAB/stop-all.sh"
"$LAB/start-all.sh"
sleep 10
"$LAB/status-all.sh"

echo ""
echo "✅ all patches applied & stack restarted"
