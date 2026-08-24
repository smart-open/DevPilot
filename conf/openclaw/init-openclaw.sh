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

# ---- 2.1 网关 Token 默认化 ----
# 若未设置或仍为占位符 change-me-to-secure-token，则自动生成安全随机 Token，
# 避免用户误用占位符导致“使用占位符 token 无法登录 / 不安全”。
if [ -z "${OPENCLAW_GATEWAY_TOKEN}" ] || [ "${OPENCLAW_GATEWAY_TOKEN}" = "change-me-to-secure-token" ]; then
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 24 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"
    echo "[init] 未检测到安全 Gateway Token，已自动生成随机 Token（请妥善保存，重新生成需清 data/openclaw/openclaw.json）"
fi
export OPENCLAW_GATEWAY_TOKEN

# ---- 2.2 飞书机器人名称默认化 ----
FEISHU_BOT_NAME="${FEISHU_BOT_NAME:-DevPilot助手}"
export FEISHU_BOT_NAME

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
        -e "s|{{FEISHU_BOT_NAME}}|${FEISHU_BOT_NAME}|g" \
        -e "s|{{REDIS_PASSWORD}}|${REDIS_PASSWORD}|g" \
        "${TEMPLATE_FILE}" > "${CONFIG_FILE}"

    echo "[init] openclaw.json 已生成: ${CONFIG_FILE}"
else
    echo "[init] openclaw.json 已存在，跳过生成"
fi

# ---- 3.1 确保 Web UI 允许 HTTP 明文访问（虚拟机 / 局域网浏览器访问场景）----
# 浏览器经 http://<VM_IP>:18789 访问时，controlUi 默认要求安全认证，
# 会拦截 WebSocket 握手，表现为“浏览器无法完成 Gateway 连接”。
# 设为 true 放行（仅建议受信任内网 / 已套反向代理终止 TLS 的场景使用）。
openclaw config set gateway.controlUi.allowInsecureAuth true 2>/dev/null || true

# ---- 3.2 强制 Gateway 绑定模式为 lan，避免默认 loopback 导致设备配对/远端访问失败 ----
# 错误 "Gateway is only bound to loopback. Set gateway.bind=lan..." 即因此。
# 配置文件模板虽已写 "bind": "lan"，但某些版本 CLI 启动时会回退到 loopback，
# 故在启动前用 config set 显式覆写并同步端口。
if [ -f "${CONFIG_FILE}" ]; then
    openclaw config set gateway.bind lan 2>/dev/null || true
    openclaw config set gateway.port "${OPENCLAW_GATEWAY_PORT:-18789}" 2>/dev/null || true
fi

# ---- 3.3 OpenClaw 现以 network_mode: host 运行，Redis 必须经宿主机回环访问 ----
# 无论 openclaw.json 是本次新生成还是历史残留，均确保 redis 地址指向 127.0.0.1:6379，
# 否则 openclaw 在 host 网络下无法解析 bridge 网络的 “redis” 主机名。
if [ -f "${CONFIG_FILE}" ]; then
    sed -i 's#@redis:6379#@127.0.0.1:6379#g' "${CONFIG_FILE}"
fi

# ---- 3.4 修复旧版飞书配置格式 ----
# 旧格式把 appId/appSecret 直接放在 channels.feishu 下，
# 官方要求格式为 channels.feishu.accounts.main.{appId,appSecret,botName} + dmPolicy。
# 若检测到旧格式（存在 channels.feishu.appId 且无 accounts.main），备份并重生成配置。
if [ -f "${CONFIG_FILE}" ]; then
    if grep -q '"appId"' "${CONFIG_FILE}" && ! grep -q '"accounts"' "${CONFIG_FILE}"; then
        echo "[init] 检测到旧版飞书配置格式（channels.feishu.appId 扁平化），备份并重新生成..."
        mv "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%s)"
        # 重新从模板生成
        if [ -f "${TEMPLATE_FILE}" ]; then
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
                -e "s|{{FEISHU_BOT_NAME}}|${FEISHU_BOT_NAME}|g" \
                -e "s|{{REDIS_PASSWORD}}|${REDIS_PASSWORD}|g" \
                "${TEMPLATE_FILE}" > "${CONFIG_FILE}"
            echo "[init] openclaw.json 已按新版飞书格式重新生成"
        fi
    fi
fi

# ---- 3.5 确保 feishu 插件被显式信任 ----
# OpenClaw v2026.7.x 安全策略要求：非 bundled 插件必须在 plugins.allow 中显式声明，
# 否则仅会被 discover 并“可能自动加载”，控制 UI 显示 not configured / 无法编辑 accounts。
# 此处用 node 对现有配置做幂等补丁（容器基于 node 镜像，node 一定可用）。
if [ -f "${CONFIG_FILE}" ] && command -v node >/dev/null 2>&1; then
    node -e "
        const fs = require('fs');
        const path = '${CONFIG_FILE}';
        const cfg = JSON.parse(fs.readFileSync(path, 'utf8'));
        if (!cfg.plugins) cfg.plugins = {};
        if (!Array.isArray(cfg.plugins.allow)) cfg.plugins.allow = [];
        if (!cfg.plugins.allow.includes('feishu')) {
            cfg.plugins.allow.push('feishu');
            fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
            console.log('[init] 已将 feishu 加入 plugins.allow');
        }
    " 2>/dev/null || echo "[warn] plugins.allow 补丁失败，请检查 ${CONFIG_FILE}"
fi

# ---- 3.6 飞书凭据空值告警 ----
# 若 .env 未填写 FEISHU_APP_ID/FEISHU_APP_SECRET，频道即使配置正确也无法启动。
if [ -z "${FEISHU_APP_ID}" ] || [ -z "${FEISHU_APP_SECRET}" ]; then
    echo "[warn] FEISHU_APP_ID 或 FEISHU_APP_SECRET 为空，飞书频道将保持未配置状态。"
    echo "[warn] 请在 .env 中填写后重新执行 'sh deploy.sh'。"
fi

# ---- 4. 安装/启用飞书插件（WebSocket 长连接模式） ----
# OpenClaw 新版已内置 bundled Feishu；旧版仍需手动安装。此处做兼容处理：
# 若 plugins list 中无 feishu 相关条目则尝试安装，失败也不阻塞启动。
echo "[init] 检查飞书插件 ..."
if ! openclaw plugins list 2>/dev/null | grep -qE "feishu|@openclaw/feishu"; then
    echo "[init] 未检测到飞书插件，尝试安装 @openclaw/feishu（新版内置则可能跳过）..."
    if openclaw plugins install @openclaw/feishu 2>/dev/null; then
        echo "[init] 飞书插件安装/注册成功"
    else
        echo "[warn] 飞书插件安装命令返回非零；OpenClaw 新版可能已内置 bundled Feishu，继续启动..."
    fi
else
    echo "[init] 飞书插件已安装"
fi

# ---- 5. 启动 OpenClaw Gateway ----
echo "[init] 启动 OpenClaw Gateway ..."
echo "  - 端口: ${OPENCLAW_GATEWAY_PORT:-18789}"
echo "  - 绑定模式: lan（强制）"
echo "  - 飞书模式: WebSocket 长连接（默认）"
echo "  - 模型 Provider: ${ACTIVE_PROVIDER}"
echo "  - Redis: 127.0.0.1:6379"
echo "========================================"

# 注意：OpenClaw 的 lan 是 --bind 的取值（非子命令），gateway 子命令无 --config 选项。
# 正确语法：openclaw gateway [run] --bind lan --allow-unconfigured
# 配置由 OPENCLAW_HOME（=/data/openclaw）下的 openclaw.json 自动加载，无需 --config。
# --token 显式兜底（默认值即 OPENCLAW_GATEWAY_TOKEN 环境变量），避免 bind=lan 因缺认证被拒。
exec openclaw gateway --bind lan --allow-unconfigured --token "${OPENCLAW_GATEWAY_TOKEN}"
