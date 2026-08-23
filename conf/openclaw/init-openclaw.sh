#!/bin/bash
set -e

# ============================================================
# OpenClaw 初始化启动脚本
# 功能：配置生成、飞书插件安装、Gateway 启动
# 支持大模型平台：agnes、deepseek、glm、ark、bailian（与 LLM_PLATFORM 一致）
# 所有平台均走 OpenAI Chat Completion 协议
# ============================================================

OPENCLAW_HOME="/data/openclaw"
CONFIG_FILE="${OPENCLAW_HOME}/openclaw.json"

echo "========================================"
echo "  OpenClaw 初始化启动"
echo "========================================"

# ---- 1. 确保数据目录存在 ----
mkdir -p "${OPENCLAW_HOME}"

# ---- 2. 根据 LLM_PLATFORM 解析当前平台（与 start.sh / llm-init.sh 一致） ----
LLM_PLATFORM="${LLM_PLATFORM:-agnes}"
case "${LLM_PLATFORM}" in
    agnes)
        ACTIVE_PROVIDER="agnes"
        ACTIVE_MODEL="${AGNES_MODEL:-agnes-2.5-flash}"
        ;;
    deepseek)
        ACTIVE_PROVIDER="deepseek"
        ACTIVE_MODEL="${DEEPSEEK_MODEL:-DeepSeek-V4-Flash}"
        ;;
    glm)
        ACTIVE_PROVIDER="glm"
        ACTIVE_MODEL="${GLM_MODEL:-GLM-5.2}"
        ;;
    ark)
        ACTIVE_PROVIDER="ark"
        ACTIVE_MODEL="${ARK_MODEL:-doubao-seed-2.1-turbo}"
        ;;
    bailian)
        ACTIVE_PROVIDER="bailian"
        ACTIVE_MODEL="${BAILIAN_MODEL:-Qwen3.7-Plus}"
        ;;
    *)
        echo "[warn] 未知 LLM_PLATFORM=${LLM_PLATFORM}，回退到 agnes"
        ACTIVE_PROVIDER="agnes"
        ACTIVE_MODEL="${AGNES_MODEL:-agnes-2.5-flash}"
        ;;
esac
ACTIVE_DEFAULT_MODEL="${ACTIVE_PROVIDER}/${ACTIVE_MODEL}"

# ---- 3. 首次启动：从模板创建配置 ----
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "[init] 首次启动，从模板生成 openclaw.json（平台: ${ACTIVE_PROVIDER}）..."

    # 读取模板
    TEMPLATE_FILE="/app/conf/openclaw.default.json"
    if [ ! -f "${TEMPLATE_FILE}" ]; then
        echo "[error] 模板文件不存在: ${TEMPLATE_FILE}"
        exit 1
    fi

    # 替换模板中的占位符为实际环境变量值
    sed \
        -e "s|{{ACTIVE_PROVIDER}}|${ACTIVE_PROVIDER}|g" \
        -e "s|{{ACTIVE_DEFAULT_MODEL}}|${ACTIVE_DEFAULT_MODEL}|g" \
        -e "s|{{AGNES_API_KEY}}|${AGNES_API_KEY}|g" \
        -e "s|{{AGNES_BASE_URL}}|${AGNES_BASE_URL}|g" \
        -e "s|{{DEEPSEEK_API_KEY}}|${DEEPSEEK_API_KEY}|g" \
        -e "s|{{DEEPSEEK_BASE_URL}}|${DEEPSEEK_BASE_URL}|g" \
        -e "s|{{GLM_API_KEY}}|${GLM_API_KEY}|g" \
        -e "s|{{GLM_BASE_URL}}|${GLM_BASE_URL}|g" \
        -e "s|{{ARK_API_KEY}}|${ARK_API_KEY}|g" \
        -e "s|{{ARK_BASE_URL}}|${ARK_BASE_URL}|g" \
        -e "s|{{BAILIAN_API_KEY}}|${BAILIAN_API_KEY}|g" \
        -e "s|{{BAILIAN_BASE_URL}}|${BAILIAN_BASE_URL}|g" \
        -e "s|{{OPENCLAW_GATEWAY_TOKEN}}|${OPENCLAW_GATEWAY_TOKEN}|g" \
        -e "s|{{FEISHU_APP_ID}}|${FEISHU_APP_ID}|g" \
        -e "s|{{FEISHU_APP_SECRET}}|${FEISHU_APP_SECRET}|g" \
        -e "s|{{REDIS_PASSWORD}}|${REDIS_PASSWORD}|g" \
        "${TEMPLATE_FILE}" > "${CONFIG_FILE}"

    echo "[init] openclaw.json 已生成: ${CONFIG_FILE}"
else
    echo "[init] openclaw.json 已存在，跳过生成"
fi

# ---- 4. 安装飞书插件（WebSocket 长连接模式） ----
echo "[init] 检查飞书插件 ..."
if ! openclaw plugins list 2>/dev/null | grep -q "feishu"; then
    echo "[init] 安装飞书插件（WebSocket 长连接模式）..."
    openclaw plugins install @openclaw/feishu || {
        echo "[warn] 飞书插件安装失败，尝试使用内置飞书配置"
    }
else
    echo "[init] 飞书插件已安装"
fi

# ---- 5. 启动 OpenClaw Gateway ----
echo "[init] 启动 OpenClaw Gateway ..."
echo "  - 端口: ${OPENCLAW_GATEWAY_PORT:-18789}"
echo "  - 飞书模式: WebSocket 长连接（默认）"
echo "  - 模型 Provider: ${ACTIVE_PROVIDER}"
echo "  - Redis: redis:6379"
echo "========================================"

exec openclaw gateway \
    --bind lan \
    --allow-unconfigured \
    --config "${CONFIG_FILE}"
