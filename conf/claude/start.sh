#!/bin/bash
set -e

# ============================================================
# Claude Code 合体容器启动脚本
# 根据 LLM_PLATFORM 环境变量动态配置大模型供应商
# 支持：agnes、deepseek、glm、ark、bailian
# 通过本地 litellm 代理（http://litellm:4000）暴露 Anthropic Messages 端点，
# 翻译成 OpenAI Chat Completions 转发给各平台。
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

# Claude Code 通过本地 litellm 代理访问各平台（复刻 CC-Switch 官方"本地路由"）：
#   litellm 暴露 Anthropic Messages 端点（/v1/messages），并翻译成 OpenAI Chat Completions
#   转发给各平台 OpenAI 兼容端点。因此 deepseek/glm/ark/bailian 等无原生 Anthropic 端点的
#   平台也能被 Claude Code 使用（之前的直连方式仅 agnes 可用）。
# 代理地址与鉴权密钥必须与 docker-compose 的 litellm 服务完全一致：
#   - ANTHROPIC_BASE_URL = http://litellm:4000   （compose 服务名，同 devpilot-network）
#   - ANTHROPIC_API_KEY  = LITELLM_MASTER_KEY     （litellm general_settings.master_key）
#   - ANTHROPIC_MODEL     = <platform>/<model>     （与 litellm 注册的 model_name 对应）
LITELLM_PROXY_URL="${LITELLM_PROXY_URL:-http://litellm:4000}"
LITELLM_AUTH_KEY="${LITELLM_MASTER_KEY}"
if [ -z "${LITELLM_AUTH_KEY}" ]; then
    echo "[error] LITELLM_MASTER_KEY 未设置，Claude Code 无法鉴权访问 litellm"
    echo "[error] 请运行 ./init.sh 自动生成，或在 .env 手动设置 32+ 位随机值"
    exit 1
fi
LLM_PLATFORM_LC="$(echo "${LLM_PLATFORM}" | tr '[:upper:]' '[:lower:]')"

export ANTHROPIC_BASE_URL="${LITELLM_PROXY_URL}"
export ANTHROPIC_API_KEY="${LITELLM_AUTH_KEY}"
export ANTHROPIC_MODEL="${LLM_PLATFORM_LC}/${ACTIVE_MODEL}"

# 持久化到 Claude Code 配置文件（init 时按 .env 与 LLM_PLATFORM 自动生成）
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
# 注：Claude Code 也可通过 devpilot-litellm 路由访问所有供应商（本配置无需 UI 切换）
#     "启用 Provider" 按钮会触发桌面端 invoke/check_env_conflicts 导致失败。
#     此处预先生成，使 Claude Code 不依赖 CC-Switch UI 即可工作。
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR}/settings.json"
# 仅在首次启动时生成（保留用户自定义；如 .env 改了 LLM_PLATFORM，删除该文件后重启即可重新生成）
if [ ! -f "${CLAUDE_SETTINGS}" ]; then
    cat > "${CLAUDE_SETTINGS}" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${LITELLM_PROXY_URL}",
    "ANTHROPIC_API_KEY": "${LITELLM_AUTH_KEY}",
    "ANTHROPIC_MODEL": "${LLM_PLATFORM_LC}/${ACTIVE_MODEL}"
  }
}
EOF
    echo "[start] 已生成 Claude Code 配置文件: ${CLAUDE_SETTINGS}"
else
    echo "[start] Claude Code 配置已存在，保留用户自定义: ${CLAUDE_SETTINGS}"
    echo "       如需按 .env 重新生成，删除该文件后重启容器"
fi


echo "[start] 大模型平台配置："
echo "  - 平台:         ${LLM_PLATFORM}"
echo "  - 供应商:       ${ACTIVE_PROVIDER}"
echo "  - API 地址:     ${ACTIVE_BASE_URL}"
echo "  - 模型:         ${ACTIVE_MODEL}"
echo "  - API Key:      $(echo "${ACTIVE_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"
echo "  - 协议:         OpenAI Chat Completion"
echo ""


# ============================================================
# 6. 自动部署钩子
# ============================================================
if [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ]; then
    echo "[start] 自动部署已启用，检查 workspace 中的服务..."
    # cicd 目录以只读卷挂载到 /opt/devpilot/cicd（见 docker-compose.yml）；
    # workspace 挂载在 /workspace。显式传 WORKSPACE_DIR，避免 post-dev-hook.sh
    # 用 SCRIPT_DIR/../.. 推算出 /opt/devpilot/workspace（不存在）导致钩子静默失效。
    WORKSPACE_DIR=/workspace bash /opt/devpilot/cicd/service-deploy/post-dev-hook.sh 2>/dev/null || true
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
echo "  Claude Code 经 litellm 代理访问 (复刻 CC-Switch 本地路由):"
echo "    ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
echo "    ANTHROPIC_MODEL=${ANTHROPIC_MODEL}"
echo ""
echo "  使用 Claude Code:"
echo "    docker compose exec devpilot-claude claude"
echo ""
echo "  Claude Code 配置已写入 ~/.claude/settings.json"
echo "    Claude Code 通过 litellm(http://litellm:4000) 路由到 ${ACTIVE_PROVIDER}（OpenAI Chat Completions）"
echo ""
echo "  自动部署: $( [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ] && echo "已启用" || echo "未启用" )"
echo ""
echo "  Git 版本:"
git --version
echo ""
echo "========================================"

# ---- 8. 保持容器运行（Claude Code 为交互式 CLI，需前台进程保活） ----
# 使用 tail -f /dev/null 作为永不退出的前台进程（Docker 经典模式）
tail -f /dev/null
