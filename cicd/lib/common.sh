#!/bin/bash

# ============================================================
# DevPilot - 公共函数库
# 所有部署/CI/CD脚本通过 source 加载此文件，消除重复代码
#
# 用法:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# ============================================================

# ---- 颜色定义 ----
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export MAGENTA='\033[0;35m'
export NC='\033[0m'

# ---- 信息输出函数 ----
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ---- 分隔线 ----
print_separator() {
    echo -e "${CYAN}========================================${NC}"
}

print_header() {
    echo ""
    echo -e "${MAGENTA}========================================${NC}"
    echo -e "${MAGENTA}  $*${NC}"
    echo -e "${MAGENTA}========================================${NC}"
    echo ""
}

# ============================================================
# 路径定位
# ============================================================

# 获取脚本所在目录（common.sh 被 source 后，调用方使用 BASH_SOURCE 定位）
# 用法: PROJECT_ROOT=$(get_project_root)
get_project_root() {
    local script_dir
    # 向上查找包含 docker-compose.yml 或 .env.example 的目录
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-$BASH_SOURCE}")" && pwd)"
    local dir="${script_dir}"
    while [ "${dir}" != "/" ]; do
        if [ -f "${dir}/docker-compose.yml" ] || [ -f "${dir}/.env.example" ]; then
            echo "${dir}"
            return 0
        fi
        dir="$(cd "${dir}/.." && pwd)"
    done
    # 回退：假设标准目录结构
    echo "$(cd "${script_dir}/../.." && pwd)"
}

# ============================================================
# .env 文件加载
# ============================================================

# 加载 .env 文件并导出环境变量
# 用法: load_env [env_file_path]
# 默认路径: ${PROJECT_ROOT}/.env
load_env() {
    local env_file="${1:-$(get_project_root)/.env}"

    if [ ! -f "${env_file}" ]; then
        error "未找到 .env 文件: ${env_file}"
        echo "  请先运行: cp .env.example .env && vim .env"
        echo "  或使用配置向导: ./init.sh"
        return 1
    fi

    set -a
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        export "$line" 2>/dev/null || true
    done < "${env_file}"
    set +a
}

# ============================================================
# 环境变量校验
# ============================================================

# 校验必需的环境变量
# 用法: validate_required_vars VAR1 VAR2 VAR3 ...
validate_required_vars() {
    local missing=0
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            error ".env 中缺少必需变量: ${var}"
            missing=1
        fi
    done
    if [ "${missing}" -eq 1 ]; then
        return 1
    fi
    return 0
}

# DevPilot 公共必填变量（与所选大模型平台无关）
DEVPILOT_COMMON_REQUIRED_VARS=(
    LLM_PLATFORM
    FEISHU_APP_ID
    FEISHU_APP_SECRET
    REDIS_PASSWORD
    OPENCLAW_GATEWAY_TOKEN
    OPENCLAW_GATEWAY_PORT
    NODE_IMAGE_TAG
    OPENCLAW_VERSION
    CLAUDE_CODE_VERSION
    TZ
)

# 根据 LLM_PLATFORM 返回该平台必填的环境变量名（空格分隔，供 validate_required_vars）
# 用法: platform_vars=$(get_platform_required_vars)
get_platform_required_vars() {
    local platform="${LLM_PLATFORM:-agnes}"
    local prefix
    case "${platform}" in
        agnes)    prefix="AGNES" ;;
        deepseek) prefix="DEEPSEEK" ;;
        glm)      prefix="GLM" ;;
        ark)      prefix="ARK" ;;
        bailian)  prefix="BAILIAN" ;;
        *)        prefix="AGNES" ;;  # 未知平台回退 agnes
    esac
    echo "${prefix}_API_KEY ${prefix}_BASE_URL ${prefix}_MODEL"
}

# 校验 DevPilot 平台部署所需的全部变量（公共必填 + 当前 LLM_PLATFORM 对应平台必填）
validate_devpilot_env() {
    local missing=0
    # 1) 公共必填变量
    validate_required_vars "${DEVPILOT_COMMON_REQUIRED_VARS[@]}" || missing=1
    # 2) 当前 LLM_PLATFORM 对应平台的必填变量
    local platform_vars
    platform_vars=$(get_platform_required_vars)
    validate_required_vars ${platform_vars} || missing=1
    return ${missing}
}

# ============================================================
# 命令执行（支持 dry-run）
# ============================================================

# DRY_RUN 变量需在调用前设置
export DRY_RUN="${DRY_RUN:-false}"

# 执行命令（支持 dry-run 模式）
# 用法: run_cmd "docker build ..." 或 run_cmd -- docker build ...
run_cmd() {
    if [ "${DRY_RUN}" = "true" ]; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# ============================================================
# 通用健康检查
# ============================================================

# 等待 HTTP 服务就绪
# 用法: wait_for_http "名称" "url" [max_retries] [interval_sec]
wait_for_http() {
    local name="$1"
    local url="$2"
    local max="${3:-30}"
    local interval="${4:-2}"
    local count=0

    info "等待 ${name} 就绪 ..."
    while [ ${count} -lt ${max} ]; do
        # 鉴权服务对未登录请求返回 401，属正常"已就绪"态；
        # 故以"HTTP 服务已响应（状态码非 000/空）"为就绪判据，而非要求 2xx。
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null)
        if [ -n "${code}" ] && [ "${code}" != "000" ]; then
            success "${name} 已就绪 (HTTP ${code})"
            return 0
        fi
        count=$((count + 1))
        sleep "${interval}"
    done
    warn "${name} 未在 ${max} 次重试内就绪"
    return 1
}

# 等待容器内 HTTP 服务就绪
# 用法: wait_for_container_http "容器名" "端口" "路径" [max_retries] [interval_sec]
wait_for_container_http() {
    local container="$1"
    local port="$2"
    local path="${3:-/healthz}"
    local max="${4:-30}"
    local interval="${5:-3}"
    local count=0

    info "等待 ${container} 就绪 ..."
    while [ ${count} -lt ${max} ]; do
        if docker exec "${container}" curl -sf "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
            success "${container} 已就绪"
            return 0
        fi
        count=$((count + 1))
        sleep "${interval}"
    done
    warn "${container} 未在 ${max} 次重试内就绪"
    return 1
}

# 等待 Redis 就绪
# 用法: wait_for_redis "容器名" "密码" [max_retries]
wait_for_redis() {
    local container="${1:-devpilot-redis}"
    local password="$2"
    local max="${3:-30}"
    local count=0

    info "等待 Redis 就绪 ..."
    while [ ${count} -lt ${max} ]; do
        if docker exec "${container}" redis-cli -a "${password}" ping 2>/dev/null | grep -q "PONG"; then
            success "Redis 已就绪"
            return 0
        fi
        count=$((count + 1))
        sleep 2
    done
    warn "Redis 未在 ${max} 次重试内就绪"
    return 1
}

# ============================================================
# Docker 辅助函数
# ============================================================

# 确保 Docker 网络存在（幂等）
# 用法: ensure_docker_network "网络名"
ensure_docker_network() {
    local network="$1"
    if docker network inspect "${network}" &>/dev/null; then
        success "网络已存在: ${network}"
    else
        docker network create --driver bridge "${network}"
        success "网络已创建: ${network}"
    fi
}

# 清理旧容器（幂等）
# 用法: remove_container_if_exists "容器名"
remove_container_if_exists() {
    local container="$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        warn "发现旧容器: ${container}，正在删除 ..."
        docker rm -f "${container}" >/dev/null
    fi
}

# 创建项目数据目录（幂等）
# 用法: create_data_dirs "${PROJECT_ROOT}"
create_data_dirs() {
    local root="$1"
    mkdir -p "${root}/data/redis" "${root}/data/openclaw" "${root}/data/devpilot-claude"
    mkdir -p "${root}/logs/redis" "${root}/logs/openclaw" "${root}/logs/devpilot-claude"
    mkdir -p "${root}/workspace"
    touch "${root}/workspace/.gitkeep"
}

# ============================================================
# 密码生成
# ============================================================

# 生成随机密码（十六进制）
# 用法: gen_password [length]
gen_password() {
    local length="${1:-32}"
    openssl rand -hex $((length / 2)) 2>/dev/null || head -c "${length}" /dev/urandom | xxd -p | tr -d '\n' | head -c "${length}"
}

# ============================================================
# 错误陷阱
# ============================================================

# 设置错误陷阱（显示行号）
setup_error_trap() {
    trap 'error "执行过程中发生错误，行号: $LINENO"' ERR
}
