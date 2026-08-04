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
#   ./service.sh logs [service]         # 查看日志（service: redis/openclaw/cc-switch-claude）
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
WEB_PORT=$(grep "^CC_SWITCH_WEB_PORT=" .env | cut -d'=' -f2)
REDIS_PASS=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)

if [ -z "${GATEWAY_PORT}" ]; then GATEWAY_PORT=18789; fi
if [ -z "${WEB_PORT}" ]; then WEB_PORT=8890; fi

debug "配置读取结果"
debug "  GATEWAY_PORT: ${GATEWAY_PORT}"
debug "  WEB_PORT: ${WEB_PORT}"
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
    echo ""
    echo -e "${CYAN}========== 当前大模型平台配置 ==========${NC}"
    echo -e "  ${CYAN}平台标识：${NC}${LLM_PLATFORM}"
    echo -e "  ${CYAN}平台名称：${NC}${LLM_PLATFORM_NAME}"
    echo -e "  ${CYAN}API 地址：${NC}${LLM_BASE_URL:-未配置}"
    echo -e "  ${CYAN}模型名称：${NC}${LLM_MODEL:-未配置}"
    if [ -n "${LLM_API_KEY}" ] && [ "${LLM_API_KEY}" != "your-"* ]; then
        echo -e "  ${CYAN}API Key：${NC}$(echo "${LLM_API_KEY}" | sed 's/\(.\{8\}\).*/\1.../')"
    else
        echo -e "  ${RED}API Key：未设置或为占位符${NC}"
    fi
    echo -e "  ${CYAN}协议：${NC}OpenAI Chat Completion"
    echo ""
}

# ============================================================
# 验证容器内模型配置是否生效
# ============================================================
verify_container_model() {
    info "验证容器内大模型配置..."

    local container_name="devpilot-openclaw"
    local found_errors=0

    # 检查 OpenClaw 容器的 LLM_PLATFORM
    local container_platform
    container_platform=$(docker exec "${container_name}" printenv LLM_PLATFORM 2>/dev/null || echo "")
    if [ -z "${container_platform}" ]; then
        warn "无法读取 ${container_name} 的 LLM_PLATFORM 环境变量"
        debug "  docker exec ${container_name} printenv LLM_PLATFORM -> 空"
        found_errors=1
    elif [ "${container_platform}" != "${LLM_PLATFORM}" ]; then
        warn "${container_name} 的 LLM_PLATFORM=${container_platform}，与 .env 配置(${LLM_PLATFORM})不一致！"
        warn "可能原因：容器未重建（尝试 ./service.sh restart 重建）"
        debug "  容器 LLM_PLATFORM: ${container_platform} vs .env LLM_PLATFORM: ${LLM_PLATFORM}"
        found_errors=1
    else
        success "${container_name} LLM_PLATFORM=${container_platform} 与配置一致"
        debug "  LLM_PLATFORM 验证通过"
    fi

    # 检查 CC-Switch 容器的 LLM_PLATFORM（如果容器存在）
    local cc_container="devpilot-cc-switch-claude"
    if docker inspect "${cc_container}" &>/dev/null; then
        local cc_platform
        cc_platform=$(docker exec "${cc_container}" printenv LLM_PLATFORM 2>/dev/null || echo "")
        if [ "${cc_platform}" != "${LLM_PLATFORM}" ]; then
            warn "${cc_container} 的 LLM_PLATFORM=${cc_platform}，与 .env 配置(${LLM_PLATFORM})不一致！"
            warn "可能原因：容器未重建（尝试 ./service.sh restart 重建）"
            debug "  CC LLM_PLATFORM: ${cc_platform} vs .env LLM_PLATFORM: ${LLM_PLATFORM}"
            found_errors=1
        else
            success "${cc_container} LLM_PLATFORM=${cc_platform} 与配置一致"
            debug "  CC-Switch LLM_PLATFORM 验证通过"
        fi

        # 检查 CC-Switch 配置文件中的 activeProvider
        local cc_config="/home/node/.cc-switch/config.json"
        local active_provider
        active_provider=$(docker exec "${cc_container}" cat "${cc_config}" 2>/dev/null | grep activeProvider | sed 's/.*: "\(.*\)".*/\1/' 2>/dev/null || echo "")
        if [ -n "${active_provider}" ]; then
            debug "  CC-Switch activeProvider: ${active_provider}"
            # 映射平台标识到供应商名称
            local expected_provider="${LLM_PLATFORM}"
            case "${LLM_PLATFORM}" in
                agnes) expected_provider="agnes-ai" ;;
            esac
            if [ "${active_provider}" != "${expected_provider}" ]; then
                warn "CC-Switch activeProvider=${active_provider}，与期望(${expected_provider})不一致"
                warn "可能原因：配置文件已存在且未被覆盖。删除 data/cc-switch-claude/.cc-switch/config.json 后重启"
                debug "  activeProvider: ${active_provider} vs expected: ${expected_provider}"
                found_errors=1
            else
                success "CC-Switch activeProvider=${active_provider} 与期望一致"
                debug "  activeProvider 验证通过"
            fi
        else
            debug "  CC-Switch 配置文件不存在或无法读取，跳过 activeProvider 检查"
        fi

        # 检查 ANTHROPIC_BASE_URL 是否已正确设置
        local anthropic_url
        anthropic_url=$(docker exec "${cc_container}" printenv ANTHROPIC_BASE_URL 2>/dev/null || echo "")
        if [ -n "${anthropic_url}" ]; then
            debug "  CC-Switch ANTHROPIC_BASE_URL: ${anthropic_url}"
            if [ "${anthropic_url}" != "${LLM_BASE_URL}" ]; then
                warn "CC-Switch ANTHROPIC_BASE_URL 与配置不一致"
                warn "  容器: ${anthropic_url}"
                warn "  配置: ${LLM_BASE_URL}"
                found_errors=1
            else
                success "CC-Switch ANTHROPIC_BASE_URL 与配置一致"
            fi
        fi
    else
        debug "  ${cc_container} 不存在，跳过验证"
    fi

    # 检查 API Key 是否为占位符
    if echo "${LLM_API_KEY}" | grep -q "^your-"; then
        error "API Key 仍为占位符(${LLM_API_KEY})，请编辑 .env 设置真实 API Key"
        found_errors=1
    fi

    echo ""
    if [ ${found_errors} -eq 0 ]; then
        success "大模型配置验证通过，所有容器配置一致"
        {
            echo ""
            echo "--- 模型配置验证 ---"
            echo "结果: 通过"
            echo "平台: ${LLM_PLATFORM} (${LLM_PLATFORM_NAME})"
            echo "模型: ${LLM_MODEL}"
            echo "API 地址: ${LLM_BASE_URL}"
        } >> "${LOG_FILE}"
    else
        warn "大模型配置验证发现问题，请按上述提示修复"
        {
            echo ""
            echo "--- 模型配置验证 ---"
            echo "结果: 有问题"
            echo "平台: ${LLM_PLATFORM} (${LLM_PLATFORM_NAME})"
            echo "模型: ${LLM_MODEL}"
            echo "API 地址: ${LLM_BASE_URL}"
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
    for port in "${GATEWAY_PORT}" "${WEB_PORT}"; do
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
        info "启动全部服务（Redis + OpenClaw + CC-Switch）..."
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
        debug "检查 CC-Switch Web 就绪（最多 30 次，间隔 2s）"
        wait_for_http "CC-Switch Web" "http://localhost:${WEB_PORT}" 30 2 || warn "CC-Switch 未就绪"
    fi

    # 验证容器内模型配置是否生效
    echo ""
    info "验证模型配置是否生效..."
    verify_container_model

    echo ""
    print_separator
    success "DevPilot 服务已就绪"
    print_separator

    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "bot" ]; then
        echo -e "  ${CYAN}OpenClaw:${NC}  http://localhost:${GATEWAY_PORT}"
    fi
    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "dev" ]; then
        echo -e "  ${CYAN}CC-Switch:${NC} http://localhost:${WEB_PORT}"
    fi
    echo -e "  ${CYAN}模型平台：${NC}${LLM_PLATFORM_NAME} (${LLM_MODEL})"
    echo ""

    # 总结日志
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
            echo "  CC-Switch: http://localhost:${WEB_PORT}"
        fi
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

    # 重新读取配置（确认是否有变更）
    info "重新读取配置..."
    read_llm_config
    print_model_config

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
        devpilot-redis devpilot-openclaw devpilot-cc-switch-claude 2>&1 | while IFS= read -r line; do
        echo "${line}"
        echo "${line}" >> "${LOG_FILE}"
    done || warn "无法获取资源使用"

    echo ""
    echo -e "${CYAN}端口监听:${NC}"
    for port_info in "OpenClaw:${GATEWAY_PORT}" "CC-Switch:${WEB_PORT}"; do
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

    echo -e "${CYAN}CC-Switch:${NC} "
    if curl -sf "http://localhost:${WEB_PORT}" >/dev/null 2>&1; then
        success "OK"
        echo "CC-Switch: OK" >> "${LOG_FILE}"
    else
        error "FAIL"
        echo "CC-Switch: FAIL" >> "${LOG_FILE}"
        all_ok=0
    fi

    echo -e "${CYAN}Claude Code:${NC} "
    if docker exec devpilot-cc-switch-claude claude --version 2>/dev/null; then
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
            cc-switch|cc|claude) service="cc-switch-claude" ;;
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
    echo -e "  ${GREEN}logs${NC}   [service]      查看日志（redis/openclaw/cc-switch-claude）"
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
