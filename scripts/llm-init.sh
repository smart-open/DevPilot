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
# 平台配置已迁移到 cicd/lib/common.sh:configure_platform() / validate_config()
# 本脚本只做"驱动"：source common.sh → 调用 → 写 export 文件给其他进程
# 取用。即"thin wrapper"角色，原 case/esac 重复实现已统一。
# ============================================================

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
    if [ -n "${LLM_CODE_MODEL:-}" ]; then
        echo -e "  ${CYAN}代码模型：${NC}${LLM_CODE_MODEL}"
    fi
    if [ -n "${LLM_CODE_PLAN_MODEL:-}" ]; then
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
