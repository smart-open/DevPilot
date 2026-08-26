#!/bin/bash

# ============================================================
# DevPilot - 公共函数库
# 所有部署/CI/CD脚本通过 source 加载此文件，消除重复代码
#
# 用法:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# Source guard：同一 shell 进程内重复 source 时跳过重定义。
# ⚠️ 此变量禁止 export：一旦泄漏进子进程（如 feishu-deploy-handler.sh
#    以 `bash deploy-service.sh` 启动子进程），子进程 source 本文件会被
#    guard 短路，所有函数未定义——曾导致 "setup_error_trap: command not
#    found"（deploy-service.sh line 25）。
# ============================================================
[ -n "${_DEVPILOT_COMMON_LOADED:-}" ] && return 0
_DEVPILOT_COMMON_LOADED=1

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

# 解析服务部署用的 workspace 目录（deploy-service.sh / feishu-deploy-handler.sh /
# post-dev-hook.sh 的统一入口）。
# 优先级: WORKSPACE_DIR 环境变量 > 容器内挂载点 /workspace > ${PROJECT_ROOT}/workspace
# 背景: docker exec 不经过 start.sh（不会注入 WORKSPACE_DIR），容器内直接调用
#       部署脚本时此前回退到 /opt/devpilot/workspace（不存在）导致 --list 等
#       命令静默失败。/.dockerenv 是 Docker 容器标准标志文件，用它可以区分
#       容器与宿主机，避免宿主机恰好存在 /workspace 目录时误判。
# 用法: WORKSPACE_DIR="$(resolve_workspace_dir)"
resolve_workspace_dir() {
    if [ -n "${WORKSPACE_DIR:-}" ]; then
        echo "${WORKSPACE_DIR}"
    elif [ -d /workspace ] && [ -f /.dockerenv ]; then
        echo "/workspace"
    else
        echo "$(get_project_root)/workspace"
    fi
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
    mkdir -p "${root}/data/redis" "${root}/data/openclaw" "${root}/data/claude-litellm"
    mkdir -p "${root}/logs/redis" "${root}/logs/openclaw" "${root}/logs/claude-litellm"
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

# ============================================================
# ⚠️  READ ME FIRST  ⚠️   平台解析的统一入口（Single Source of Truth）
# ============================================================
# DevPilot 的"大模型平台 → 字段映射"逻辑**只此一处**。任何脚本需要
# 解析 LLM_PLATFORM，都应调用 configure_platform() 而不是再写一段
# case/esac。
#
# 调用方用法（任何 shell 脚本，开头 source common.sh 后）：
#   configure_platform "${LLM_PLATFORM:-agnes}"
# 输出（export 到当前 shell）：
#   LLM_PLATFORM        当前平台 id（agnes/deepseek/glm/ark/bailian）
#   LLM_API_KEY         该平台真实 API Key（占位符则 configure_platform 返回 1）
#   LLM_BASE_URL        该平台 API base（默认值兜底）
#   LLM_MODEL           默认模型
#   LLM_PLATFORM_NAME   中文显示名（"Agnes AI" / "百炼（DashScope）" 等）
#   LLM_CODE_MODEL      部分平台的代码模型（如 deepseek，无则空串）
#   LLM_CODE_PLAN_MODEL 部分平台的代码规划模型（如 ark，无则空串）
#   ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY / ANTHROPIC_MODEL
#                       Claude Code 通过这三个 env 连 litellm 时用
#
# ✅ 加新平台：**只改本文件的 _resolve_llm_platform_vars 一次**
# ❌ 加新平台：禁止在其它脚本再加 case "${LLM_PLATFORM}" in ... esac
#
# 历史：commit 0a2de98 把这块从 scripts/llm-init.sh 抽出作为 SSOT。
#       后续 commit a9c8f87 / 3c2e209 / 1b46d88 把 7 处散落副本全部
#       收敛到本函数。
# ============================================================

# 解析当前 LLM_PLATFORM 对应的 prefix / default base_url / default model。
# 用 bash 3 兼容写法（不用 declare -A 关联数组）。
# 用法: _resolve_llm_platform_vars <platform> prefix_var def_base_var def_model_var [extra_key_var extra_def_var]
_resolve_llm_platform_vars() {
    local platform="$1"
    case "${platform}" in
        agnes)
            printf -v "$2" '%s' "AGNES"
            printf -v "$3" '%s' "https://api.agnes-ai.cn/v1"
            printf -v "$4" '%s' "agnes-2.5-flash"
            ;;
        deepseek)
            printf -v "$2" '%s' "DEEPSEEK"
            printf -v "$3" '%s' "https://api.deepseek.com/v1"
            printf -v "$4" '%s' "DeepSeek-V4-Flash"
            printf -v "${5:-_x}" '%s' "DEEPSEEK_CODE_MODEL"
            printf -v "${6:-_x}" '%s' "DeepSeek-V4-Flash"
            ;;
        glm)
            printf -v "$2" '%s' "GLM"
            printf -v "$3" '%s' "https://open.bigmodel.cn/api/paas/v4"
            printf -v "$4" '%s' "GLM-5.2"
            ;;
        ark)
            printf -v "$2" '%s' "ARK"
            printf -v "$3" '%s' "https://ark.cn-beijing.volces.com/api/v3"
            printf -v "$4" '%s' "doubao-seed-2.1-turbo"
            printf -v "${5:-_x}" '%s' "ARK_CODE_PLAN_MODEL"
            printf -v "${6:-_x}" '%s' "doubao-seed-2.1-turbo"
            ;;
        bailian)
            printf -v "$2" '%s' "BAILIAN"
            printf -v "$3" '%s' "https://dashscope.aliyuncs.com/compatible-mode/v1"
            printf -v "$4" '%s' "Qwen3.7-Plus"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# 配置指定平台；输出统一变量 LLM_API_KEY / LLM_BASE_URL / LLM_MODEL /
# LLM_PLATFORM_NAME / LLM_CODE_MODEL / LLM_CODE_PLAN_MODEL，并 export
# ANTHROPIC_* 兼容变量。返回 0 成功 / 1 失败（未知平台 / API Key 为占位符）。
configure_platform() {
    local platform="${1:-${LLM_PLATFORM:-agnes}}"
    LLM_PLATFORM="${platform}"
    export LLM_PLATFORM

    local prefix def_base def_model extra_key extra_def=""
    extra_key=""
    if ! _resolve_llm_platform_vars "${platform}" prefix def_base def_model extra_key extra_def; then
        error "未知大模型平台: '${platform}'（支持: agnes | deepseek | glm | ark | bailian）"
        return 1
    fi

    local api_key="${prefix}_API_KEY"
    local base_url="${prefix}_BASE_URL"
    local model="${prefix}_MODEL"

    # bash 3 兼容：${!var} 间接展开，bash 3 也支持
    local _ak _au _am
    eval "_ak=\"\${${api_key}:-}\""
    eval "_au=\"\${${base_url}:-}\""
    eval "_am=\"\${${model}:-}\""

    if [ -z "${_ak}" ] || [[ "${_ak}" == your-* ]] || [ "${_ak}" = "change-me" ]; then
        error "${prefix}_API_KEY 未设置或仍为占位符，请检查 .env"
        return 1
    fi

    # 用 eval 写默认回退（bash 3 兼容）
    eval "LLM_API_KEY=\"\${${api_key}}\""
    if [ -n "${_au}" ]; then
        eval "LLM_BASE_URL=\"\${${base_url}}\""
    else
        eval "LLM_BASE_URL=\"\${${base_url}:-${def_base}}\""
    fi
    if [ -n "${_am}" ]; then
        eval "LLM_MODEL=\"\${${model}}\""
    else
        eval "LLM_MODEL=\"\${${model}:-${def_model}}\""
    fi
    export LLM_API_KEY
    export LLM_BASE_URL
    export LLM_MODEL
    export LLM_PLATFORM_NAME="$(_llm_platform_display_name "${platform}")"

    # 可选字段（仅部分平台有 DEEPSEEK_CODE_MODEL / ARK_CODE_PLAN_MODEL）
    if [ -n "${extra_key}" ]; then
        eval "_cv=\"\${${extra_key}:-${extra_def}}\""
        LLM_CODE_MODEL="${_cv}"
        LLM_CODE_PLAN_MODEL="${_cv}"
    else
        LLM_CODE_MODEL=""
        LLM_CODE_PLAN_MODEL=""
    fi
    export LLM_CODE_MODEL
    export LLM_CODE_PLAN_MODEL

    # ANTHROPIC_* 兼容变量（Claude Code 通过这些环境变量连 litellm）
    export ANTHROPIC_BASE_URL="${LLM_BASE_URL}"
    export ANTHROPIC_API_KEY="${LLM_API_KEY}"
    export ANTHROPIC_MODEL="${LLM_MODEL}"

    return 0
}

# 检查平台 API Key 是否已真实配置（占位符视为未配置）。返回 0 / 1。
validate_config() {
    local platform="${1:-${LLM_PLATFORM:-agnes}}"
    case "${platform}" in
        agnes)    [ -n "${AGNES_API_KEY:-}" ]    && [ "${AGNES_API_KEY}" != "your-agnes-api-key" ] ;;
        deepseek) [ -n "${DEEPSEEK_API_KEY:-}" ] && [ "${DEEPSEEK_API_KEY}" != "your-deepseek-api-key" ] ;;
        glm)      [ -n "${GLM_API_KEY:-}" ]      && [ "${GLM_API_KEY}" != "your-glm-api-key" ] ;;
        ark)      [ -n "${ARK_API_KEY:-}" ]      && [ "${ARK_API_KEY}" != "your-ark-api-key" ] ;;
        bailian)  [ -n "${BAILIAN_API_KEY:-}" ]  && [ "${BAILIAN_API_KEY}" != "your-bailian-api-key" ] ;;
        *)        return 1 ;;
    esac
}

# 平台中文显示名（不依赖外部脚本）
_llm_platform_display_name() {
    case "$1" in
        agnes)    echo "Agnes AI" ;;
        deepseek) echo "DeepSeek" ;;
        glm)      echo "GLM（智谱）" ;;
        ark)      echo "火山方舟（ARK）" ;;
        bailian)  echo "百炼（DashScope）" ;;
        *)        echo "$1" ;;
    esac
}
