#!/bin/bash
set -e

# ============================================================
# CC-Switch + Claude Code 合体容器启动脚本
# CC-Switch Web 通过 PORT 和 HOST 环境变量配置（官方文档）
# ============================================================

echo "========================================"
echo "  CC-Switch + Claude Code 合体容器"
echo "========================================"

# ---- 1. 启动 CC-Switch Web（后台） ----
echo "[start] 启动 CC-Switch Web ..."
echo "  - Web UI 端口: ${PORT:-8890}"
echo "  - 绑定地址: ${HOST:-0.0.0.0}"
echo "  - Home 目录: ${HOME}"

# 后台启动 CC-Switch Web（读取 PORT 和 HOST 环境变量）
cc-switch-web &
CC_SWITCH_PID=$!
echo "[start] CC-Switch Web PID: ${CC_SWITCH_PID}"

# ---- 2. 等待 CC-Switch Web 就绪 ----
echo "[start] 等待 CC-Switch Web 就绪 ..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -sf "http://127.0.0.1:${PORT:-8890}" >/dev/null 2>&1; then
        echo "[start] CC-Switch Web 已就绪"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 1
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "[warn] CC-Switch Web 未在 ${MAX_RETRIES}s 内就绪，继续运行..."
fi

# ---- 3. 自动配置 agnes-ai 供应商 ----
CC_SWITCH_DIR="${HOME}/.cc-switch"
CC_SWITCH_CONFIG="${CC_SWITCH_DIR}/config.json"

mkdir -p "${CC_SWITCH_DIR}"

# 仅在配置文件不存在时写入，避免覆盖用户自定义配置
if [ ! -f "${CC_SWITCH_CONFIG}" ]; then
    echo "[start] 初始化 agnes-ai 供应商配置 ..."

    AGNES_MODEL="${ANTHROPIC_MODEL:-agnes-2.0-flash}"
    AGNES_BASE_URL_VAL="${AGNES_BASE_URL:-${ANTHROPIC_BASE_URL}}"
    AGNES_API_KEY_VAL="${AGNES_API_KEY:-${ANTHROPIC_API_KEY}}"

    if [ -z "${AGNES_BASE_URL_VAL}" ] || [ -z "${AGNES_API_KEY_VAL}" ]; then
        echo "[warn] AGNES_BASE_URL 或 AGNES_API_KEY 环境变量未设置，跳过自动配置"
        echo "[warn] 请在 CC-Switch Web UI 中手动配置 agnes-ai 供应商"
    else
        cat > "${CC_SWITCH_CONFIG}" <<EOF
{
  "providers": {
    "agnes-ai": {
      "baseUrl": "${AGNES_BASE_URL_VAL}",
      "apiKey": "${AGNES_API_KEY_VAL}",
      "model": "${AGNES_MODEL}",
      "enabled": true
    }
  },
  "activeProvider": "agnes-ai"
}
EOF
        echo "[start] agnes-ai 供应商配置已写入 ${CC_SWITCH_CONFIG}"
    fi
else
    echo "[start] 已存在 CC-Switch 配置文件，跳过自动配置: ${CC_SWITCH_CONFIG}"
fi

# ---- 4. 读取并显示 Web 密码 ----
WEB_PASSWORD=""
WEB_PASSWORD_FILE="${CC_SWITCH_DIR}/web_password"
if [ -f "${WEB_PASSWORD_FILE}" ]; then
    WEB_PASSWORD="$(cat "${WEB_PASSWORD_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "${WEB_PASSWORD}" ]; then
    WEB_PASSWORD="（未找到，请查看 ${WEB_PASSWORD_FILE}）"
fi

# ---- 5. 自动部署钩子 ----
if [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ]; then
    echo "[start] 自动部署已启用，检查 workspace 中的服务..."
    bash /workspace/cicd/service-deploy/post-dev-hook.sh 2>/dev/null || true
fi

# ---- 6. 打印使用说明 ----
echo "========================================"
echo "  容器已就绪"
echo "========================================"
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
echo "  agnes-ai 供应商已自动配置（见 ~/.cc-switch/config.json）"
echo "    Claude Code 将通过 CC-Switch 使用 agnes-ai 供应商"
echo ""
echo "  自动部署: $( [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ] && echo "已启用" || echo "未启用" )"
echo ""
echo "  Git 版本:"
git --version
echo ""
echo "========================================"

# ---- 7. 保持容器运行 ----
wait ${CC_SWITCH_PID}
