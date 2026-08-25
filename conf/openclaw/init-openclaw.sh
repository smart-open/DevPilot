#!/bin/bash
set -e

# ============================================================
# OpenClaw 初始化启动脚本
# 功能：配置生成、飞书插件安装、Gateway 启动
# 支持大模型平台：agnes、deepseek、glm、ark、bailian（与 LLM_PLATFORM 一致）
# 所有平台均走 OpenAI Chat Completion 协议
# ============================================================

OPENCLAW_HOME="/data/openclaw"
# OpenClaw 实际将运行时配置写入 ${OPENCLAW_HOME}/.openclaw/openclaw.json（隐藏子目录，
# 行为同 Claude Code 的 ~/.claude）。此前 init 误写为 ${OPENCLAW_HOME}/openclaw.json，
# 导致模板生成 / sed 修正 / node 补丁全部落在 openclaw 从不读取的孤儿文件上，
# 配置正确性只能依赖 openclaw config set 兜底。此处统一指向真实路径。
OPENCLAW_CONFIG_DIR="${OPENCLAW_HOME}/.openclaw"
CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"

echo "========================================"
echo "  OpenClaw 初始化启动"
echo "========================================"

# ---- 1. 确保数据目录存在 ----
mkdir -p "${OPENCLAW_HOME}" "${OPENCLAW_CONFIG_DIR}"

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
    echo "[init] 未检测到安全 Gateway Token，已自动生成随机 Token（请妥善保存，重新生成需清 data/openclaw/.openclaw/openclaw.json）"
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
if [ "${DEVPILLOT_INSECURE_AUTH:-true}" = "true" ]; then
    openclaw config set gateway.controlUi.allowInsecureAuth true 2>/dev/null || true
else
    openclaw config set gateway.controlUi.allowInsecureAuth false 2>/dev/null || true
fi

# ---- 3.1.1 确保 Control UI 允许浏览器来源（allowedOrigins，gateway.bind=lan 时强制校验）----
# 现象：浏览器经 http://localhost:18789/chat（SSH 隧道 / 端口转发）或 http://<VM_IP>:18789
# 访问时提示「浏览器来源不被允许 / 将此浏览器来源添加到 gateway.controlUi.allowedOrigins」。
# 根因：bind=lan 后 Control UI 要求显式白名单 Origin（不支持通配符）。
# 此处每次启动幂等写入 localhost / 127.0.0.1 / 检测到的 LAN IP 三个来源（含当前端口）。
if [ -f "${CONFIG_FILE}" ]; then
    LAN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^127\.' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
    PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
    node -e "
        const fs = require('fs');
        const path = '${CONFIG_FILE}';
        const cfg = JSON.parse(fs.readFileSync(path, 'utf8'));
        if (!cfg.gateway) cfg.gateway = {};
        if (!cfg.gateway.controlUi) cfg.gateway.controlUi = {};
        const port = '${PORT}';
        const origins = new Set(['http://localhost:' + port, 'http://127.0.0.1:' + port]);
        const lanIp = '${LAN_IP}';
        if (lanIp) origins.add('http://' + lanIp + ':' + port);
        cfg.gateway.controlUi.allowedOrigins = Array.from(origins);
        fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
        console.log('[init] allowedOrigins = ' + Array.from(origins).join(', '));
    " 2>/dev/null || echo "[warn] allowedOrigins 设置失败，请手动执行 openclaw config set gateway.controlUi.allowedOrigins"
fi

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
# 否则 openclaw 在 host 网络下无法解析 bridge 网络的 "redis" 主机名。
# 【回退提示】若将来把 openclaw 改回 bridge 网络（加入 devpilot-network），
#   必须删除下方 sed 改写，让配置保留 redis:6379 服务名访问；
#   同时 Redis 的 127.0.0.1:6379 端口绑定也可去掉（bridge 内经服务名访问即可）。
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

# ---- 3.4.1 过滤未完整配置的 provider（避免 baseUrl/apiKey 为空导致网关启动失败）----
# 现象：仅配置 agnes 时，deepseek/glm/ark/bailian 的 baseUrl 经 sed 替换后为空字符串，
# OpenClaw 2026.7.1-2 校验 "models.providers.<id>.baseUrl: Invalid input" → 网关起不来 → 重启循环。
# 处理：仅保留 baseUrl 为合法 URL 且（apiKey 已填真实值 或 为当前激活平台）的 provider；
# 其余（占位符/空值）直接剔除，确保生成的 openclaw.json 永远能通过 schema 校验。
if [ -f "${CONFIG_FILE}" ] && command -v node >/dev/null 2>&1; then
    ACTIVE_PROVIDER="${ACTIVE_PROVIDER:-agnes}" node -e "
        const fs = require('fs');
        const path = '${CONFIG_FILE}';
        const active = process.env.ACTIVE_PROVIDER || 'agnes';
        const cfg = JSON.parse(fs.readFileSync(path, 'utf8'));
        const provs = (cfg.models && cfg.models.providers) || {};
        const isPh = (v) => {
            if (!v) return true;
            return /^your-/i.test(v) || /change-me/i.test(v) || v.includes('{{') || v.includes('}}');
        };
        const kept = {};
        const removed = [];
        for (const [id, p] of Object.entries(provs)) {
            const base = (p.baseUrl || '').trim();
            const key = (p.apiKey || '').trim();
            const baseOk = base.startsWith('http://') || base.startsWith('https://');
            const keyOk = !isPh(key);
            if (baseOk && (keyOk || id === active)) {
                kept[id] = p;
            } else {
                removed.push(id);
            }
        }
        cfg.models = cfg.models || {};
        cfg.models.providers = kept;
        fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
        if (removed.length) console.log('[init] 已过滤未完整配置的 provider: ' + removed.join(', ') + '（在 .env 补全对应 API Key / Base URL 后重新生成即可启用）');
    " 2>/dev/null || echo "[warn] provider 过滤失败，请检查 ${CONFIG_FILE}"
fi

# ---- 3.5 确保 feishu 插件被显式信任（官方 CLI，最可靠；每次启动幂等）----
# OpenClaw v2026.7.x 安全策略要求：非 bundled 插件必须在 plugins.allow 中显式声明，
# 否则仅“discovered”状态，控制 UI 显示 not configured / 无法编辑 accounts。
# 优先用 openclaw config set（OpenClaw 自带写入器，保证 schema 合法）；失败再回退 node 直接改 JSON。
if [ -f "${CONFIG_FILE}" ]; then
    if ! openclaw config set plugins.allow '["feishu"]' 2>/dev/null; then
        if command -v node >/dev/null 2>&1; then
            node -e "
                const fs = require('fs');
                const path = '${CONFIG_FILE}';
                const cfg = JSON.parse(fs.readFileSync(path, 'utf8'));
                if (!cfg.plugins) cfg.plugins = {};
                if (!Array.isArray(cfg.plugins.allow)) cfg.plugins.allow = [];
                if (!cfg.plugins.allow.includes('feishu')) {
                    cfg.plugins.allow.push('feishu');
                    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
                    console.log('[init] 已将 feishu 加入 plugins.allow（node 回退）');
                }
            " 2>/dev/null || echo "[warn] plugins.allow 补丁失败，请检查 ${CONFIG_FILE}"
        fi
    fi
fi

# ---- 3.6 每次启动同步 .env 飞书凭据到配置（解决“改了 .env 重部署不生效”）----
# openclaw.json 已存在时，section 3 的模板生成会被跳过，故此处显式用最新 .env 覆盖凭据。
if [ -f "${CONFIG_FILE}" ]; then
    if [ -n "${FEISHU_APP_ID}" ] && [ "${FEISHU_APP_ID}" != "your-feishu-app-id" ]; then
        openclaw config set channels.feishu.accounts.main.appId "${FEISHU_APP_ID}" 2>/dev/null || true
    fi
    if [ -n "${FEISHU_APP_SECRET}" ] && [ "${FEISHU_APP_SECRET}" != "your-feishu-app-secret" ]; then
        openclaw config set channels.feishu.accounts.main.appSecret "${FEISHU_APP_SECRET}" 2>/dev/null || true
    fi
    openclaw config set channels.feishu.accounts.main.name "${FEISHU_BOT_NAME}" 2>/dev/null || true
fi

# ---- 3.7 飞书凭据空值告警 ----
# 若 .env 未填写真实 FEISHU_APP_ID/FEISHU_APP_SECRET，频道即使配置正确也无法启动。
if [ -z "${FEISHU_APP_ID}" ] || [ -z "${FEISHU_APP_SECRET}" ] || \
   [ "${FEISHU_APP_ID}" = "your-feishu-app-id" ] || [ "${FEISHU_APP_SECRET}" = "your-feishu-app-secret" ]; then
    echo "[warn] FEISHU_APP_ID / FEISHU_APP_SECRET 未填写真实值，飞书频道将保持未配置（not configured）。"
    echo "[warn] 请在 .env 填入飞书开放平台的 App ID 与 App Secret 后重新 'sh deploy.sh'。"
fi

# ---- 3.7.1 启动前配置校验与自愈（防止 Invalid config 触发无限重启循环）----
# 2026.7.1-2 对 openclaw.json 做严格 schema 校验，任意非法字段（如顶层多余 key、gateway 子字段类型不符）
# 都会让网关启动即 Invalid config，进而触发 restart-loop breaker 无限重启刷屏。
# 此处启动前主动校验：校验未通过则尝试 openclaw doctor --fix 自愈，并把详细错误打到日志，
# 便于排障，而不是让容器在崩溃循环里空转。
if command -v openclaw >/dev/null 2>&1; then
    if openclaw config validate >/tmp/oc_validate.log 2>&1; then
        echo "[init] 配置校验通过 ✓"
    else
        echo "[init] 配置校验未通过，尝试 openclaw doctor --fix 自愈…"
        sed -n '1,40p' /tmp/oc_validate.log 2>/dev/null || true
        if openclaw doctor --fix >/tmp/oc_doctor.log 2>&1; then
            echo "[init] 已执行 openclaw doctor --fix，重新校验…"
            openclaw config validate 2>&1 | head -40 || true
        else
            echo "[warn] doctor --fix 未能修复（退出非零）。当前 openclaw.json 顶层或 gateway 字段可能不符合 2026.7.1-2 schema；"
            echo "[warn] 详细错误见 /tmp/oc_doctor.log，请人工核查 openclaw.json 顶层 / gateway 字段后重试。"
            sed -n '1,40p' /tmp/oc_doctor.log 2>/dev/null || true
        fi
    fi
fi

# ---- 3.8 启动前配置自检（便于排障，凭据做掩码；用 node 读文件，避免依赖 config get）----
echo "[init] 配置自检:"
if [ -f "${CONFIG_FILE}" ] && command -v node >/dev/null 2>&1; then
    node -e "
        const fs = require('fs');
        const c = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf8'));
        const bind = (c.gateway && c.gateway.bind) || '未知';
        const allow = (c.plugins && Array.isArray(c.plugins.allow)) ? c.plugins.allow.join(',') : '未知(空)';
        const acct = c.channels && c.channels.feishu && c.channels.feishu.accounts && c.channels.feishu.accounts.main;
        const appId = acct && acct.appId ? acct.appId : '';
        const appIdMask = appId.length > 6 ? appId.slice(0,6) + '***' : (appId || '⚠️ 空');
        console.log('  - Gateway bind:    ' + bind);
        console.log('  - plugins.allow:   ' + allow);
        console.log('  - 飞书 App ID:     ' + appIdMask + (appId && appId.indexOf('your-feishu') === 0 ? '（占位符未替换）' : ''));
    " 2>/dev/null || echo "  - 自检失败（不影响启动）"
else
    echo "  - 跳过（node 不可用或配置文件缺失）"
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
GATEWAY_EXTRA_ARGS=""
if [ "${DEVPILLOT_INSECURE_AUTH:-true}" = "true" ]; then
    GATEWAY_EXTRA_ARGS="--allow-unconfigured"
fi
exec openclaw gateway --bind lan ${GATEWAY_EXTRA_ARGS} --token "${OPENCLAW_GATEWAY_TOKEN}"
