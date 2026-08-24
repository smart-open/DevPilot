#!/bin/bash
set -e

# ============================================================
# CC-Switch + Claude Code 合体容器启动脚本
# 根据 LLM_PLATFORM 环境变量动态配置大模型供应商
# 支持：agnes、deepseek、glm、ark、bailian
# 所有平台均走 OpenAI Chat Completion 协议
# ============================================================

echo "========================================"
echo "  CC-Switch + Claude Code 合体容器"
echo "========================================"

# ============================================================
# 1. 根据 LLM_PLATFORM 解析当前平台的配置
# ============================================================
LLM_PLATFORM="${LLM_PLATFORM:-agnes}"
ACTIVE_PROVIDER=""
ACTIVE_BASE_URL=""
ACTIVE_API_KEY=""
ACTIVE_MODEL=""

case "${LLM_PLATFORM}" in
    agnes)
        ACTIVE_PROVIDER="agnes-ai"
        ACTIVE_BASE_URL="${AGNES_BASE_URL:-https://api.agnes-ai.cn/v1}"
        ACTIVE_API_KEY="${AGNES_API_KEY}"
        ACTIVE_MODEL="${AGNES_MODEL:-agnes-2.5-flash}"
        ;;
    deepseek)
        ACTIVE_PROVIDER="deepseek"
        ACTIVE_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/v1}"
        ACTIVE_API_KEY="${DEEPSEEK_API_KEY}"
        ACTIVE_MODEL="${DEEPSEEK_MODEL:-DeepSeek-V4-Flash}"
        ;;
    glm)
        ACTIVE_PROVIDER="glm"
        ACTIVE_BASE_URL="${GLM_BASE_URL:-https://open.bigmodel.cn/api/paas/v4}"
        ACTIVE_API_KEY="${GLM_API_KEY}"
        ACTIVE_MODEL="${GLM_MODEL:-GLM-5.2}"
        ;;
    ark)
        ACTIVE_PROVIDER="ark"
        ACTIVE_BASE_URL="${ARK_BASE_URL:-https://ark.cn-beijing.volces.com/api/v3}"
        ACTIVE_API_KEY="${ARK_API_KEY}"
        ACTIVE_MODEL="${ARK_MODEL:-doubao-seed-2.1-turbo}"
        ;;
    bailian)
        ACTIVE_PROVIDER="bailian"
        ACTIVE_BASE_URL="${BAILIAN_BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
        ACTIVE_API_KEY="${BAILIAN_API_KEY}"
        ACTIVE_MODEL="${BAILIAN_MODEL:-Qwen3.7-Plus}"
        ;;
    *)
        echo "[warn] 未知 LLM_PLATFORM=${LLM_PLATFORM}，回退到 agnes"
        ACTIVE_PROVIDER="agnes-ai"
        ACTIVE_BASE_URL="${AGNES_BASE_URL:-https://api.agnes-ai.cn/v1}"
        ACTIVE_API_KEY="${AGNES_API_KEY}"
        ACTIVE_MODEL="${AGNES_MODEL:-agnes-2.5-flash}"
        ;;
esac

# 验证 API Key 是否已设置
if [ -z "${ACTIVE_API_KEY}" ] || echo "${ACTIVE_API_KEY}" | grep -q "^your-"; then
    echo "[error] ${LLM_PLATFORM} 平台的 API Key 未正确设置"
    echo "[error] 请检查 .env 文件中对应平台的 API Key 配置"
    exit 1
fi

# 推导 Claude Code 专用的 Anthropic Messages 兼容端点
# 关键：Claude Code 走 Anthropic Messages API，请求路径固定为 ${BASE}/v1/messages；
# 而上游 OpenAI 端点（ACTIVE_BASE_URL）已含 /v1 等路径后缀（OpenAI 客户端直接拼 /chat/completions）。
# 若直接复用 ACTIVE_BASE_URL，Claude Code 会打到 .../v1/v1/messages → 404 → 报“模型不存在/无权限”。
# 因此必须剥离 /v1、/v3、/v4、/compatible-mode/v1 等后缀，使拼出的路径正确。
# 仅 agnes 原生提供 Anthropic Messages 兼容端点（已验证 https://api.agnes-ai.cn/v1/messages 返回 401 路由存在）。
ACTIVE_ANTHROPIC_BASE_URL="$(echo "${ACTIVE_BASE_URL}" | sed -E 's#/compatible-mode/v1/?$##; s#/v[0-9]+/?$##')"

# 设置 ANTHROPIC 兼容变量（供 Claude Code 直接使用）
export ANTHROPIC_BASE_URL="${ACTIVE_ANTHROPIC_BASE_URL}"
export ANTHROPIC_API_KEY="${ACTIVE_API_KEY}"
export ANTHROPIC_MODEL="${ACTIVE_MODEL}"

# 同时持久化到 Claude Code 配置文件，避免 CC-Switch Web UI 的 provider 切换在 v0.21.0 中
# 因调用桌面端独占 API 而失败，导致 Claude Code 无法启动。
CLAUDE_CONFIG_DIR="${HOME}/.claude"
mkdir -p "${CLAUDE_CONFIG_DIR}"

# 跳过首次联网登录验证（国内/第三方 API 必需）
if [ ! -f "${HOME}/.claude.json" ]; then
    cat > "${HOME}/.claude.json" <<'EOF'
{
  "hasCompletedOnboarding": true
}
EOF
    echo "[start] 已生成 ~/.claude.json（跳过首次登录验证）"
fi

# Claude Code 全局 settings.json，直接指向当前激活的模型供应商
# 注：CC-Switch Web UI 理论上可接管该文件，但 v0.21.0 Web Server 模式下
#     "启用 Provider" 按钮会触发桌面端 invoke/check_env_conflicts 导致失败。
#     此处预先生成，使 Claude Code 不依赖 CC-Switch UI 即可工作。
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR}/settings.json"
cat > "${CLAUDE_SETTINGS}" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${ACTIVE_ANTHROPIC_BASE_URL}",
    "ANTHROPIC_API_KEY": "${ACTIVE_API_KEY}",
    "ANTHROPIC_MODEL": "${ACTIVE_MODEL}"
  }
}
EOF
echo "[start] 已生成 Claude Code 配置文件: ${CLAUDE_SETTINGS}"


echo "[start] 大模型平台配置："
echo "  - 平台:         ${LLM_PLATFORM}"
echo "  - 供应商:       ${ACTIVE_PROVIDER}"
echo "  - API 地址:     ${ACTIVE_BASE_URL}"
echo "  - 模型:         ${ACTIVE_MODEL}"
echo "  - API Key:      $(echo "${ACTIVE_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"
echo "  - 协议:         OpenAI Chat Completion"
echo ""

# ============================================================
# 2. 启动 CC-Switch Web（后台）
# ============================================================
echo "[start] 启动 CC-Switch Web ..."
echo "  - Web UI 端口: ${PORT:-8890}"
echo "  - 绑定地址: ${HOST:-0.0.0.0}"
echo "  - Home 目录: ${HOME}"

# ---- 2.0 若设置了 CC_SWITCH_WEB_PASSWORD，则覆盖默认生成的 Web 登录密码 ----
# cc-switch-web 采用 file-based credentials（首次运行自动生成 ~/.cc-switch/web_password）。
# 本段在启动前将环境变量指定的密码写入该文件，从而支持从 .env 统一管理 Web 登录密码。
CC_SWITCH_DIR="${HOME}/.cc-switch"
if [ -n "${CC_SWITCH_WEB_PASSWORD}" ]; then
    mkdir -p "${CC_SWITCH_DIR}"
    printf '%s' "${CC_SWITCH_WEB_PASSWORD}" > "${CC_SWITCH_DIR}/web_password"
    echo "[start] 已使用环境变量 CC_SWITCH_WEB_PASSWORD 设置 Web 登录密码"
fi

cc-switch-web &
CC_SWITCH_PID=$!
echo "[start] CC-Switch Web PID: ${CC_SWITCH_PID}"

# ============================================================
# 3. 等待 CC-Switch Web 就绪
# ============================================================
echo "[start] 等待 CC-Switch Web 就绪 ..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # CC-Switch Web 需登录（file-based credentials），未鉴权访问返回 401 属正常；
    # 用 curl -s（仅连接失败才判非就绪），不能用 -f（4xx 会被判失败）。
    if curl -s "http://127.0.0.1:${PORT:-8890}" >/dev/null 2>&1; then
        echo "[start] CC-Switch Web 已就绪"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 1
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "[warn] CC-Switch Web 未在 ${MAX_RETRIES}s 内就绪，继续运行..."
fi

# ============================================================
# 4. 向 CC-Switch 写入遗留快照（仅用于 Web UI 展示，不依赖它启用 provider）
# ============================================================
CC_SWITCH_DIR="${HOME}/.cc-switch"
CC_SWITCH_CONFIG="${CC_SWITCH_DIR}/config.json"

mkdir -p "${CC_SWITCH_DIR}"

# 说明：
# - cc-switch-web v0.21.0 的运行时权威存储是 SQLite（~/.cc-switch/cc-switch.db），
#   启动时若数据库为空，会从 ~/.cc-switch/config.json（遗留快照）导入。
# - 但 v0.21.0 Web Server 模式下，Web UI 的 "启用 Provider" / Stream Check 会调用
#   桌面端独占的 Tauri invoke / check_env_conflicts，导致
#   "TypeError: Cannot read properties of undefined (reading 'invoke')" 与 501 报错。
# - 因此本脚本已直接生成 Claude Code 的 ~/.claude/settings.json，Claude Code 不
#   依赖 CC-Switch UI 启用即可工作。
# - 以下 config.json 仅作为遗留快照写入，让 Web UI 能展示 provider 信息；如需真正
#   通过 CC-Switch 路由使用，请改用其 REST API（见运维手册）。
if [ ! -f "${CC_SWITCH_CONFIG}" ]; then
    echo "[start] 写入 CC-Switch 遗留快照配置 ..."

    cat > "${CC_SWITCH_CONFIG}" <<EOF
{
  "providers": {
    "${ACTIVE_PROVIDER}": {
      "baseUrl": "${ACTIVE_BASE_URL}",
      "apiKey": "${ACTIVE_API_KEY}",
      "model": "${ACTIVE_MODEL}",
      "enabled": true
    }
  },
  "activeProvider": "${ACTIVE_PROVIDER}"
}
EOF
    echo "[start] 已写入 ${CC_SWITCH_CONFIG}（仅展示/导入用）"
else
    echo "[start] 已存在 CC-Switch 配置文件，跳过写入: ${CC_SWITCH_CONFIG}"
    echo "[start] 当前激活供应商: $(cat "${CC_SWITCH_CONFIG}" | grep activeProvider | sed 's/.*: "\(.*\)".*/\1/' 2>/dev/null || echo '未知')"
fi

# ============================================================
# 5. 读取并显示 Web 密码
# ============================================================
WEB_PASSWORD=""
WEB_PASSWORD_FILE="${CC_SWITCH_DIR}/web_password"
if [ -f "${WEB_PASSWORD_FILE}" ]; then
    WEB_PASSWORD="$(cat "${WEB_PASSWORD_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "${WEB_PASSWORD}" ]; then
    WEB_PASSWORD="（未找到，请查看 ${WEB_PASSWORD_FILE}）"
fi

# ============================================================
# 6. 自动部署钩子
# ============================================================
if [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ]; then
    echo "[start] 自动部署已启用，检查 workspace 中的服务..."
    bash /workspace/cicd/service-deploy/post-dev-hook.sh 2>/dev/null || true
fi

# ============================================================
# 7. 打印使用说明
# ============================================================
echo "========================================"
echo "  容器已就绪"
echo "========================================"
echo ""
echo "  当前大模型平台: ${LLM_PLATFORM}"
echo "  供应商:         ${ACTIVE_PROVIDER}"
echo "  模型:           ${ACTIVE_MODEL}"
echo "  API 地址:       ${ACTIVE_BASE_URL}"
echo ""
echo "  CC-Switch Web UI:"
echo "    浏览器访问 http://localhost:${PORT:-8890}"
echo "    默认用户名: admin"
echo "    密码: ${WEB_PASSWORD}"
echo ""
echo "  Claude Code 直连模式 (fallback):"
echo "    ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
echo "    ANTHROPIC_MODEL=${ANTHROPIC_MODEL}"
echo ""
echo "  使用 Claude Code:"
echo "    docker compose exec cc-switch-claude claude"
echo ""
echo "  Claude Code 直连配置已写入 ~/.claude/settings.json"
echo "    Claude Code 将直接使用 ${ACTIVE_PROVIDER}（不依赖 CC-Switch UI 启用）"
echo ""
echo "  注意：CC-Switch Web UI v0.21.0 的 '启用 Provider' / Stream Check 按钮"
echo "        在 Web Server 模式下会触发桌面端 API 导致报错（见运维手册说明）。"
echo "        如需通过 CC-Switch 路由切换，请使用其 REST API 而非 Web UI 按钮。"
echo ""
echo "  自动部署: $( [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ] && echo "已启用" || echo "未启用" )"
echo ""
echo "  Git 版本:"
git --version
echo ""
echo "========================================"

# ---- 8. 保持容器运行 ----
wait ${CC_SWITCH_PID}
