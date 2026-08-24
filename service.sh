#!/bin/bash
set -e

# ============================================================
# DevPilot 一键启停脚本（带详细调试日志 + 模型切换验证）
# 基于运维操作手册编写，覆盖日常启停、状态查看、健康检查
#
# 用法:
#   ./service.sh start  [full|bot|dev]  # 启动服务（默认 full）
#   ./service.sh stop                   # 停止所有服务
#   ./service.sh restart [full|bot|dev] # 重启服务
#   ./service.sh status                 # 查看容器状态
#   ./service.sh health                 # 健康检查
#   ./service.sh model                  # 查看当前大模型平台配置
#   ./service.sh logs [service]         # 查看日志（service: redis/openclaw/devpilot-claude）
#   ./service.sh help                   # 显示帮助
#
# 调试模式：
#   DEBUG=1 ./service.sh start          # 启用详细调试日志
#
# 依赖：cicd/lib/common.sh、.env
# ============================================================

# ---- 基础配置 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cicd/lib/common.sh"
cd "${SCRIPT_DIR}"

# ---- 日志配置 ----
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/service-$(date +%Y%m%d-%H%M%S).log"
DEBUG=${DEBUG:-0}

# ---- 增强日志函数（带时间戳 + 双输出）----
_log() {
    local level="$1"
    shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    case "${level}" in
        INFO)   color="${BLUE}" ;;
        OK)     color="${GREEN}" ;;
        WARN)   color="${YELLOW}" ;;
        ERROR)  color="${RED}" ;;
        DEBUG)  color="${MAGENTA}" ;;
    esac
    # 控制台输出
    echo -e "${color}[${ts}] [${level}]${NC} ${msg}"
    # 日志文件输出（无颜色）
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
}

info()    { _log "INFO" "$*"; }
success() { _log "OK" "$*"; }
warn()    { _log "WARN" "$*"; }
error()   { _log "ERROR" "$*" >&2; }

debug() {
    if [ "${DEBUG}" -eq 1 ]; then
        _log "DEBUG" "$*"
    fi
}

# ---- 初始化日志 ----
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  DevPilot 服务管理脚本${NC}"
echo -e "${CYAN}  日志文件: ${LOG_FILE}${NC}"
if [ "${DEBUG}" -eq 1 ]; then
    echo -e "${MAGENTA}  调试模式已启用${NC}"
fi
echo -e "${CYAN}========================================${NC}"
echo ""
{
    echo "========================================"
    echo "  DevPilot 服务管理脚本"
    echo "  启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  执行命令: $0 $*"
    echo "========================================"
} >> "${LOG_FILE}"

# ---- 检查 .env ----
debug "检查 .env 文件是否存在"
if [ ! -f ".env" ]; then
    error ".env 文件不存在，请先运行: ./init.sh"
    exit 1
fi
success ".env 文件存在"

# ---- 读取基础配置 ----
debug "读取配置文件"
GATEWAY_PORT=$(grep "^OPENCLAW_GATEWAY_PORT=" .env | cut -d'=' -f2)
REDIS_PASS=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)

if [ -z "${GATEWAY_PORT}" ]; then GATEWAY_PORT=18789; fi
# CC-Switch Web 已移除（2026-08），不再需要 WEB_PORT 变量

debug "配置读取结果"
debug "  GATEWAY_PORT: ${GATEWAY_PORT}"
debug "  REDIS_PASS: $(if [ -n "${REDIS_PASS}" ]; then echo '已设置'; else echo '未设置'; fi)"

# ============================================================
# 读取大模型平台配置
# ============================================================
read_llm_config() {
    debug "读取大模型平台配置..."

    LLM_PLATFORM=$(grep "^LLM_PLATFORM=" .env | cut -d'=' -f2)
    if [ -z "${LLM_PLATFORM}" ]; then
        LLM_PLATFORM="agnes"
        debug "  LLM_PLATFORM 未设置，默认为 agnes"
    fi

    # 根据平台读取对应配置
    case "${LLM_PLATFORM}" in
        agnes)
            LLM_API_KEY=$(grep "^AGNES_API_KEY=" .env | cut -d'=' -f2)
            LLM_BASE_URL=$(grep "^AGNES_BASE_URL=" .env | cut -d'=' -f2)
            LLM_MODEL=$(grep "^AGNES_MODEL=" .env | cut -d'=' -f2)
            LLM_PLATFORM_NAME="Agnes AI"
            ;;
        deepseek)
            LLM_API_KEY=$(grep "^DEEPSEEK_API_KEY=" .env | cut -d'=' -f2)
            LLM_BASE_URL=$(grep "^DEEPSEEK_BASE_URL=" .env | cut -d'=' -f2)
            LLM_MODEL=$(grep "^DEEPSEEK_MODEL=" .env | cut -d'=' -f2)
            LLM_PLATFORM_NAME="DeepSeek"
            ;;
        glm)
            LLM_API_KEY=$(grep "^GLM_API_KEY=" .env | cut -d'=' -f2)
            LLM_BASE_URL=$(grep "^GLM_BASE_URL=" .env | cut -d'=' -f2)
            LLM_MODEL=$(grep "^GLM_MODEL=" .env | cut -d'=' -f2)
            LLM_PLATFORM_NAME="GLM（智谱）"
            ;;
        ark)
            LLM_API_KEY=$(grep "^ARK_API_KEY=" .env | cut -d'=' -f2)
            LLM_BASE_URL=$(grep "^ARK_BASE_URL=" .env | cut -d'=' -f2)
            LLM_MODEL=$(grep "^ARK_MODEL=" .env | cut -d'=' -f2)
            LLM_PLATFORM_NAME="火山方舟（ARK）"
            ;;
        bailian)
            LLM_API_KEY=$(grep "^BAILIAN_API_KEY=" .env | cut -d'=' -f2)
            LLM_BASE_URL=$(grep "^BAILIAN_BASE_URL=" .env | cut -d'=' -f2)
            LLM_MODEL=$(grep "^BAILIAN_MODEL=" .env | cut -d'=' -f2)
            LLM_PLATFORM_NAME="百炼（DashScope）"
            ;;
        *)
            LLM_PLATFORM_NAME="未知(${LLM_PLATFORM})"
            LLM_API_KEY=""
            LLM_BASE_URL=""
            LLM_MODEL=""
            ;;
    esac

    debug "  LLM_PLATFORM: ${LLM_PLATFORM}"
    debug "  LLM_PLATFORM_NAME: ${LLM_PLATFORM_NAME}"
    debug "  LLM_BASE_URL: ${LLM_BASE_URL}"
    debug "  LLM_MODEL: ${LLM_MODEL}"
    debug "  LLM_API_KEY: $(if [ -n "${LLM_API_KEY}" ]; then echo "$(echo "${LLM_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"; else echo '未设置'; fi)"
}

# ---- 读取模型配置 ----
read_llm_config

# ============================================================
# 打印当前模型配置
# ============================================================
print_model_config() {
    local model_key_display
    if [ -n "${LLM_API_KEY}" ] && [ "${LLM_API_KEY}" != "your-"* ]; then
        model_key_display=$(echo "${LLM_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')
    else
        model_key_display="未设置或为占位符"
    fi

    local config_block
    config_block="========== 当前大模型平台配置 ==========
  平台标识：${LLM_PLATFORM}
  平台名称：${LLM_PLATFORM_NAME}
  API 地址：${LLM_BASE_URL:-未配置}
  模型名称：${LLM_MODEL:-未配置}
  API Key：${model_key_display}
  协议：OpenAI Chat Completion"

    echo ""
    echo -e "${CYAN}${config_block}${NC}"
    echo ""
    # 同时写入日志文件
    echo "${config_block}" >> "${LOG_FILE}"
}

# ============================================================
# 验证容器内模型配置是否生效
# ============================================================
verify_container_model() {
    info "验证容器内大模型配置..."

    local container_name="devpilot-openclaw"
    local found_errors=0

    # 收集所有失败的检查项（用于最终汇总）
    local error_details=""

    # ============================================================
    # 检查 1/5: OpenClaw 容器的 LLM_PLATFORM
    # ============================================================
    local container_platform
    container_platform=$(docker exec "${container_name}" printenv LLM_PLATFORM 2>/dev/null || echo "")
    if [ -z "${container_platform}" ]; then
        error "${container_name} 验证失败：无法读取 LLM_PLATFORM 环境变量"
        error "  -> 容器可能未启动或未传入 LLM_PLATFORM 环境变量"
        error "  -> 修复：检查 docker-compose.yml 中 openclaw 服务是否包含 LLM_PLATFORM=\${LLM_PLATFORM}"
        error_details="${error_details}\n  [FAIL] ${container_name} | LLM_PLATFORM | 无法读取环境变量"
        found_errors=1
    elif [ "${container_platform}" != "${LLM_PLATFORM}" ]; then
        error "${container_name} 验证失败：LLM_PLATFORM 不一致"
        error "  -> 容器内值: ${container_platform}"
        error "  -> .env 配置: ${LLM_PLATFORM}"
        error "  -> 修复：运行 ./service.sh restart 重建容器"
        error_details="${error_details}\n  [FAIL] ${container_name} | LLM_PLATFORM | 容器=${container_platform} vs 配置=${LLM_PLATFORM}"
        found_errors=1
    else
        success "[1/5] ${container_name} LLM_PLATFORM=${container_platform} 与配置一致"
    fi

    # ============================================================
    # 检查 2-5: devpilot-claude 容器（含 Claude Code + LiteLLM 路由）
    # ============================================================
    local cc_container="devpilot-claude"
    if docker inspect "${cc_container}" &>/dev/null; then

        # ---- 检查 2/5: devpilot-claude LLM_PLATFORM（来自 .env） ----
        local cc_platform
        cc_platform=$(docker exec "${cc_container}" printenv LLM_PLATFORM 2>/dev/null || echo "")
        if [ "${cc_platform}" != "${LLM_PLATFORM}" ]; then
            error "${cc_container} 验证失败：LLM_PLATFORM 不一致"
            error "  -> 容器内值: ${cc_platform:-（空）}"
            error "  -> .env 配置: ${LLM_PLATFORM}"
            error "  -> 修复：运行 ./service.sh restart 重建容器"
            error_details="${error_details}\n  [FAIL] ${cc_container} | LLM_PLATFORM | 容器=${cc_platform:-（空）} vs 配置=${LLM_PLATFORM}"
            found_errors=1
        else
            success "[2/5] ${cc_container} LLM_PLATFORM=${cc_platform} 与配置一致"
        fi

        # ---- 检查 3/5: devpilot-claude ANTHROPIC_MODEL 与 settings.json 一致性 ----
                local active_provider
        active_provider=$(docker exec "${cc_container}" cat "${cc_config}" 2>/dev/null | grep activeProvider | sed 's/.*: "\(.*\)".*/\1/' 2>/dev/null || echo "")
        if [ -n "${active_provider}" ]; then
            # 映射平台标识到供应商名称
            local expected_provider="${LLM_PLATFORM}"
            case "${LLM_PLATFORM}" in
                agnes) expected_provider="agnes-ai" ;;
            esac
            if [ "${active_provider}" != "${expected_provider}" ]; then
                error "${cc_container} 验证失败：activeProvider 不一致"
                error "  -> 配置文件: ${cc_config}"
                error "  -> 当前值:   ${active_provider}"
                error "  -> 期望值:   ${expected_provider}"
                error "  -> 修复：删除 data/devpilot-claude/.claude/settings.json 重启
"                error_details="${error_details}\n  [FAIL] ${cc_container} | activeProvider | 当前=${active_provider} vs 期望=${expected_provider}"
                found_errors=1
            else
                success "[3/5] ${cc_container} activeProvider=${active_provider} 与期望一致"
            fi
        else
            warn "[3/5] ${cc_container} 配置文件不存在或无法读取，跳过 activeProvider 检查"
            error_details="${error_details}\n  [SKIP] ${cc_container} | activeProvider | 配置文件不存在"
        fi

        # ---- 检查 4/5: devpilot-claude ANTHROPIC_BASE_URL = http://litellm:4000 ----
        local anthropic_url
        anthropic_url=$(docker exec "${cc_container}" printenv ANTHROPIC_BASE_URL 2>/dev/null || echo "")
        if [ -n "${anthropic_url}" ]; then
            if [ "${anthropic_url}" != "${LLM_BASE_URL}" ]; then
                error "${cc_container} 验证失败：ANTHROPIC_BASE_URL 不一致"
                error "  -> 容器内值: ${anthropic_url}"
                error "  -> .env 配置: ${LLM_BASE_URL}"
                error "  -> 修复：运行 ./service.sh restart 重建容器（start.sh 会根据 LLM_PLATFORM 动态设置）"
                error_details="${error_details}\n  [FAIL] ${cc_container} | ANTHROPIC_BASE_URL | 容器=${anthropic_url} vs 配置=${LLM_BASE_URL}"
                found_errors=1
            else
                success "[4/5] ${cc_container} ANTHROPIC_BASE_URL 与配置一致"
            fi
        else
            warn "[4/5] ${cc_container} ANTHROPIC_BASE_URL 未设置（可能容器尚未完全启动）"
            error_details="${error_details}\n  [SKIP] ${cc_container} | ANTHROPIC_BASE_URL | 未设置"
        fi

        # ---- 检查 5/5: devpilot-claude ANTHROPIC_MODEL = <platform>/<model> 格式 ----
        local anthropic_model
        anthropic_model=$(docker exec "${cc_container}" printenv ANTHROPIC_MODEL 2>/dev/null || echo "")
        if [ -n "${anthropic_model}" ]; then
            if [ "${anthropic_model}" != "${LLM_MODEL}" ]; then
                error "${cc_container} 验证失败：ANTHROPIC_MODEL 不一致"
                error "  -> 容器内值: ${anthropic_model}"
                error "  -> .env 配置: ${LLM_MODEL}"
                error "  -> 修复：运行 ./service.sh restart 重建容器"
                error_details="${error_details}\n  [FAIL] ${cc_container} | ANTHROPIC_MODEL | 容器=${anthropic_model} vs 配置=${LLM_MODEL}"
                found_errors=1
            else
                success "[5/5] ${cc_container} ANTHROPIC_MODEL 与配置一致"
            fi
        else
            warn "[5/5] ${cc_container} ANTHROPIC_MODEL 未设置（可能容器尚未完全启动）"
            error_details="${error_details}\n  [SKIP] ${cc_container} | ANTHROPIC_MODEL | 未设置"
        fi
    else
        warn "${cc_container} 不存在，跳过检查 2-5"
        error_details="${error_details}\n  [SKIP] ${cc_container} | 容器不存在"
    fi

    # ============================================================
    # 附加检查：API Key 是否为占位符
    # ============================================================
    if echo "${LLM_API_KEY}" | grep -q "^your-"; then
        error "API Key 验证失败：仍为占位符"
        error "  -> 当前值: ${LLM_API_KEY}"
        error "  -> 修复：编辑 .env 设置真实的 ${LLM_PLATFORM} 平台 API Key"
        error_details="${error_details}\n  [FAIL] .env | API Key | 仍为占位符(${LLM_API_KEY})"
        found_errors=1
    fi

    # ============================================================
    # 最终汇总
    # ============================================================
    echo ""
    if [ ${found_errors} -eq 0 ]; then
        success "大模型配置验证通过，所有容器配置一致"
        success "模型切换成功：${LLM_PLATFORM_NAME} | ${LLM_MODEL} | ${LLM_BASE_URL}"
        {
            echo ""
            echo "--- 模型配置验证 ---"
            echo "结果: 通过"
            echo "状态: 模型切换成功"
            echo "平台: ${LLM_PLATFORM} (${LLM_PLATFORM_NAME})"
            echo "模型: ${LLM_MODEL}"
            echo "API 地址: ${LLM_BASE_URL}"
            echo "检查项:"
            echo "  [1/5] ${container_name} LLM_PLATFORM: 一致"
            echo "  [2/5] devpilot-claude LLM_PLATFORM: 一致"
            echo "  [3/5] devpilot-claude activeProvider: 一致"
            echo "  [4/5] devpilot-claude ANTHROPIC_BASE_URL: 一致"
            echo "  [5/5] devpilot-claude ANTHROPIC_MODEL: 一致"
            echo "  API Key: 已设置且非占位符"
        } >> "${LOG_FILE}"
    else
        error "模型切换失败！以下检查项未通过："
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}  模型切换失败 - 详细错误汇总${NC}"
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}  目标平台: ${LLM_PLATFORM} (${LLM_PLATFORM_NAME})${NC}"
        echo -e "${RED}  目标模型: ${LLM_MODEL}${NC}"
        echo -e "${RED}  目标 API: ${LLM_BASE_URL}${NC}"
        echo -e "${RED}----------------------------------------${NC}"
        echo -e "${RED}${error_details}${NC}"
        echo -e "${RED}========================================${NC}"
        echo ""
        warn "修复建议："
        echo -e "  1. 容器环境变量不一致 -> 运行 ${GREEN}./service.sh restart${NC} 重建容器"
        echo -e "  2. 配置不一致 -> 删除 ${GREEN}data/devpilot-claude/.claude/settings.json${NC} 后重启
"        echo -e "  3. API Key 为占位符 -> 编辑 ${GREEN}.env${NC} 设置真实 API Key"
        echo ""
        {
            echo ""
            echo "--- 模型配置验证 ---"
            echo "结果: 失败"
            echo "状态: 模型切换失败"
            echo "目标平台: ${LLM_PLATFORM} (${LLM_PLATFORM_NAME})"
            echo "目标模型: ${LLM_MODEL}"
            echo "目标 API: ${LLM_BASE_URL}"
            echo "失败检查项:"
            echo -e "${error_details}"
            echo ""
            echo "修复建议:"
            echo "  1. 容器环境变量不一致 -> 运行 ./service.sh restart 重建容器"
            echo "  2. 配置不一致 -> 删除 data/devpilot-claude/.claude/settings.json 后重启
"            echo "  3. API Key 为占位符 -> 编辑 .env 设置真实 API Key"
        } >> "${LOG_FILE}"
    fi
}

# ============================================================
# 函数定义
# ============================================================

# 解析 profile 参数
parse_profile() {
    local profile="${1:-full}"
    debug "解析 profile 参数: ${profile}"
    case "${profile}" in
        full) echo "" ;;
        bot)  echo "bot" ;;
        dev)  echo "dev" ;;
        *)    error "未知 profile: ${profile}（可选: full|bot|dev）"; exit 1 ;;
    esac
}

# 构建 docker compose 命令前缀
compose_cmd() {
    local profile_flag="$1"
    if [ -z "${profile_flag}" ]; then
        echo "docker compose --env-file .env"
    else
        echo "docker compose --env-file .env --profile ${profile_flag}"
    fi
}

# 启动服务
do_start() {
    local profile_name="${1:-full}"
    local profile_flag
    profile_flag=$(parse_profile "${profile_name}")

    print_header "启动 DevPilot 服务（模式: ${profile_name}）"
    debug "启动模式: ${profile_name}，profile_flag: '${profile_flag}'"

    # 打印当前模型配置（启动前确认）
    print_model_config

    info "检查 Docker 守护进程..."
    if ! docker info &>/dev/null; then
        error "Docker 守护进程未运行"
        debug "Docker 检查失败"
        exit 1
    fi
    success "Docker 运行中"
    debug "Docker 版本: $(docker --version)"
    debug "Docker Compose 版本: $(docker compose version --short)"

    info "检查端口占用..."
    for port in "${GATEWAY_PORT}"; do
        if command -v ss &>/dev/null; then
            if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                warn "端口 ${port} 已被占用（可能是已有服务运行）"
                debug "端口 ${port} 占用检测: 已占用"
            else
                debug "端口 ${port} 占用检测: 可用"
            fi
        else
            debug "ss 命令不可用，跳过端口占用检查"
        fi
    done

    local cmd
    cmd=$(compose_cmd "${profile_flag}")
    debug "构建的 compose 命令: ${cmd}"

    if [ -z "${profile_flag}" ]; then
        info "启动全部服务（Redis + OpenClaw + devpilot-claude + devpilot-litellm）..."
        debug "准备启动 3 个容器"
    else
        info "启动 profile=${profile_flag} 的服务..."
        debug "准备启动指定 profile 的容器"
    fi

    debug "执行命令: ${cmd} up -d --build"
    echo ""
    {
        echo ""
        echo "--- Compose up 输出 ---"
        echo "平台: ${LLM_PLATFORM} (${LLM_PLATFORM_NAME})"
        echo "模型: ${LLM_MODEL}"
        echo "API 地址: ${LLM_BASE_URL}"
    } >> "${LOG_FILE}"

    ${cmd} up -d --build 2>&1 | while IFS= read -r line; do
        echo "  ${line}"
        echo "${line}" >> "${LOG_FILE}"
    done

    local exit_code=${PIPESTATUS[0]}
    if [ ${exit_code} -ne 0 ]; then
        error "Compose up 执行失败，退出码: ${exit_code}"
        exit ${exit_code}
    fi

    echo ""
    success "服务已启动"
    debug "Compose up 执行成功"

    # 检查容器状态
    debug "检查容器初始状态"
    ${cmd} ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>&1 | while IFS= read -r line; do
        echo "  ${line}"
        echo "${line}" >> "${LOG_FILE}"
    done

    # 等待健康检查
    info "等待服务就绪..."
    echo ""
    {
        echo ""
        echo "--- 健康检查阶段 ---"
    } >> "${LOG_FILE}"

    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "bot" ]; then
        debug "检查 Redis 就绪（最多 30 次，间隔 2s）"
        wait_for_redis "devpilot-redis" "${REDIS_PASS}" 30 || warn "Redis 未就绪"
        debug "检查 OpenClaw 就绪（最多 20 次，间隔 3s）"
        wait_for_http "OpenClaw" "http://localhost:${GATEWAY_PORT}/healthz" 20 3 || warn "OpenClaw 未就绪"
    fi

    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "dev" ]; then
        debug "检查 devpilot-claude 容器 Claude Code 就绪（claude --version）"
        # Claude Code 是 CLI 而非 HTTP 服务，通过 docker exec 检测
        docker exec devpilot-claude claude --version >/dev/null 2>&1 || warn "Claude Code 未就绪"
    fi

    # 验证容器内模型配置是否生效
    echo ""
    info "验证模型配置是否生效..."
    verify_container_model

    echo ""
    print_separator
    success "DevPilot 服务已就绪"
    print_separator

    local summary_block
    summary_block=""
    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "bot" ]; then
        summary_block="${summary_block}  OpenClaw:  http://localhost:${GATEWAY_PORT}\n"
    fi
    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "dev" ]; then
    fi
    summary_block="${summary_block}  模型平台：${LLM_PLATFORM_NAME} (${LLM_MODEL})"

    echo -e "${CYAN}${summary_block}${NC}"
    echo ""

    # 总结日志（含模型切换确认）
    {
        echo ""
        echo "--- 启动总结 ---"
        echo "启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "启动模式: ${profile_name}"
        echo "大模型平台: ${LLM_PLATFORM} (${LLM_PLATFORM_NAME})"
        echo "模型: ${LLM_MODEL}"
        echo "API 地址: ${LLM_BASE_URL}"
        echo "服务地址:"
        if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "bot" ]; then
            echo "  OpenClaw: http://localhost:${GATEWAY_PORT}"
        fi
        if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "dev" ]; then
        fi
        echo "模型切换状态: 成功"
        echo "完成!"
    } >> "${LOG_FILE}"
}

# 停止服务
do_stop() {
    print_header "停止 DevPilot 服务"
    debug "准备停止所有容器"

    info "停止所有容器..."
    {
        echo ""
        echo "--- Compose down 输出 ---"
    } >> "${LOG_FILE}"

    docker compose --env-file .env down 2>&1 | while IFS= read -r line; do
        echo "  ${line}"
        echo "${line}" >> "${LOG_FILE}"
    done

    echo ""
    success "所有服务已停止（数据保留在 data/ 目录）"
    echo ""

    # 总结日志
    {
        echo ""
        echo "--- 停止总结 ---"
        echo "停止时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "完成!"
    } >> "${LOG_FILE}"
}

# 重启服务
do_restart() {
    local profile_name="${1:-full}"
    print_header "重启 DevPilot 服务（模式: ${profile_name}）"
    debug "准备重启服务"

    # 记录重启前的平台（用于切换对比）
    local old_platform="${LLM_PLATFORM}"
    local old_model="${LLM_MODEL}"

    # 重新读取配置（确认是否有变更）
    info "重新读取配置..."
    read_llm_config
    print_model_config

    # 检测平台是否发生变化
    if [ "${old_platform}" != "${LLM_PLATFORM}" ]; then
        info "检测到平台变更: ${old_platform} -> ${LLM_PLATFORM}"
        echo "[变更] 平台: ${old_platform} -> ${LLM_PLATFORM}" >> "${LOG_FILE}"
        if [ "${old_model}" != "${LLM_MODEL}" ]; then
            info "检测到模型变更: ${old_model} -> ${LLM_MODEL}"
            echo "[变更] 模型: ${old_model} -> ${LLM_MODEL}" >> "${LOG_FILE}"
        fi
    else
        info "平台未变更: ${LLM_PLATFORM}（将重建容器以确保配置同步）"
    fi

    info "停止当前服务..."
    do_stop

    echo ""
    success "已停止，正在重新启动..."

    do_start "${profile_name}"
}

# 查看状态
do_status() {
    print_header "DevPilot 容器状态"

    echo -e "${CYAN}容器列表:${NC}"
    {
        echo ""
        echo "--- 容器状态 ---"
    } >> "${LOG_FILE}"

    docker compose --env-file .env ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>&1 | while IFS= read -r line; do
        echo "${line}"
        echo "${line}" >> "${LOG_FILE}"
    done || warn "无法获取容器状态"

    echo ""
    echo -e "${CYAN}资源使用:${NC}"
    {
        echo ""
        echo "--- 资源使用 ---"
    } >> "${LOG_FILE}"

    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" \
        devpilot-redis devpilot-openclaw devpilot-claude 2>&1 | while IFS= read -r line; do
        echo "${line}"
        echo "${line}" >> "${LOG_FILE}"
    done || warn "无法获取资源使用"

    echo ""
    echo -e "${CYAN}端口监听:${NC}"
    for port_info in "OpenClaw:${GATEWAY_PORT}" "devpilot-litellm:容器内 4000"; do
        name="${port_info%%:*}"
        port="${port_info##*:}"
        if command -v ss &>/dev/null; then
            if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                success "${name} 端口 ${port} 正在监听"
                debug "${name} 端口 ${port} 监听: 正常"
            else
                error "${name} 端口 ${port} 未监听"
                debug "${name} 端口 ${port} 监听: 异常"
            fi
        fi
    done

    # 显示当前模型配置
    print_model_config

    echo ""
}

# 健康检查
do_health() {
    print_header "DevPilot 健康检查"
    {
        echo ""
        echo "--- 健康检查 ---"
    } >> "${LOG_FILE}"

    local all_ok=1

    echo -e "${CYAN}Redis:${NC}     "
    if docker exec devpilot-redis redis-cli -a "${REDIS_PASS}" ping 2>&1 | grep -q PONG; then
        success "PONG"
        echo "Redis: OK" >> "${LOG_FILE}"
    else
        error "FAIL"
        echo "Redis: FAIL" >> "${LOG_FILE}"
        all_ok=0
    fi

    echo -e "${CYAN}OpenClaw:${NC}  "
    if curl -sf "http://localhost:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then
        success "OK"
        echo "OpenClaw: OK" >> "${LOG_FILE}"
    else
        error "FAIL"
        echo "OpenClaw: FAIL" >> "${LOG_FILE}"
        all_ok=0
    fi

    echo -e "${CYAN}devpilot-litellm:${NC} "
    if curl -sf "http://localhost:${WEB_PORT}" >/dev/null 2>&1; then
        success "OK"
        echo "devpilot-litellm: OK" >> "${LOG_FILE}"
    else
        error "FAIL"
        echo "CC-Switch: FAIL" >> "${LOG_FILE}"
        all_ok=0
    fi

    echo -e "${CYAN}Claude Code:${NC} "
    if docker exec devpilot-claude claude --version 2>/dev/null; then
        success "OK"
        echo "Claude Code: OK" >> "${LOG_FILE}"
    else
        warn "未检测到（可能 dev profile 未启动）"
        echo "Claude Code: N/A" >> "${LOG_FILE}"
    fi

    # 模型配置验证
    echo ""
    echo -e "${CYAN}模型配置验证:${NC}"
    verify_container_model

    echo ""

    if [ ${all_ok} -eq 0 ]; then
        warn "部分服务健康检查失败，请查看日志: ${LOG_FILE}"
    fi
}

# 查看模型配置
do_model() {
    print_header "DevPilot 大模型平台配置"
    print_model_config

    # 如果容器在运行，验证配置一致性
    if docker inspect devpilot-openclaw &>/dev/null; then
        verify_container_model
    else
        warn "容器未运行，仅显示 .env 配置"
    fi
}

# 查看日志
do_logs() {
    local service="${1:-}"

    if [ -z "${service}" ]; then
        info "查看所有服务日志（Ctrl+C 退出）..."
        docker compose --env-file .env logs -f --tail 50
    else
        # 支持简写
        case "${service}" in
            redis)        service="redis" ;;
            openclaw|bot) service="openclaw" ;;
            claude|claude-code|devpilot-claude) service="devpilot-claude" ;;
        esac
        info "查看 ${service} 日志（Ctrl+C 退出）..."
        docker compose --env-file .env logs -f --tail 100 "${service}"
    fi
}

# 显示帮助
show_help() {
    echo ""
    print_separator
    echo -e "${MAGENTA}  DevPilot 服务管理脚本${NC}"
    print_separator
    echo ""
    echo -e "${CYAN}用法:${NC}"
    echo "  ./service.sh <命令> [参数]"
    echo ""
    echo -e "${CYAN}调试模式:${NC}"
    echo "  DEBUG=1 ./service.sh <命令>    # 启用详细调试日志"
    echo ""
    echo -e "${CYAN}日志文件:${NC}"
    echo "  所有执行会记录到: ${LOG_DIR}/service-YYYYMMDD-HHMMSS.log"
    echo ""
    echo -e "${CYAN}命令:${NC}"
    echo -e "  ${GREEN}start${NC}  [full|bot|dev]  启动服务（默认 full）"
    echo -e "  ${GREEN}stop${NC}                  停止所有服务（保留数据）"
    echo -e "  ${GREEN}restart${NC} [full|bot|dev] 重启服务（重新读取配置）"
    echo -e "  ${GREEN}status${NC}                查看容器状态和资源使用"
    echo -e "  ${GREEN}health${NC}                健康检查（Redis/OpenClaw/CC-Switch/Claude/模型配置）"
    echo -e "  ${GREEN}model${NC}                 查看当前大模型平台配置和验证结果"
    echo -e "  ${GREEN}logs${NC}   [service]      查看日志（redis/openclaw/devpilot-claude）"
    echo -e "  ${GREEN}help${NC}                  显示此帮助"
    echo ""
    echo -e "${CYAN}部署模式:${NC}"
    echo "  full  - Redis + OpenClaw + CC-Switch（完整功能）"
    echo "  bot   - Redis + OpenClaw（仅飞书机器人）"
    echo "  dev   - CC-Switch + Claude Code（仅开发环境）"
    echo ""
    echo -e "${CYAN}支持的大模型平台:${NC}"
    echo "  agnes   - Agnes AI (agnes-2.5-flash)"
    echo "  deepseek - DeepSeek (DeepSeek-V4-Flash)"
    echo "  glm     - GLM 智谱 (GLM-5.2)"
    echo "  ark     - 火山方舟 (doubao-seed-2.1-turbo)"
    echo "  bailian - 百炼 (Qwen3.7-Plus)"
    echo ""
    echo -e "${CYAN}示例:${NC}"
    echo "  ./service.sh start           # 启动全部服务"
    echo "  ./service.sh start bot       # 仅启动飞书机器人"
    echo "  DEBUG=1 ./service.sh start   # 启用调试日志启动"
    echo "  ./service.sh stop            # 停止所有服务"
    echo "  ./service.sh restart         # 重启全部服务（切换平台后使用）"
    echo "  ./service.sh status          # 查看状态"
    echo "  ./service.sh health          # 健康检查"
    echo "  ./service.sh model           # 查看模型配置"
    echo "  ./service.sh logs redis      # 查看 Redis 日志"
    echo ""
    echo -e "${YELLOW}切换平台:${NC}"
    echo "  1. 编辑 .env: 修改 LLM_PLATFORM 和对应平台的 API Key"
    echo "  2. 重启服务:  ./service.sh restart"
    echo "  3. 验证配置:  ./service.sh model"
    echo ""
}

# ============================================================
# 主入口
# ============================================================
COMMAND="${1:-help}"
shift 2>/dev/null || true

debug "接收到的命令: ${COMMAND}"
debug "剩余参数: $*"

case "${COMMAND}" in
    start)  do_start "$@" ;;
    stop)   do_stop ;;
    restart) do_restart "$@" ;;
    status) do_status ;;
    health) do_health ;;
    model)  do_model ;;
    logs)   do_logs "$@" ;;
    help|--help|-h) show_help ;;
    *)
        error "未知命令: ${COMMAND}"
        show_help
        exit 1
        ;;
esac
