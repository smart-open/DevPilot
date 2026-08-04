#!/bin/bash
set -e

# ============================================================
# DevPilot 多平台模型统一初始化脚本
# 根据 LLM_PLATFORM 配置选择对应平台的环境变量
# 所有平台均走 OpenAI Chat Completion 协议
# 支持：agnes、deepseek、glm、ark、bailian
# 用法：./scripts/llm-init.sh [platform]
# ============================================================

# ---- 加载公共函数库 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/../cicd/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/../cicd/lib/common.sh"
fi

# ---- 定位项目根目录 ----
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

# ---- 加载 .env ----
if [ -f ".env" ]; then
    set -a
    source ".env"
    set +a
else
    error ".env 文件不存在，请先运行 ./init.sh"
    exit 1
fi

# ---- 加载版本配置 ----
if [ -f "versions.env" ]; then
    source "versions.env"
fi

# ============================================================
# 平台配置映射（统一输出 LLM_API_KEY / LLM_BASE_URL / LLM_MODEL）
# ============================================================
configure_platform() {
    local platform="$1"
    info "初始化 ${platform} 平台配置..."

    case "${platform}" in
        agnes)
            if [ -z "${AGNES_API_KEY}" ] || [ "${AGNES_API_KEY}" = "your-agnes-api-key" ]; then
                error "请设置 AGNES_API_KEY"
                return 1
            fi

            export LLM_API_KEY="${AGNES_API_KEY}"
            export LLM_BASE_URL="${AGNES_BASE_URL:-https://api.agnes-ai.cn/v1}"
            export LLM_MODEL="${AGNES_MODEL:-agnes-2.5-flash}"
            export LLM_PLATFORM_NAME="Agnes AI"
            ;;

        deepseek)
            if [ -z "${DEEPSEEK_API_KEY}" ] || [ "${DEEPSEEK_API_KEY}" = "your-deepseek-api-key" ]; then
                error "请设置 DEEPSEEK_API_KEY"
                return 1
            fi

            export LLM_API_KEY="${DEEPSEEK_API_KEY}"
            export LLM_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/v1}"
            export LLM_MODEL="${DEEPSEEK_MODEL:-DeepSeek-V4-Flash}"
            export LLM_CODE_MODEL="${DEEPSEEK_CODE_MODEL:-DeepSeek-V4-Flash}"
            export LLM_PLATFORM_NAME="DeepSeek"
            ;;

        glm)
            if [ -z "${GLM_API_KEY}" ] || [ "${GLM_API_KEY}" = "your-glm-api-key" ]; then
                error "请设置 GLM_API_KEY"
                return 1
            fi

            export LLM_API_KEY="${GLM_API_KEY}"
            export LLM_BASE_URL="${GLM_BASE_URL:-https://open.bigmodel.cn/api/paas/v4}"
            export LLM_MODEL="${GLM_MODEL:-GLM-5.2}"
            export LLM_PLATFORM_NAME="GLM（智谱）"
            ;;

        ark)
            if [ -z "${ARK_API_KEY}" ] || [ "${ARK_API_KEY}" = "your-ark-api-key" ]; then
                error "请设置 ARK_API_KEY"
                return 1
            fi

            export LLM_API_KEY="${ARK_API_KEY}"
            export LLM_BASE_URL="${ARK_BASE_URL:-https://ark.cn-beijing.volces.com/api/v3}"
            export LLM_MODEL="${ARK_MODEL:-doubao-seed-2.1-turbo}"
            export LLM_CODE_PLAN_MODEL="${ARK_CODE_PLAN_MODEL:-doubao-seed-2.1-turbo}"
            export LLM_PLATFORM_NAME="火山方舟（ARK）"
            ;;

        bailian)
            if [ -z "${BAILIAN_API_KEY}" ] || [ "${BAILIAN_API_KEY}" = "your-bailian-api-key" ]; then
                error "请设置 BAILIAN_API_KEY"
                return 1
            fi

            export LLM_API_KEY="${BAILIAN_API_KEY}"
            export LLM_BASE_URL="${BAILIAN_BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
            export LLM_MODEL="${BAILIAN_MODEL:-Qwen3.7-Plus}"
            export LLM_PLATFORM_NAME="百炼（DashScope）"
            ;;

        *)
            error "未知平台: ${platform}（支持: agnes | deepseek | glm | ark | bailian）"
            return 1
            ;;
    esac

    # 统一设置 ANTHROPIC 兼容变量（供 Claude Code fallback 使用）
    export ANTHROPIC_BASE_URL="${LLM_BASE_URL}"
    export ANTHROPIC_API_KEY="${LLM_API_KEY}"
    export ANTHROPIC_MODEL="${LLM_MODEL}"

    success "配置成功：${LLM_PLATFORM_NAME}"
    return 0
}

# ============================================================
# 配置验证
# ============================================================
validate_config() {
    local platform="$1"
    info "验证 ${platform} 平台配置..."

    case "${platform}" in
        agnes)
            [ -n "${AGNES_API_KEY}" ] && [ "${AGNES_API_KEY}" != "your-agnes-api-key" ]
            ;;
        deepseek)
            [ -n "${DEEPSEEK_API_KEY}" ] && [ "${DEEPSEEK_API_KEY}" != "your-deepseek-api-key" ]
            ;;
        glm)
            [ -n "${GLM_API_KEY}" ] && [ "${GLM_API_KEY}" != "your-glm-api-key" ]
            ;;
        ark)
            [ -n "${ARK_API_KEY}" ] && [ "${ARK_API_KEY}" != "your-ark-api-key" ]
            ;;
        bailian)
            [ -n "${BAILIAN_API_KEY}" ] && [ "${BAILIAN_API_KEY}" != "your-bailian-api-key" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# 显示配置摘要
# ============================================================
print_summary() {
    echo ""
    print_separator
    success "当前大模型平台配置"
    print_separator
    echo ""
    echo -e "  ${CYAN}平台名称：${NC}${LLM_PLATFORM_NAME}"
    echo -e "  ${CYAN}平台标识：${NC}${LLM_PLATFORM}"
    echo -e "  ${CYAN}API 地址：${NC}${LLM_BASE_URL}"
    echo -e "  ${CYAN}模型：${NC}${LLM_MODEL}"
    if [ -n "${LLM_CODE_MODEL}" ]; then
        echo -e "  ${CYAN}代码模型：${NC}${LLM_CODE_MODEL}"
    fi
    if [ -n "${LLM_CODE_PLAN_MODEL}" ]; then
        echo -e "  ${CYAN}代码规划模型：${NC}${LLM_CODE_PLAN_MODEL}"
    fi
    echo -e "  ${CYAN}API Key：${NC}$(echo "${LLM_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"
    echo -e "  ${CYAN}协议：${NC}OpenAI Chat Completion"
    echo ""
}

# ============================================================
# 主入口
# ============================================================
main() {
    # 确定平台
    LLM_PLATFORM="${LLM_PLATFORM:-agnes}"

    # 如果传入参数，优先使用
    if [ "$1" != "" ]; then
        LLM_PLATFORM="$1"
    fi

    info "使用平台: ${LLM_PLATFORM}"

    # 验证配置
    if ! validate_config "${LLM_PLATFORM}"; then
        error "配置验证失败，请检查 .env 文件中的 ${LLM_PLATFORM} 相关配置"
        exit 1
    fi

    # 配置平台
    if ! configure_platform "${LLM_PLATFORM}"; then
        error "平台配置失败"
        exit 1
    fi

    # 显示配置摘要
    print_summary

    # 导出变量到环境文件（用于其他脚本读取）
    if [ -d "data" ]; then
        cat > "data/llm-config.sh" << EOF
#!/bin/bash
# DevPilot 大模型平台配置
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
# LLM_PLATFORM：${LLM_PLATFORM}
# 协议：OpenAI Chat Completion
export LLM_PLATFORM="${LLM_PLATFORM}"
export LLM_PLATFORM_NAME="${LLM_PLATFORM_NAME}"
export LLM_API_KEY="${LLM_API_KEY}"
export LLM_BASE_URL="${LLM_BASE_URL}"
export LLM_MODEL="${LLM_MODEL}"
export LLM_CODE_MODEL="${LLM_CODE_MODEL:-}"
export LLM_CODE_PLAN_MODEL="${LLM_CODE_PLAN_MODEL:-}"
export ANTHROPIC_BASE_URL="${LLM_BASE_URL}"
export ANTHROPIC_API_KEY="${LLM_API_KEY}"
export ANTHROPIC_MODEL="${LLM_MODEL}"
EOF
        chmod +x "data/llm-config.sh"
        info "配置已保存到 data/llm-config.sh"
    fi

    success "初始化完成！"
}

main "$@"
