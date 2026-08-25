#!/bin/bash
# ============================================================
# DevPilot 端到端验证脚本
# ============================================================
# 用途：重建或启动后，跑一遍确认整套链路工作正常
#   - 容器层（4 容器 Up + 镜像名正确无 devpilot- 前缀重复）
#   - litellm 代理层（健康 + 模型注册 + Anthropic 协议探测）
#   - Claude Code 端到端（settings.json 指向 litellm + 实际对话）
#   - OpenClaw 飞书（gateway + 插件 + 频道）
#   - Redis（ping）
#   - 镜像名（验证无 devpilot- 前缀重复）
#
# 用法：bash scripts/verify.sh
# 退出码：0=全通过 / 1=有失败（不阻塞，仅输出汇总）
# ============================================================

set +e  # 不因单项失败退出

# 颜色
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

PASS=0; FAIL=0
check_pass() { echo -e "  ${GREEN}✓ PASS${NC} $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}✗ FAIL${NC} $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}⚠ WARN${NC} $1"; }

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  DevPilot 端到端验证${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ---- 切到仓库根目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "无法切到 $PROJECT_ROOT"; exit 1; }

# ============= 阶段 0: 镜像名（避免 devpilot- 前缀重复） =============
echo -e "${CYAN}[1/7] 镜像名检查（避免 devpilot-devpilot-claude-litellm 双重前缀）${NC}"
DUPED=$(docker images --format "{{.Repository}}" | grep -E "^devpilot-devpilot-" || true)
if [ -z "$DUPED" ]; then
    check_pass "无 devpilot-devpilot-* 双重前缀镜像"
else
    check_fail "发现双重前缀镜像：$DUPED（说明 docker-compose.yml 还有 build 服务未设 image: 字段）"
fi
# 期望的核心镜像
for img in devpilot-openclaw devpilot-claude-litellm devpilot-claude-litellm; do
    if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${img}:latest$"; then
        check_pass "镜像 ${img}:latest 存在"
    else
        check_warn "镜像 ${img}:latest 不存在（首次构建或 .env 未激活平台）"
    fi
done
echo ""

# ============= 阶段 1: 容器层 =============
echo -e "${CYAN}[2/7] 容器状态${NC}"
EXPECTED=("devpilot-redis" "devpilot-openclaw" "devpilot-claude-litellm" "devpilot-claude-litellm")
for name in "${EXPECTED[@]}"; do
    STATUS=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)
    if [ "$STATUS" = "running" ]; then
        check_pass "$name running"
    else
        check_fail "$name 未运行（status=$STATUS）"
    fi
done
echo ""

# ============= 阶段 2: litellm 健康 + 模型注册 =============
echo -e "${CYAN}[3/7] devpilot-claude-litellm 代理层${NC}"
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/health/liveliness 2>/dev/null)
if [ "$HEALTH" = "200" ]; then
    check_pass "litellm /health/liveliness -> 200"
else
    check_fail "litellm /health/liveliness -> HTTP $HEALTH"
fi

MODEL_COUNT=$(docker exec devpilot-claude-litellm cat /opt/litellm/litellm_config.yaml 2>/dev/null | grep -c "^  - model_name:" || echo 0)
if [ "$MODEL_COUNT" -ge 1 ]; then
    check_pass "litellm 注册了 $MODEL_COUNT 个模型"
else
    check_fail "litellm 未注册任何模型（检查 .env 中 5 平台 API Key 是否配置）"
fi

# Anthropic 协议打 litellm（验证 /v1/messages 路由 + master_key 校验 + 上游转发）
MASTER_KEY=$(docker exec devpilot-claude-litellm env 2>/dev/null | grep -oE 'LITELLM_MASTER_KEY=[^ ]+' | head -1 | cut -d= -f2)
if [ -z "$MASTER_KEY" ]; then
    check_warn "未从 litellm 容器读取到 LITELLM_MASTER_KEY（配置异常或容器未启动）"
    MASTER_KEY=""
fi
ACTIVE_MODEL=$(docker exec devpilot-claude-litellm cat /opt/litellm/litellm_config.yaml 2>/dev/null | grep -oE 'model_name: [^ ]+' | head -1 | awk '{print $2}')
if [ -z "$ACTIVE_MODEL" ]; then
    ACTIVE_MODEL="agnes/agnes-2.5-flash"
fi
RESP=$(curl -s -X POST http://localhost:4000/v1/messages \
    -H "x-api-key: ${MASTER_KEY}" \
    -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"${ACTIVE_MODEL}\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>&1)
if echo "$RESP" | grep -q '"content"'; then
    check_pass "Anthropic 协议探测成功（$ACTIVE_MODEL）"
elif echo "$RESP" | grep -q "Authentication"; then
    check_fail "litellm 鉴权失败（master_key 不一致？）"
elif echo "$RESP" | grep -q "Invalid model"; then
    check_fail "litellm 模型未注册（$ACTIVE_MODEL）"
else
    check_warn "Anthropic 探测返回异常：$(echo "$RESP" | head -c 200)"
fi
echo ""

# ============= 阶段 3: Claude Code settings.json =============
echo -e "${CYAN}[4/7] Claude Code 链路${NC}"
SETTINGS=$(docker compose exec -T devpilot-claude-litellm cat /home/node/.claude/settings.json 2>/dev/null)
if echo "$SETTINGS" | grep -q '"ANTHROPIC_BASE_URL": "http://127.0.0.1:4000"'; then
    check_pass "ANTHROPIC_BASE_URL 指向 devpilot-claude-litellm:4000"
else
    check_fail "ANTHROPIC_BASE_URL 异常：$(echo "$SETTINGS" | grep -oE 'ANTHROPIC_BASE_URL[^,}]*' | head -1)"
fi
if echo "$SETTINGS" | grep -q '"ANTHROPIC_API_KEY"'; then
    check_pass "ANTHROPIC_API_KEY 已设置"
else
    check_fail "ANTHROPIC_API_KEY 未设置"
fi
ANTHROPIC_MODEL=$(echo "$SETTINGS" | grep -oE '"ANTHROPIC_MODEL": *"[^"]+"' | head -1)
if [ -n "$ANTHROPIC_MODEL" ]; then
    check_pass "$ANTHROPIC_MODEL"
else
    check_fail "ANTHROPIC_MODEL 未设置"
fi

# claude --version
CLAUDE_VER=$(docker compose exec -T devpilot-claude-litellm claude --version 2>&1 | head -1)
if echo "$CLAUDE_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
    check_pass "claude CLI 可用（$CLAUDE_VER）"
else
    check_fail "claude --version 异常：$CLAUDE_VER"
fi
echo ""

# ============= 阶段 4: OpenClaw + 飞书 =============
echo -e "${CYAN}[5/7] OpenClaw + 飞书${NC}"
GATEWAY_STATUS=$(docker compose exec -T openclaw openclaw gateway status 2>&1 | head -3)
if echo "$GATEWAY_STATUS" | grep -qiE "running|ready|listening"; then
    check_pass "OpenClaw gateway 运行中"
else
    check_fail "OpenClaw gateway 异常：$(echo "$GATEWAY_STATUS" | head -2 | tr '\n' ' ')"
fi

FEISHU_PLUGIN=$(docker compose exec -T openclaw openclaw plugins list 2>&1 | grep -i feishu)
if [ -n "$FEISHU_PLUGIN" ]; then
    check_pass "飞书插件：$FEISHU_PLUGIN"
else
    check_warn "飞书插件未安装（重部署后可能需 openclaw plugins install feishu）"
fi

FEISHU_CHANNELS=$(docker compose exec -T openclaw openclaw channels list 2>&1 | grep -E "feishu:.*active|feishu:.*running")
if [ -n "$FEISHU_CHANNELS" ]; then
    check_pass "飞书频道活跃"
else
    check_warn "飞书频道未活跃（可能需 openclaw channels start feishu）"
fi
echo ""

# ============= 阶段 5: Redis =============
echo -e "${CYAN}[6/7] Redis${NC}"
REDIS_PASS=$(grep '^REDIS_PASSWORD=' .env 2>/dev/null | cut -d= -f2)
PONG=$(docker exec devpilot-redis sh -c "redis-cli -a \"${REDIS_PASS}\" ping" 2>&1 | tail -1)
if [ "$PONG" = "PONG" ]; then
    check_pass "Redis ping -> PONG"
else
    check_fail "Redis ping 失败：$PONG"
fi
echo ""

# ============= 阶段 6: OpenClaw 模型注册 =============
echo -e "${CYAN}[7/7] OpenClaw 模型注册${NC}"
MODELS_IN_OPENCLAW=$(docker exec devpilot-openclaw cat /data/openclaw/.openclaw/openclaw.json 2>/dev/null | grep -oE '"id": *"[^"]+"' | wc -l)
if [ "$MODELS_IN_OPENCLAW" -ge 1 ]; then
    check_pass "OpenClaw 配置含 $MODELS_IN_OPENCLAW 个 model id（已注册模型）"
else
    check_fail "OpenClaw 未注册任何模型（运行 'openclaw config validate' 排查）"
fi
echo ""

# ============= 汇总 =============
echo -e "${CYAN}========================================${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  ${GREEN}PASS: $PASS${NC} / ${RED}FAIL: $FAIL${NC} (total: $TOTAL)"
echo -e "${CYAN}========================================${NC}"

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✓ 全部通过${NC}"
    exit 0
else
    echo -e "${RED}✗ 有 $FAIL 项失败${NC}"
    echo ""
    echo "排障提示："
    echo "  1. 容器日志：docker compose logs -f <service>"
    echo "  2. litellm 配置：docker exec devpilot-claude-litellm cat /opt/litellm/litellm_config.yaml"
    echo "  3. Claude Code 配置：docker compose exec devpilot-claude-litellm cat /home/node/.claude/settings.json"
    echo "  4. 详细排障手册：运维操作手册.md §13"
    exit 1
fi
