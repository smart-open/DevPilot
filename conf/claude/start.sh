#!/bin/bash
set -e

# ============================================================
# DevPilot Claude Code + LiteLLM 合体容器启动脚本
# 后台拉起 litellm（venv，监听 0.0.0.0:4000），Claude Code 经同容器
# http://127.0.0.1:4000 访问，无需跨容器网络。
# 根据 LLM_PLATFORM 动态配置大模型供应商，支持 agnes/deepseek/glm/ark/bailian。
# ============================================================

# 统一 LLM_PLATFORM 解析收敛到 cicd/lib/common.sh:configure_platform()。
# Dockerfiles/claude/Dockerfile 已 COPY 此文件到镜像内
# /usr/local/lib/devpilot-common.sh，本地开发时回退到相对路径。
if [ -f /usr/local/lib/devpilot-common.sh ]; then
    source /usr/local/lib/devpilot-common.sh
elif [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../cicd/lib/common.sh" ]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../cicd/lib/common.sh"
fi

echo "========================================"
echo "  Claude Code + LiteLLM 合体容器"
echo "========================================"

# ============================================================
# 1. 根据 LLM_PLATFORM 解析当前平台配置（统一走 common.sh:configure_platform）
# ============================================================
LLM_PLATFORM="${LLM_PLATFORM:-agnes}"
ACTIVE_PROVIDER=""
ACTIVE_BASE_URL=""
ACTIVE_API_KEY=""
ACTIVE_MODEL=""

configure_platform "${LLM_PLATFORM}"
# Claude 容器视角下 agnes 全名是 "agnes-ai"（与 deploy.sh / docker-run.sh 对齐）
if [ "${LLM_PLATFORM}" = "agnes" ]; then
    ACTIVE_PROVIDER="agnes-ai"
else
    ACTIVE_PROVIDER="${LLM_PLATFORM}"
fi
ACTIVE_BASE_URL="${LLM_BASE_URL}"
ACTIVE_API_KEY="${LLM_API_KEY}"
ACTIVE_MODEL="${LLM_MODEL}"

# 验证 API Key 是否已设置
if [ -z "${ACTIVE_API_KEY}" ] || echo "${ACTIVE_API_KEY}" | grep -q "^your-"; then
    echo "[error] ${LLM_PLATFORM} 平台的 API Key 未正确设置"
    echo "[error] 请检查 .env 文件中对应平台的 API Key 配置"
    exit 1
fi

# LITELLM_MASTER_KEY 验证（litellm 鉴权 + Claude Code 携带的 API Key）
LITELLM_AUTH_KEY="${LITELLM_MASTER_KEY}"
if [ -z "${LITELLM_AUTH_KEY}" ]; then
    echo "[error] LITELLM_MASTER_KEY 未设置，litellm 无法启动"
    echo "[error] 请运行 ./init.sh 自动生成，或在 .env 手动设置 32+ 位随机值"
    exit 1
fi
export LITELLM_MASTER_KEY

# ============================================================
# 2. 启动 litellm（后台，venv；监听 0.0.0.0:4000，同容器 127.0.0.1:4000 可达）
# ============================================================
LITELLM_VENV="/opt/litellm/venv"
LITELLM_DIR="/opt/litellm"
LITELLM_CONFIG="${LITELLM_DIR}/litellm_config.yaml"

# 生成配置（gen_config.py 读环境变量各平台 key，仅注册 key 有效的平台为模型）
"${LITELLM_VENV}/bin/python" "${LITELLM_DIR}/gen_config.py"

# 后台启动 litellm
"${LITELLM_VENV}/bin/litellm" --config "${LITELLM_CONFIG}" --port 4000 --host 0.0.0.0 &
LITELLM_PID=$!
echo "[start] litellm 已启动 (PID=${LITELLM_PID})，监听 0.0.0.0:4000"

# 等 litellm 就绪（最多 30s）
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
        echo "[start] litellm 就绪 (HTTP 200)"
        break
    fi
    if [ "$i" = "30" ]; then
        echo "[warn] litellm 30s 内未就绪，Claude Code 调用可能失败"
    fi
    sleep 1
done

# ============================================================
# 3. Claude Code 配置（经同容器 litellm 127.0.0.1:4000 访问各平台）
#   litellm 暴露 Anthropic Messages 端点（/v1/messages），翻译成 OpenAI Chat
#   Completions 转发各平台 OpenAI 兼容端点。因此 deepseek/glm/ark/bailian
#   等无原生 Anthropic 端点的平台也能被 Claude Code 使用。
# ============================================================
LITELLM_PROXY_URL="${LITELLM_PROXY_URL:-http://127.0.0.1:4000}"
LLM_PLATFORM_LC="$(echo "${LLM_PLATFORM}" | tr '[:upper:]' '[:lower:]')"

export ANTHROPIC_BASE_URL="${LITELLM_PROXY_URL}"
export ANTHROPIC_API_KEY="${LITELLM_AUTH_KEY}"
export ANTHROPIC_MODEL="${LLM_PLATFORM_LC}/${ACTIVE_MODEL}"

# Claude Code 配置目录
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

# settings.json 仅首次生成（保留用户自定义；改 LLM_PLATFORM 需删该文件重启）
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR}/settings.json"
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

echo ""
echo "[start] 大模型平台配置："
echo "  - 平台:         ${LLM_PLATFORM}"
echo "  - 供应商:       ${ACTIVE_PROVIDER}"
echo "  - API 地址:     ${ACTIVE_BASE_URL}"
echo "  - 模型:         ${ACTIVE_MODEL}"
echo "  - API Key:      $(echo "${ACTIVE_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"
echo "  - 协议:         OpenAI Chat Completion"
echo "  - litellm PID:  ${LITELLM_PID}（127.0.0.1:4000）"
echo ""

# ============================================================
# 4. 自动部署钩子
# ============================================================
if [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ]; then
    echo "[start] 自动部署已启用，检查 workspace 中的服务..."
    # cicd 目录以只读卷挂载到 /opt/devpilot/cicd（见 docker-compose.yml）；
    # workspace 挂载在 /workspace。显式传 WORKSPACE_DIR，避免 post-dev-hook.sh
    # 用 SCRIPT_DIR/../.. 推算出 /opt/devpilot/workspace（不存在）导致钩子静默失效。
    WORKSPACE_DIR=/workspace bash /opt/devpilot/cicd/service-deploy/post-dev-hook.sh 2>/dev/null || true
fi

# ============================================================
# 5. 打印使用说明 + 保活
# ============================================================
echo "========================================"
echo "  容器已就绪（Claude Code + litellm 合体）"
echo "========================================"
echo "  当前平台: ${LLM_PLATFORM} (${ACTIVE_PROVIDER})"
echo "  模型:     ${ACTIVE_MODEL}"
echo "  litellm:  http://127.0.0.1:4000（同容器，Claude Code 经此路由）"
echo ""
echo "  使用 Claude Code:"
echo "    docker compose exec claude-litellm claude"
echo ""
echo "  自动部署: $( [ "${DEVPILOT_AUTO_DEPLOY}" = "true" ] && echo "已启用" || echo "未启用" )"
echo "  Git:      $(git --version)"
echo "========================================"

# 保活：前台 tail，退出时 kill litellm 子进程
trap 'kill ${LITELLM_PID} 2>/dev/null; exit 0' INT TERM
tail -f /dev/null
