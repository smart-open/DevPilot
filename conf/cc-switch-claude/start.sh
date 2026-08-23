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

# 设置 ANTHROPIC 兼容变量（供 Claude Code fallback 使用）
export ANTHROPIC_BASE_URL="${ACTIVE_BASE_URL}"
export ANTHROPIC_API_KEY="${ACTIVE_API_KEY}"
export ANTHROPIC_MODEL="${ACTIVE_MODEL}"

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
# 4. 根据 LLM_PLATFORM 自动配置 CC-Switch 供应商
# ============================================================
CC_SWITCH_DIR="${HOME}/.cc-switch"
CC_SWITCH_CONFIG="${CC_SWITCH_DIR}/config.json"

mkdir -p "${CC_SWITCH_DIR}"

# 仅在配置文件不存在时写入，避免覆盖用户自定义配置
if [ ! -f "${CC_SWITCH_CONFIG}" ]; then
    echo "[start] 初始化 ${ACTIVE_PROVIDER} 供应商配置 ..."

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
    echo "[start] ${ACTIVE_PROVIDER} 供应商配置已写入 ${CC_SWITCH_CONFIG}"
else
    echo "[start] 已存在 CC-Switch 配置文件，跳过自动配置: ${CC_SWITCH_CONFIG}"
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
echo "  ${ACTIVE_PROVIDER} 供应商已自动配置（见 ~/.cc-switch/config.json）"
echo "    Claude Code 将通过 CC-Switch 使用 ${ACTIVE_PROVIDER} 供应商"
echo ""
echo "  自动部署: $( [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ] && echo "已启用" || echo "未启用" )"
echo ""
echo "  Git 版本:"
git --version
echo ""
echo "========================================"

# ---- 8. 保持容器运行 ----
wait ${CC_SWITCH_PID}
