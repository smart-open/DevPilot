#!/bin/bash
set -e

# ============================================================
# DevPilot 交互式配置向导
# 功能：引导用户填写配置、自动生成密码、生成 .env 文件
# 支持平台：Agnes AI、DeepSeek、GLM（智谱）、火山方舟、百炼
# 所有平台均走 OpenAI Chat Completion 协议
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
        printf -v "${var_name}" '%s' "${default}"
    else
        printf -v "${var_name}" '%s' "${input}"
    fi
}

# ---- 选择平台（带验证）----
select_platform() {
    echo -e "${CYAN}可用大模型平台（均支持 OpenAI Chat Completion 协议）：${NC}"
    echo -e "  ${GREEN}1) Agnes AI${NC}          模型: agnes-2.5-flash"
    echo -e "  ${GREEN}2) DeepSeek${NC}          模型: DeepSeek-V4-Flash"
    echo -e "  ${GREEN}3) GLM（智谱）${NC}       模型: GLM-5.2"
    echo -e "  ${GREEN}4) 火山方舟（ARK）${NC}   模型: doubao-seed-2.1-turbo"
    echo -e "  ${GREEN}5) 百炼（DashScope）${NC} 模型: Qwen3.7-Plus"
    echo ""

    local selected=""

    while true; do
        printf "${CYAN}[*] 请选择平台（输入数字或名称）${NC}: "
        read -r selected
        selected=$(echo "${selected}" | tr '[:upper:]' '[:lower:]')

        case "${selected}" in
            1|agnes)
                LLM_PLATFORM="agnes"
                break
                ;;
            2|deepseek)
                LLM_PLATFORM="deepseek"
                break
                ;;
            3|glm)
                LLM_PLATFORM="glm"
                break
                ;;
            4|ark|fangzhou|volcengine)
                LLM_PLATFORM="ark"
                break
                ;;
            5|bailian|dashscope)
                LLM_PLATFORM="bailian"
                break
                ;;
            *)
                warn "无效选项，请重新选择"
                ;;
        esac
    done

    success "已选择平台: ${LLM_PLATFORM}"
}

# ---- 平台配置 ----
configure_platform() {
    local platform="$1"
    echo ""
    echo -e "${BLUE}========== 配置 ${platform} 平台 ==========${NC}"
    echo ""

    case "${platform}" in
        agnes)
            printf "${CYAN}[*] Agnes AI API Key${NC}: "
            read -r AGNES_API_KEY
            if [ -z "${AGNES_API_KEY}" ]; then
                die "Agnes AI API Key 不能为空"
            fi

            AGNES_BASE_URL="https://api.agnes-ai.cn/v1"
            AGNES_MODEL="agnes-2.5-flash"

            success "Agnes AI 配置完成"
            ;;

        deepseek)
            printf "${CYAN}[*] DeepSeek API Key${NC}: "
            read -r DEEPSEEK_API_KEY
            if [ -z "${DEEPSEEK_API_KEY}" ]; then
                die "DeepSeek API Key 不能为空"
            fi

            DEEPSEEK_BASE_URL="https://api.deepseek.com/v1"
            DEEPSEEK_MODEL="DeepSeek-V4-Flash"
            DEEPSEEK_CODE_MODEL="DeepSeek-V4-Flash"

            success "DeepSeek 配置完成"
            ;;

        glm)
            printf "${CYAN}[*] GLM（智谱）API Key${NC}: "
            read -r GLM_API_KEY
            if [ -z "${GLM_API_KEY}" ]; then
                die "GLM API Key 不能为空"
            fi

            GLM_BASE_URL="https://open.bigmodel.cn/api/paas/v4"
            GLM_MODEL="GLM-5.2"

            success "GLM（智谱）配置完成"
            ;;

        ark)
            printf "${CYAN}[*] 火山方舟 API Key${NC}: "
            read -r ARK_API_KEY
            if [ -z "${ARK_API_KEY}" ]; then
                die "火山方舟 API Key 不能为空"
            fi

            ARK_BASE_URL="https://ark.cn-beijing.volces.com/api/v3"
            ARK_MODEL="doubao-seed-2.1-turbo"
            ARK_CODE_PLAN_MODEL="doubao-seed-2.1-turbo"

            success "火山方舟配置完成"
            ;;

        bailian)
            printf "${CYAN}[*] 百炼 API Key${NC}: "
            read -r BAILIAN_API_KEY
            if [ -z "${BAILIAN_API_KEY}" ]; then
                die "百炼 API Key 不能为空"
            fi

            BAILIAN_BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"
            BAILIAN_MODEL="Qwen3.7-Plus"

            success "百炼配置完成"
            ;;

        *)
            die "未知平台: ${platform}"
            ;;
    esac
}

# ---- 定位项目根目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---- 欢迎信息 ----
print_header "DevPilot 配置向导"
echo -e "  本向导将引导你完成 DevPilot 的配置，支持 ${GREEN}多平台大模型${NC}。"
echo -e "  支持平台：${CYAN}Agnes AI、DeepSeek、GLM、火山方舟、百炼${NC}"
echo -e "  所有平台均走 ${GREEN}OpenAI Chat Completion 协议${NC}"
echo -e "  带 [*] 的为必填项"
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
    cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
    success "已备份旧配置到 .env.bak.*"
fi

# ============================================================
# 2. 第 1 步：选择大模型平台
# ============================================================
echo -e "${BLUE}========== 第 1 步：选择大模型平台 ==========${NC}"
echo ""
select_platform

# ============================================================
# 3. 第 2 步：配置所选平台
# ============================================================
configure_platform "${LLM_PLATFORM}"

# ============================================================
# 4. 第 3 步：必填的飞书配置
# ============================================================
echo ""
echo -e "${BLUE}========== 第 3 步：飞书机器人配置 ==========${NC}"
echo ""
echo -e "  ${YELLOW}在飞书开放平台创建应用后获取以下信息${NC}"
echo -e "  应用类型：企业自建应用 | 事件订阅：长连接模式"
echo ""

printf "${CYAN}[*] 飞书 App ID${NC}: "
read -r FEISHU_APP_ID
if [ -z "${FEISHU_APP_ID}" ]; then
    die "飞书 App ID 不能为空"
fi
success "App ID 已设置"

printf "${CYAN}[*] 飞书 App Secret${NC}: "
read -r FEISHU_APP_SECRET
if [ -z "${FEISHU_APP_SECRET}" ]; then
    die "飞书 App Secret 不能为空"
fi
success "App Secret 已设置"

# ============================================================
# 5. 第 4 步：可选配置（带默认值，直接回车即可）
# ============================================================
echo ""
echo -e "${BLUE}========== 第 4 步：可选配置（直接回车使用默认值） ==========${NC}"
echo ""

read_input "OpenClaw Gateway 端口" "18789" "OPENCLAW_GATEWAY_PORT"
read_input "是否启用自动部署 (true/false)" "false" "DEVPILOT_AUTO_DEPLOY"

# ============================================================
# 6. 自动生成安全密码 & 加载版本（静默处理）
# ============================================================
info "自动生成安全密码..."
REDIS_PASSWORD=$(gen_password 32)
OPENCLAW_GATEWAY_TOKEN=$(gen_password 32)
LITELLM_MASTER_KEY=$(gen_password 32)
success "Redis 密码 / Gateway Token / LiteLLM Master Key 已生成"

# ============================================================
# 7. 生成 .env 文件
# ============================================================
echo ""
echo -e "${BLUE}========== 生成 .env 文件 ==========${NC}"
echo ""

cat > .env << EOF
# ============================================================
# DevPilot 环境变量配置
# 由 init.sh 向导生成 | $(date '+%Y-%m-%d %H:%M:%S')
# 选择平台：${LLM_PLATFORM}
# 所有平台均走 OpenAI Chat Completion 协议
# ============================================================

# ---- 大模型平台选择 ----
LLM_PLATFORM=${LLM_PLATFORM}

# ---- Agnes AI 平台 ----
AGNES_API_KEY=${AGNES_API_KEY}
AGNES_BASE_URL=${AGNES_BASE_URL}
AGNES_MODEL=${AGNES_MODEL}

# ---- DeepSeek 平台 ----
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
DEEPSEEK_BASE_URL=${DEEPSEEK_BASE_URL}
DEEPSEEK_MODEL=${DEEPSEEK_MODEL}
DEEPSEEK_CODE_MODEL=${DEEPSEEK_CODE_MODEL}

# ---- GLM（智谱）平台 ----
GLM_API_KEY=${GLM_API_KEY}
GLM_BASE_URL=${GLM_BASE_URL}
GLM_MODEL=${GLM_MODEL}

# ---- 火山方舟（ARK）平台 ----
ARK_API_KEY=${ARK_API_KEY}
ARK_BASE_URL=${ARK_BASE_URL}
ARK_MODEL=${ARK_MODEL}
ARK_CODE_PLAN_MODEL=${ARK_CODE_PLAN_MODEL}

# ---- 百炼平台 ----
BAILIAN_API_KEY=${BAILIAN_API_KEY}
BAILIAN_BASE_URL=${BAILIAN_BASE_URL}
BAILIAN_MODEL=${BAILIAN_MODEL}

# ---- 飞书配置 ----
FEISHU_APP_ID=${FEISHU_APP_ID}
FEISHU_APP_SECRET=${FEISHU_APP_SECRET}

# ---- Redis 配置 ----
REDIS_PASSWORD=${REDIS_PASSWORD}

# ---- OpenClaw 配置 ----
OPENCLAW_VERSION=${OPENCLAW_VERSION}
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}

# ---- 注：CC-Switch Web v0.21.0 已移除，主路由由 devpilot-claude-litellm 承担 ----

# ---- LiteLLM 代理配置（Claude Code 经此路由访问各平台 OpenAI 兼容端点）----
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
LITELLM_PROXY_URL=http://127.0.0.1:4000

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
# 8. 配置摘要 & 下一步指引
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${CYAN}配置摘要：${NC}"
echo -e "  大模型平台:     ${GREEN}${LLM_PLATFORM}${NC}"
# 平台摘要统一从 common.sh:configure_platform() 导出的 LLM_* 变量读。
configure_platform "${LLM_PLATFORM}"
echo -e "  API Key:        $(echo "${LLM_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"
echo -e "  API 地址:       ${LLM_BASE_URL}"
echo -e "  模型:           ${LLM_MODEL}"
echo -e "  飞书 App ID:   ${FEISHU_APP_ID}"
echo -e "  Redis 密码:    $(echo "${REDIS_PASSWORD}" | sed 's/./*/g')"
echo -e "  Gateway Token: $(echo "${OPENCLAW_GATEWAY_TOKEN}" | sed 's/./*/g')"
echo -e "  LiteLLM Key:   $(echo "${LITELLM_MASTER_KEY}" | sed 's/./*/g')"
echo -e "  Gateway 端口:  ${OPENCLAW_GATEWAY_PORT}"
echo -e "  自动部署:      ${DEVPILOT_AUTO_DEPLOY}"
echo ""
echo -e "${CYAN}组件版本（来自 versions.env）：${NC}"
echo -e "  Node.js:       ${NODE_IMAGE_TAG}"
echo -e "  OpenClaw:      ${OPENCLAW_VERSION}"
echo -e "  Claude Code:   ${CLAUDE_CODE_VERSION}"
echo ""
echo -e "${CYAN}下一步：${NC}"
echo -e "  ${GREEN}./deploy.sh${NC}  一键部署"
echo ""
echo -e "${YELLOW}提示：${NC}如需切换平台或修改配置，编辑 .env 文件后重新运行 deploy.sh"
echo ""
