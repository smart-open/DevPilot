#!/bin/bash
set -e

# ============================================================
# DevPilot 交互式配置向导
# 功能：引导用户填写配置、自动生成密码、生成 .env 文件
# 用法: ./init.sh
# ============================================================

# ---- 加载公共函数库（颜色、日志、密码生成等） ----
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cicd/lib/common.sh"

# ---- 加载版本配置（单一配置源，无需手动询问） ----
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/versions.env"

# ---- 设置错误陷阱（显示出错行号） ----
setup_error_trap

# ---- 读取用户输入（带默认值，用于可选配置） ----
read_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ -n "${default}" ]; then
        if [ "${is_secret}" = "true" ]; then
            local masked=$(echo "${default}" | sed 's/./*/g')
            printf "${CYAN}${prompt}${NC} [当前: ${masked}]: "
        else
            printf "${CYAN}${prompt}${NC} [默认: ${default}]: "
        fi
    else
        printf "${CYAN}${prompt}${NC}: "
    fi

    read -r input
    if [ -z "${input}" ] && [ -n "${default}" ]; then
        eval "${var_name}=\"${default}\""
    else
        eval "${var_name}=\"${input}\""
    fi
}

# ---- 定位项目根目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---- 欢迎信息 ----
print_header "DevPilot 配置向导"
echo -e "  本向导将引导你完成 DevPilot 的配置。"
echo -e "  只需填写 ${GREEN}3 个必填项${NC}，其余将自动生成。"
echo -e "  ${YELLOW}带 [*] 的为必填项${NC}"
echo ""

# ============================================================
# 1. 检查 .env 是否已存在（备份旧配置）
# ============================================================
if [ -f ".env" ]; then
    warn ".env 文件已存在"
    printf "  是否覆盖？(y/N): "
    read -r OVERWRITE
    if [ "${OVERWRITE}" != "y" ] && [ "${OVERWRITE}" != "Y" ]; then
        info "保留现有配置，退出"
        exit 0
    fi
    # 备份旧配置
    cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
    success "已备份旧配置到 .env.bak.*"
fi

# ============================================================
# 2. 第 1 步：必填配置（3 个必填项）
# ============================================================
echo -e "${BLUE}========== 第 1 步：必填配置 ==========${NC}"
echo ""

# 必填：agnes-ai API Key
printf "${CYAN}[*] agnes-ai API Key${NC}: "
read -r AGNES_API_KEY
if [ -z "${AGNES_API_KEY}" ]; then
    die "agnes-ai API Key 不能为空"
fi
success "API Key 已设置"

echo ""
echo -e "  ${YELLOW}在飞书开放平台创建应用后获取以下信息${NC}"
echo -e "  应用类型：企业自建应用 | 事件订阅：长连接模式"
echo ""

# 必填：飞书 App ID
printf "${CYAN}[*] 飞书 App ID${NC}: "
read -r FEISHU_APP_ID
if [ -z "${FEISHU_APP_ID}" ]; then
    die "飞书 App ID 不能为空"
fi
success "App ID 已设置"

# 必填：飞书 App Secret
printf "${CYAN}[*] 飞书 App Secret${NC}: "
read -r FEISHU_APP_SECRET
if [ -z "${FEISHU_APP_SECRET}" ]; then
    die "飞书 App Secret 不能为空"
fi
success "App Secret 已设置"

# ============================================================
# 3. 第 2 步：可选配置（带默认值，直接回车即可）
# ============================================================
echo ""
echo -e "${BLUE}========== 第 2 步：可选配置（直接回车使用默认值） ==========${NC}"
echo ""

read_input "agnes-ai API 地址" "https://apihub.agnes-ai.com/v1" "AGNES_BASE_URL"
read_input "OpenClaw Gateway 端口" "18789" "OPENCLAW_GATEWAY_PORT"
read_input "CC-Switch Web UI 端口" "8890" "CC_SWITCH_WEB_PORT"
read_input "是否启用自动部署 (true/false)" "false" "DEVPILOT_AUTO_DEPLOY"

# ============================================================
# 4. 自动生成安全密码 & 加载版本（静默处理）
# ============================================================
info "自动生成安全密码..."
REDIS_PASSWORD=$(gen_password 32)
OPENCLAW_GATEWAY_TOKEN=$(gen_password 32)
success "Redis 密码与 Gateway Token 已生成"

# 模型默认值
AGNES_MODEL_FLASH="agnes-2.0-flash"

# 版本号从 versions.env 自动加载
success "组件版本已从 versions.env 加载"

# ============================================================
# 5. 生成 .env 文件
# ============================================================
echo ""
echo -e "${BLUE}========== 生成 .env 文件 ==========${NC}"
echo ""

cat > .env << EOF
# ============================================================
# DevPilot 环境变量配置
# 由 init.sh 向导生成 | $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# ---- agnes-ai 大模型配置 ----
AGNES_API_KEY=${AGNES_API_KEY}
AGNES_BASE_URL=${AGNES_BASE_URL}
AGNES_MODEL_FLASH=${AGNES_MODEL_FLASH}

# ---- 飞书配置 ----
# WebSocket 长连接模式：仅需 App ID 和 App Secret
FEISHU_APP_ID=${FEISHU_APP_ID}
FEISHU_APP_SECRET=${FEISHU_APP_SECRET}

# ---- Redis 配置 ----
# 密码由 init.sh 自动生成
REDIS_PASSWORD=${REDIS_PASSWORD}

# ---- OpenClaw 配置 ----
OPENCLAW_VERSION=${OPENCLAW_VERSION}
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}

# ---- CC-Switch Web 配置 ----
CC_SWITCH_VERSION=${CC_SWITCH_VERSION}
CC_SWITCH_WEB_PORT=${CC_SWITCH_WEB_PORT}

# ---- Claude Code 配置 ----
CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}

# ---- Node.js 基础镜像版本 ----
NODE_IMAGE_TAG=${NODE_IMAGE_TAG}

# ---- 时区 ----
TZ=Asia/Shanghai

# ---- 服务自动部署 ----
DEVPILOT_AUTO_DEPLOY=${DEVPILOT_AUTO_DEPLOY}
EOF

success ".env 文件已生成"

# ============================================================
# 6. 配置摘要 & 下一步指引
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${CYAN}配置摘要：${NC}"
echo -e "  agnes-ai API Key:  $(echo "${AGNES_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"
echo -e "  agnes-ai 地址:     ${AGNES_BASE_URL}"
echo -e "  飞书 App ID:       ${FEISHU_APP_ID}"
echo -e "  Redis 密码:        $(echo "${REDIS_PASSWORD}" | sed 's/./*/g')"
echo -e "  Gateway Token:     $(echo "${OPENCLAW_GATEWAY_TOKEN}" | sed 's/./*/g')"
echo -e "  Gateway 端口:      ${OPENCLAW_GATEWAY_PORT}"
echo -e "  Web UI 端口:       ${CC_SWITCH_WEB_PORT}"
echo -e "  自动部署:          ${DEVPILOT_AUTO_DEPLOY}"
echo ""
echo -e "${CYAN}组件版本（来自 versions.env）：${NC}"
echo -e "  Node.js:           ${NODE_IMAGE_TAG}"
echo -e "  OpenClaw:          ${OPENCLAW_VERSION}"
echo -e "  CC-Switch:         ${CC_SWITCH_VERSION}"
echo -e "  Claude Code:       ${CLAUDE_CODE_VERSION}"
echo ""
echo -e "${CYAN}下一步：${NC}"
echo -e "  ${GREEN}./deploy.sh${NC}  一键部署"
echo ""
echo -e "${YELLOW}提示：${NC}如需修改配置，编辑 .env 文件后重新运行 deploy.sh"
echo ""
