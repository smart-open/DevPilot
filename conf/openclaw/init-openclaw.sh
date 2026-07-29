#!/bin/bash
set -e

# ============================================================
# OpenClaw 初始化启动脚本
# 功能：配置生成、飞书插件安装、Gateway 启动
# ============================================================

OPENCLAW_HOME="/data/openclaw"
CONFIG_FILE="${OPENCLAW_HOME}/openclaw.json"

echo "========================================"
echo "  OpenClaw 初始化启动"
echo "========================================"

# ---- 1. 确保数据目录存在 ----
mkdir -p "${OPENCLAW_HOME}"

# ---- 2. 首次启动：从模板创建配置 ----
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "[init] 首次启动，从模板生成 openclaw.json ..."

    # 读取模板
    TEMPLATE_FILE="/app/conf/openclaw.default.json"
    if [ ! -f "${TEMPLATE_FILE}" ]; then
        echo "[error] 模板文件不存在: ${TEMPLATE_FILE}"
        exit 1
    fi

    # 替换模板中的占位符为实际环境变量值
    sed \
        -e "s|{{AGNES_API_KEY}}|${AGNES_API_KEY}|g" \
        -e "s|{{AGNES_BASE_URL}}|${AGNES_BASE_URL}|g" \
        -e "s|{{OPENCLAW_GATEWAY_TOKEN}}|${OPENCLAW_GATEWAY_TOKEN}|g" \
        -e "s|{{FEISHU_APP_ID}}|${FEISHU_APP_ID}|g" \
        -e "s|{{FEISHU_APP_SECRET}}|${FEISHU_APP_SECRET}|g" \
        -e "s|{{REDIS_PASSWORD}}|${REDIS_PASSWORD}|g" \
        "${TEMPLATE_FILE}" > "${CONFIG_FILE}"

    echo "[init] openclaw.json 已生成: ${CONFIG_FILE}"
else
    echo "[init] openclaw.json 已存在，跳过生成"
fi

# ---- 3. 安装飞书插件（WebSocket 长连接模式） ----
echo "[init] 检查飞书插件 ..."
if ! openclaw plugins list 2>/dev/null | grep -q "feishu"; then
    echo "[init] 安装飞书插件（WebSocket 长连接模式）..."
    openclaw plugins install @openclaw/feishu || {
        echo "[warn] 飞书插件安装失败，尝试使用内置飞书配置"
    }
else
    echo "[init] 飞书插件已安装"
fi

# ---- 4. 启动 OpenClaw Gateway ----
echo "[init] 启动 OpenClaw Gateway ..."
echo "  - 端口: ${OPENCLAW_GATEWAY_PORT:-18789}"
echo "  - 飞书模式: WebSocket 长连接（默认）"
echo "  - 模型 Provider: agnes-ai"
echo "  - Redis: redis:6379"
echo "========================================"

exec openclaw gateway \
    --bind lan \
    --allow-unconfigured \
    --config "${CONFIG_FILE}"
