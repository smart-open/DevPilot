#!/bin/bash
set -e

# ============================================================
# DevPilot 一键启停脚本
# 基于运维操作手册编写，覆盖日常启停、状态查看、健康检查
#
# 用法:
#   ./service.sh start  [full|bot|dev]  # 启动服务（默认 full）
#   ./service.sh stop                   # 停止所有服务
#   ./service.sh restart [full|bot|dev] # 重启服务
#   ./service.sh status                 # 查看容器状态
#   ./service.sh health                 # 健康检查
#   ./service.sh logs [service]         # 查看日志（service: redis/openclaw/cc-switch-claude）
#   ./service.sh help                   # 显示帮助
#
# 依赖：cicd/lib/common.sh、.env
# ============================================================

# ---- 加载公共函数库 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cicd/lib/common.sh"
cd "${SCRIPT_DIR}"

# ---- 检查 .env ----
if [ ! -f ".env" ]; then
    error ".env 文件不存在，请先运行: ./init.sh"
    exit 1
fi

# ---- 读取端口配置 ----
GATEWAY_PORT=$(grep "^OPENCLAW_GATEWAY_PORT=" .env | cut -d'=' -f2)
WEB_PORT=$(grep "^CC_SWITCH_WEB_PORT=" .env | cut -d'=' -f2)
REDIS_PASS=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)

# ============================================================
# 函数定义
# ============================================================

# 解析 profile 参数
parse_profile() {
    local profile="${1:-full}"
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

    info "检查 Docker 守护进程..."
    if ! docker info &>/dev/null; then
        error "Docker 守护进程未运行"
        exit 1
    fi
    success "Docker 运行中"

    info "检查端口占用..."
    for port in "${GATEWAY_PORT}" "${WEB_PORT}"; do
        if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            warn "端口 ${port} 已被占用（可能是已有服务运行）"
        fi
    done

    local cmd
    cmd=$(compose_cmd "${profile_flag}")

    if [ -z "${profile_flag}" ]; then
        info "启动全部服务（Redis + OpenClaw + CC-Switch）..."
    else
        info "启动 profile=${profile_flag} 的服务..."
    fi

    ${cmd} up -d --build 2>&1 | while IFS= read -r line; do
        echo "  ${line}"
    done

    echo ""
    success "服务已启动"

    # 等待健康检查
    info "等待服务就绪..."
    echo ""

    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "bot" ]; then
        wait_for_redis "devpilot-redis" "${REDIS_PASS}" 30 || warn "Redis 未就绪"
        wait_for_http "OpenClaw" "http://localhost:${GATEWAY_PORT}/healthz" 20 3 || warn "OpenClaw 未就绪"
    fi

    if [ "${profile_name}" = "full" ] || [ "${profile_name}" = "dev" ]; then
        wait_for_http "CC-Switch Web" "http://localhost:${WEB_PORT}" 30 2 || warn "CC-Switch 未就绪"
    fi

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
    echo ""
}

# 停止服务
do_stop() {
    print_header "停止 DevPilot 服务"

    info "停止所有容器..."
    docker compose --env-file .env down 2>&1 | while IFS= read -r line; do
        echo "  ${line}"
    done

    echo ""
    success "所有服务已停止（数据保留在 data/ 目录）"
    echo ""
}

# 重启服务
do_restart() {
    local profile_name="${1:-full}"

    print_header "重启 DevPilot 服务（模式: ${profile_name}）"

    info "停止当前服务..."
    docker compose --env-file .env down 2>&1 | while IFS= read -r line; do
        echo "  ${line}"
    done

    echo ""
    success "已停止，正在重新启动..."

    do_start "${profile_name}"
}

# 查看状态
do_status() {
    print_header "DevPilot 容器状态"

    echo -e "${CYAN}容器列表:${NC}"
    docker compose --env-file .env ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || warn "无法获取容器状态"

    echo ""
    echo -e "${CYAN}资源使用:${NC}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" \
        devpilot-redis devpilot-openclaw devpilot-cc-switch-claude 2>/dev/null || warn "无法获取资源使用"

    echo ""
    echo -e "${CYAN}端口监听:${NC}"
    for port_info in "OpenClaw:${GATEWAY_PORT}" "CC-Switch:${WEB_PORT}"; do
        name="${port_info%%:*}"
        port="${port_info##*:}"
        if command -v ss &>/dev/null; then
            if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                success "${name} 端口 ${port} 正在监听"
            else
                error "${name} 端口 ${port} 未监听"
            fi
        fi
    done
    echo ""
}

# 健康检查
do_health() {
    print_header "DevPilot 健康检查"

    echo -e "${CYAN}Redis:${NC}     "
    if docker exec devpilot-redis redis-cli -a "${REDIS_PASS}" ping 2>/dev/null | grep -q PONG; then
        success "PONG"
    else
        error "FAIL"
    fi

    echo -e "${CYAN}OpenClaw:${NC}  "
    if curl -sf "http://localhost:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then
        success "OK"
    else
        error "FAIL"
    fi

    echo -e "${CYAN}CC-Switch:${NC} "
    if curl -sf "http://localhost:${WEB_PORT}" >/dev/null 2>&1; then
        success "OK"
    else
        error "FAIL"
    fi

    echo -e "${CYAN}Claude Code:${NC} "
    if docker exec devpilot-cc-switch-claude claude --version 2>/dev/null; then
        success "OK"
    else
        warn "未检测到（可能 dev profile 未启动）"
    fi
    echo ""
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
    echo -e "${CYAN}命令:${NC}"
    echo -e "  ${GREEN}start${NC}  [full|bot|dev]  启动服务（默认 full）"
    echo -e "  ${GREEN}stop${NC}                  停止所有服务（保留数据）"
    echo -e "  ${GREEN}restart${NC} [full|bot|dev] 重启服务"
    echo -e "  ${GREEN}status${NC}                查看容器状态和资源使用"
    echo -e "  ${GREEN}health${NC}                健康检查（Redis/OpenClaw/CC-Switch/Claude）"
    echo -e "  ${GREEN}logs${NC}   [service]      查看日志（redis/openclaw/cc-switch-claude）"
    echo -e "  ${GREEN}help${NC}                  显示此帮助"
    echo ""
    echo -e "${CYAN}部署模式:${NC}"
    echo "  full  - Redis + OpenClaw + CC-Switch（完整功能）"
    echo "  bot   - Redis + OpenClaw（仅飞书机器人）"
    echo "  dev   - CC-Switch + Claude Code（仅开发环境）"
    echo ""
    echo -e "${CYAN}示例:${NC}"
    echo "  ./service.sh start           # 启动全部服务"
    echo "  ./service.sh start bot       # 仅启动飞书机器人"
    echo "  ./service.sh stop            # 停止所有服务"
    echo "  ./service.sh restart         # 重启全部服务"
    echo "  ./service.sh status          # 查看状态"
    echo "  ./service.sh health          # 健康检查"
    echo "  ./service.sh logs redis      # 查看 Redis 日志"
    echo ""
}

# ============================================================
# 主入口
# ============================================================
COMMAND="${1:-help}"
shift 2>/dev/null || true

case "${COMMAND}" in
    start)  do_start "$@" ;;
    stop)   do_stop ;;
    restart) do_restart "$@" ;;
    status) do_status ;;
    health) do_health ;;
    logs)   do_logs "$@" ;;
    help|--help|-h) show_help ;;
    *)
        error "未知命令: ${COMMAND}"
        show_help
        exit 1
        ;;
esac
