#!/bin/bash
set -e

# ============================================================
# DevPilot 一键部署脚本
# 功能：环境检查、配置生成、构建启动、健康检查
# 用法: ./deploy.sh
# 依赖：cicd/lib/common.sh（公共函数库）
# 日志：输出到控制台 + logs/deploy-YYYYMMDD-HHMMSS.log
# ============================================================

# ---- 加载公共函数库 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cicd/lib/common.sh"
cd "${SCRIPT_DIR}"

# ---- 日志文件设置 ----
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

# ---- 增强日志函数（带时间戳 + 双输出到控制台和日志文件） ----
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local color=""
    case "${level}" in
        INFO)   color="${BLUE}" ;;
        OK)     color="${GREEN}" ;;
        WARN)   color="${YELLOW}" ;;
        ERROR)  color="${RED}" ;;
        DETAIL) color="${CYAN}" ;;
    esac
    # 控制台输出（带颜色）
    echo -e "${color}[${ts}] [${level}]${NC} ${msg}"
    # 日志文件输出（无颜色码）
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
}

# 覆盖 common.sh 的函数，增加时间戳和日志文件输出
info()    { _log "INFO" "$*"; }
success() { _log "OK" "$*"; }
warn()    { _log "WARN" "$*"; }
error()   { _log "ERROR" "$*" >&2; }

# 子步骤日志
detail()  { _log "DETAIL" "  $*"; }

# 步骤计时
STEP_START=0
step_begin() {
    local num="$1"; local name="$2"
    echo "" >> "${LOG_FILE}"
    echo "========== 步骤 ${num}: ${name} ==========" >> "${LOG_FILE}"
    info "步骤 ${num}/7: ${name}"
    STEP_START=$SECONDS
}

step_end() {
    local elapsed=$((SECONDS - STEP_START))
    success "步骤完成（耗时 ${elapsed}s）"
    echo ""
}

# 以 root 权限执行（已是 root 直接运行，否则尝试 sudo）
run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        warn "需要 root 权限执行: $*（当前非 root 且无 sudo，跳过）"
        return 1
    fi
}

# 等待 Docker 守护进程就绪（最多约 60s）
wait_for_docker() {
    local i tries=30
    for ((i=1; i<=tries; i++)); do
        if docker info &>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# 部署前网络自愈（修复“DOCKER iptables 链缺失 / 孤儿网桥”导致的网络创建失败）：
# 1) 删除残留 devpilot-network（幂等）
# 2) 删除无对应 docker 网络的孤儿 br-* 网桥
# 3) 若 nat 表 DOCKER 链缺失，重启 Docker 守护进程以重建
preflight_network_cleanup() {
    local NETWORK_NAME="devpilot-network"
    local br short out rc
    local check_file; check_file="$(mktemp 2>/dev/null || echo /tmp/.devpilot_ipt_check)"

    # 1) 删除可能残留的自定义网络（幂等，不存在则跳过）
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "${NETWORK_NAME}"; then
        detail "删除残留网络: ${NETWORK_NAME}"
        docker network rm "${NETWORK_NAME}" 2>/dev/null || true
    fi

    # 2) 删除孤儿网桥（br-<12hex> 且没有任何 docker 网络 ID 以其为前缀）
    for br in $(ip -o link show 2>/dev/null | grep -oE 'br-[a-f0-9]{12}' | sort -u); do
        short="${br#br-}"
        if ! docker network ls -q 2>/dev/null | grep -q "^${short}"; then
            detail "删除孤儿网桥: ${br}"
            run_root ip link delete "${br}" 2>/dev/null || true
        fi
    done

    # 3) 检查 DOCKER iptables 链，缺失则重启 Docker 守护进程重建
    if run_root sh -c 'iptables -t nat -L DOCKER -n' >/dev/null 2>"${check_file}"; then
        detail "Docker DOCKER iptables 链正常"
    else
        out="$(cat "${check_file}" 2>/dev/null)"
        if echo "${out}" | grep -qiE "no chain|not exist|No chain/target"; then
            warn "检测到 Docker DOCKER iptables 链缺失，重启 Docker 守护进程以重建..."
            if run_root systemctl restart docker 2>/dev/null \
                || run_root service docker restart 2>/dev/null; then
                if wait_for_docker; then
                    success "Docker 守护进程已重启，DOCKER 链重建完成"
                else
                    error "Docker 守护进程重启后仍无法就绪，请检查 Docker 服务状态"
                    rm -f "${check_file}"
                    return 1
                fi
            else
                error "无法重启 Docker 守护进程，请手动执行: sudo systemctl restart docker"
                rm -f "${check_file}"
                return 1
            fi
        else
            warn "无法确认 DOCKER 链状态（${out}）；若部署仍报 DOCKER 链错误，请手动 sudo systemctl restart docker"
        fi
    fi
    rm -f "${check_file}"
}

# 敏感信息掩码
mask_secret() {
    local val="$1"
    if [ ${#val} -le 8 ]; then
        echo "****"
    else
        echo "${val:0:4}****${val: -4}"
    fi
}

# 打印部署后的访问凭据（OpenClaw Gateway Token）。
# - OpenClaw Token 优先取 .env（非空 + 非占位符），否则从 data/openclaw/.openclaw/openclaw.json
#   的 gateway.token 字段读取（容器自动生成场景）；
# - 若 openclaw.json 读到了真实 token 且 .env 仍是占位符/缺失，会回写到 .env 以保持一致。
# - cc-switch-web v0.21.0 已移除（不适合 headless 容器），主路由由 devpilot-litellm 承担。
print_credentials() {
    local openclaw_token="" token_source=""
    local env_token tmp

    # 1) OpenClaw Gateway Token
    env_token="$(grep '^OPENCLAW_GATEWAY_TOKEN=' .env | cut -d'=' -f2-)"
    if [ -n "${env_token}" ] && [ "${env_token}" != "change-me-to-secure-token" ]; then
        openclaw_token="${env_token}"
        token_source=".env"
    elif [ -f "data/openclaw/.openclaw/openclaw.json" ]; then
        # 从已生成的配置里读 gateway.token 字段（容器内 init-openclaw.sh 自动生成后写入）
        openclaw_token="$(grep -E '"token"[[:space:]]*:' data/openclaw/.openclaw/openclaw.json \
            | head -1 \
            | sed -E 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
        if [ -n "${openclaw_token}" ]; then
            token_source="data/openclaw/.openclaw/openclaw.json（容器内自动生成）"
            # 回写到 .env，保持脚本间一致
            if grep -q '^OPENCLAW_GATEWAY_TOKEN=' .env; then
                tmp="$(mktemp 2>/dev/null || echo .env.tmp)"
                sed "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=${openclaw_token}|" .env > "${tmp}"
                mv "${tmp}" .env
            fi
        fi
    fi
    if [ -z "${openclaw_token}" ]; then
        openclaw_token="（未获取到，请检查 data/openclaw/.openclaw/openclaw.json）"
        token_source="未知"
    fi

    # 控制台（带颜色）
    print_separator
    echo -e "${CYAN}  访问凭据  ${NC}"
    print_separator
    echo ""
    echo -e "${CYAN}OpenClaw Gateway${NC}"
    echo "  访问地址:        http://<VM_IP>:${GATEWAY_PORT}/"
    echo "  本机访问:        http://localhost:${GATEWAY_PORT}/"
    echo -e "  鉴权方式:        ${YELLOW}URL 末尾追加 #token=<token>${NC}"
    echo "  Gateway Token:   ${openclaw_token}"
    echo "  Token 来源:      ${token_source}"
    echo ""
    echo -e "${CYAN}飞书机器人${NC}"
    echo "  在飞书中搜索机器人（AppID 见 .env FEISHU_APP_ID），发消息即获 AI 回复"
    echo ""
    echo -e "${CYAN}Claude Code（devpilot-claude 容器）${NC}"
    echo "  使用方式:        docker compose exec devpilot-claude claude"
    echo "  LLM 路由:        通过 devpilot-litellm（http://litellm:4000）"
    echo "  配置:            ANTHROPIC_BASE_URL=http://litellm:4000（容器内 ~/.claude/settings.json）"
    echo ""

    # 同步写入日志文件（无颜色）
    {
        echo ""
        echo "========== 访问凭据 =========="
        echo "OpenClaw Gateway: http://<VM_IP>:${GATEWAY_PORT}/"
        echo "  Token:       ${openclaw_token}"
        echo "  Token来源:   ${token_source}"
        echo "  URL鉴权:     在地址末尾追加 #token=<token>"
        echo "Claude Code:     docker compose exec devpilot-claude claude"
        echo "  LLM 路由:   http://litellm:4000（devpilot-litellm 代理）"
    } >> "${LOG_FILE}"
}

# ============================================================
# 启动
# ============================================================
echo "========================================" | tee -a "${LOG_FILE}"
echo "  DevPilot 一键部署" | tee -a "${LOG_FILE}"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${LOG_FILE}"
echo "  日志: ${LOG_FILE}" | tee -a "${LOG_FILE}"
echo "========================================" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# ============================================================
# 步骤 1: 环境检查
# ============================================================
step_begin 1 "环境检查"

# Docker
detail "检查 Docker..."
if ! command -v docker &>/dev/null; then
    error "Docker 未安装，请先安装 Docker Engine 24.0+"
    error "安装指南: https://docs.docker.com/engine/install/"
    exit 1
fi
DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
success "Docker 版本: ${DOCKER_VER}"
detail "Docker 路径: $(command -v docker)"

# Docker Compose
detail "检查 Docker Compose..."
if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 未安装，请安装 Docker Compose v2.20+"
    exit 1
fi
COMPOSE_VER=$(docker compose version --short)
success "Docker Compose: ${COMPOSE_VER}"

# Docker 守护进程
detail "检查 Docker 守护进程..."
if ! docker info &>/dev/null; then
    error "Docker 守护进程未运行，请启动 Docker"
    exit 1
fi
success "Docker 守护进程运行中"

# 系统资源
detail "检查系统资源..."
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "unknown")
MEM_AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo "unknown")
DISK_AVAIL=$(df -m . 2>/dev/null | awk 'NR==2{print $4}' || echo "unknown")
detail "内存: 总计 ${MEM_TOTAL}MB, 可用 ${MEM_AVAIL}MB"
detail "磁盘: 可用 ${DISK_AVAIL}MB"

if [ "${MEM_AVAIL}" != "unknown" ] && [ "${MEM_AVAIL}" -lt 2048 ]; then
    warn "可用内存不足 2GB（当前 ${MEM_AVAIL}MB），可能导致 OOM"
fi
if [ "${DISK_AVAIL}" != "unknown" ] && [ "${DISK_AVAIL}" -lt 5120 ]; then
    warn "可用磁盘不足 5GB（当前 ${DISK_AVAIL}MB），可能导致构建失败"
fi

# Docker 磁盘使用
DOCKER_DISK=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "unknown")
detail "Docker 磁盘占用: ${DOCKER_DISK}"

# Make (可选)
if command -v make &>/dev/null; then
    success "Make 已安装（可用 make 命令）"
else
    warn "Make 未安装（可选，安装后可用 make 命令快捷操作）"
fi

# 网络端口检查（仅 OpenClaw Gateway 端口；cc-switch-web v0.21.0 已移除）
detail "检查端口占用..."
GATEWAY_PORT_CHECK=$(grep "^OPENCLAW_GATEWAY_PORT=" .env 2>/dev/null | cut -d'=' -f2 || echo "18789")
for port in "${GATEWAY_PORT_CHECK}"; do
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            warn "端口 ${port} 已被占用"
        else
            detail "端口 ${port} 可用"
        fi
    fi
done

step_end

# ============================================================
# 步骤 2: 创建数据目录
# ============================================================
step_begin 2 "创建数据目录"

detail "创建 data/ 目录..."
mkdir -p data/redis data/openclaw data/devpilot-claude
detail "  data/redis/         - Redis 持久化"
detail "  data/openclaw/      - OpenClaw 配置"
detail "  data/devpilot-claude/ - CC-Switch 数据"

detail "创建 logs/ 目录..."
mkdir -p logs/redis logs/openclaw logs/devpilot-claude
detail "  logs/redis/          - Redis 日志"
detail "  logs/openclaw/       - OpenClaw 日志"
detail "  logs/devpilot-claude/ - CC-Switch 日志"

detail "创建 workspace/ 目录..."
mkdir -p workspace
touch workspace/.gitkeep

success "目录结构已创建"

step_end

# ============================================================
# 步骤 3: 检查 .env 配置
# ============================================================
step_begin 3 "检查环境变量配置"

if [ ! -f ".env" ]; then
    if [ -f "./init.sh" ]; then
        warn ".env 文件不存在，启动配置向导..."
        echo ""
        bash ./init.sh
        if [ ! -f ".env" ]; then
            error "配置未完成，请重新运行 ./deploy.sh"
            exit 1
        fi
    elif [ -f ".env.example" ]; then
        warn ".env 文件不存在，从模板创建..."
        cp .env.example .env
        AUTO_REDIS_PASS=$(gen_password 32)
        AUTO_TOKEN=$(gen_password 32)
        sed -i.bak \
            -e "s|REDIS_PASSWORD=change-me-to-strong-password|REDIS_PASSWORD=${AUTO_REDIS_PASS}|" \
            -e "s|OPENCLAW_GATEWAY_TOKEN=change-me-to-secure-token|OPENCLAW_GATEWAY_TOKEN=${AUTO_TOKEN}|" \
            .env
        rm -f .env.bak
        success "已自动生成 Redis 密码和 Gateway Token"
        warn "请编辑 .env 文件填入 agnes-ai API Key 和飞书凭证"
        echo ""
        echo "  vim .env"
        echo ""
        exit 0
    else
        error ".env 文件、init.sh 和 .env.example 都不存在"
        exit 1
    fi
fi

# 加载版本配置
if [ -f "versions.env" ]; then
    detail "加载 versions.env..."
    source versions.env
    detail "  Node.js:       ${NODE_IMAGE_TAG}"
    detail "  OpenClaw:      ${OPENCLAW_VERSION}"
    detail "  Claude Code:   ${CLAUDE_CODE_VERSION}"
    detail "  Claude Code:   ${CLAUDE_CODE_VERSION}"
fi

# 逐项检查环境变量（敏感信息掩码）
detail "检查环境变量..."

check_env_var() {
    local var_name="$1"
    local var_desc="$2"
    local is_secret="$3"
    local var_value
    var_value=$(grep "^${var_name}=" .env 2>/dev/null | cut -d'=' -f2-)

    if [ -z "${var_value}" ]; then
        error "${var_desc} 未配置（${var_name}）"
        return 1
    elif echo "${var_value}" | grep -qE "your-|change-me"; then
        error "${var_desc} 仍为占位符（${var_name}=${var_value}）"
        return 1
    else
        if [ "${is_secret}" = "secret" ]; then
            detail "  ${var_name} = $(mask_secret "${var_value}")"
        else
            detail "  ${var_name} = ${var_value}"
        fi
        return 0
    fi
}

ENV_ERRORS=0
check_env_var "AGNES_API_KEY"          "agnes-ai API Key"     "secret" || ENV_ERRORS=$((ENV_ERRORS + 1))
check_env_var "AGNES_BASE_URL"         "agnes-ai API 地址"     ""       || ENV_ERRORS=$((ENV_ERRORS + 1))
check_env_var "FEISHU_APP_ID"          "飞书 App ID"          ""       || ENV_ERRORS=$((ENV_ERRORS + 1))
check_env_var "FEISHU_APP_SECRET"      "飞书 App Secret"      "secret" || ENV_ERRORS=$((ENV_ERRORS + 1))
check_env_var "REDIS_PASSWORD"         "Redis 密码"           "secret" || ENV_ERRORS=$((ENV_ERRORS + 1))
check_env_var "OPENCLAW_GATEWAY_TOKEN" "Gateway Token"        "secret" || ENV_ERRORS=$((ENV_ERRORS + 1))
check_env_var "OPENCLAW_GATEWAY_PORT"  "Gateway 端口"         ""       || ENV_ERRORS=$((ENV_ERRORS + 1))
# CC_SWITCH_WEB_PORT 已移除（cc-switch-web v0.21.0 不再部署）
check_env_var "TZ"                     "时区"                 ""       || ENV_ERRORS=$((ENV_ERRORS + 1))

if [ ${ENV_ERRORS} -gt 0 ]; then
    echo ""
    error "有 ${ENV_ERRORS} 个变量未配置或仍为占位符"
    echo ""
    echo "  vim .env"
    echo "  或运行配置向导: ./init.sh"
    echo ""
    exit 1
fi

success ".env 配置检查通过（${ENV_ERRORS} 个错误）"

step_end

# ============================================================
# 步骤 4: 构建镜像
# ============================================================
step_begin 4 "构建 Docker 镜像"

detail "构建配置:"
detail "  OpenClaw Dockerfile:    dockerfiles/openclaw/Dockerfile"
detail "  CC-Switch Dockerfile:   dockerfiles/devpilot-claude/Dockerfile"
detail "  构建上下文:             ${SCRIPT_DIR}"
detail "  .dockerignore:          已启用"

info "开始构建镜像（首次构建需 5-10 分钟）..."
echo ""

# 前置网络自愈清理（修复 DOCKER iptables 链缺失 / 孤儿网桥导致的网络创建失败）
info "前置网络清理（自愈检查）..."
preflight_network_cleanup || warn "前置网络清理未完全成功，若部署仍报 DOCKER iptables 链错误，请参考运维操作手册 § 网络与 iptables 排障"

BUILD_START=$SECONDS
docker compose up -d --build 2>&1 | while IFS= read -r line; do
    echo "  ${line}"
    echo "${line}" >> "${LOG_FILE}"
done
BUILD_ELAPSED=$((SECONDS - BUILD_START))

echo ""
success "镜像构建完成（耗时 ${BUILD_ELAPSED}s）"

# 记录镜像大小
detail "镜像信息:"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null | grep -E "devpilot|REPOSITORY" | while read -r line; do
    detail "  ${line}"
done

step_end

# ============================================================
# 步骤 5: 容器状态验证
# ============================================================
step_begin 5 "容器状态验证"

detail "检查容器运行状态..."
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | while IFS= read -r line; do
    detail "  ${line}"
done

# 逐容器检查
for container in devpilot-redis devpilot-openclaw devpilot-claude; do
    detail "检查容器: ${container}"
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        local_status=$(docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null)
        local_health=$(docker inspect --format '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "none")
        detail "  状态: ${local_status}, 健康检查: ${local_health}"
        success "容器运行中: ${container}"
    else
        error "容器未运行: ${container}"
        detail "  最后 20 行日志:"
        docker compose logs --tail 20 "${container/devpilot-/}" 2>/dev/null | head -20 | while read -r line; do
            detail "    ${line}"
        done
    fi
done

# 端口绑定检查
detail "检查端口绑定..."
GATEWAY_PORT=$(grep "^OPENCLAW_GATEWAY_PORT=" .env | cut -d'=' -f2)
WEB_PORT=$(grep "^CC_SWITCH_WEB_PORT=" .env | cut -d'=' -f2)
REDIS_PASS=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)

for port_info in "OpenClaw:${GATEWAY_PORT}" "CC-Switch:${WEB_PORT}"; do
    name="${port_info%%:*}"
    port="${port_info##*:}"
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            detail "  ${name} 端口 ${port} 已监听"
        else
            warn "  ${name} 端口 ${port} 未监听"
        fi
    fi
done

step_end

# ============================================================
# 步骤 6: 健康检查
# ============================================================
step_begin 6 "健康检查"

detail "Redis 健康检查（最多 45 次重试，每 2s 一次）..."
wait_for_redis "devpilot-redis" "${REDIS_PASS}" 45 || warn "Redis 未在预期时间内就绪"

detail "OpenClaw 健康检查（最多 30 次重试，每 3s 一次）..."
wait_for_http "OpenClaw" "http://localhost:${GATEWAY_PORT}/healthz" 30 3 || warn "OpenClaw 未在预期时间内就绪"

detail "CC-Switch Web 健康检查（最多 45 次重试，每 2s 一次）..."
wait_for_http "CC-Switch Web" "http://localhost:${WEB_PORT}" 45 2 || warn "CC-Switch 未在预期时间内就绪"

step_end

# ============================================================
# 步骤 7: 部署总结
# ============================================================
step_begin 7 "部署总结"

print_separator
success "DevPilot 部署完成"
print_separator
echo ""
echo -e "${CYAN}服务地址:${NC}"
echo "  Redis:        容器内部 :6379"
echo "  OpenClaw:     http://localhost:${GATEWAY_PORT}"
echo "  CC-Switch:    http://localhost:${WEB_PORT}"
echo ""
echo -e "${CYAN}常用命令:${NC}"
echo "  启动 Claude Code:   docker compose exec devpilot-claude claude"
echo "  查看日志:          docker compose logs -f"
echo "  查看状态:          docker compose ps"
echo "  健康检查:          make health"
echo "  一键启停:          ./service.sh start|stop|status"
echo ""
echo -e "${CYAN}飞书机器人:${NC}"
echo "  在飞书中搜索并添加你的机器人，发送消息即可获得 AI 回复"
echo ""
echo -e "${CYAN}CC-Switch 配置:${NC}"
echo "  1. 浏览器打开 http://localhost:${WEB_PORT}"
echo "  2. 添加 agnes-ai 供应商（API Key 在 .env 文件中）"
echo "  3. 启用 Claude Code takeover"
echo ""

# 打印本次部署生效的访问凭据（OpenClaw Token / CC-Switch Web 用户名密码）
print_credentials

echo -e "${YELLOW}部署日志: ${LOG_FILE}${NC}"
echo ""
echo "========================================"

# 记录到日志文件
{
    echo ""
    echo "========== 部署总结 =========="
    echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "状态: 完成"
    echo "OpenClaw:  http://localhost:${GATEWAY_PORT}"
    echo "CC-Switch: http://localhost:${WEB_PORT}"
    echo "日志文件:  ${LOG_FILE}"
} >> "${LOG_FILE}"

step_end
