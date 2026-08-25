#!/bin/bash
set -e

# ============================================================
# DevPilot - 远程 Docker 部署脚本
# 功能：通过 DOCKER_HOST 连接远程 Docker 守护进程进行部署
# 支持两种模式：
#   1) docker compose 远程部署（默认）
#   2) docker run 远程部署（通过 --run 参数切换）
#
# 支持三种 DOCKER_HOST 连接方式：
#   - tcp://remote:2375         （明文 TCP，仅限内网/信任网络）
#   - ssh://user@remote         （SSH 通道，推荐）
#   - SSH 隧道模式（--ssh-tunnel，本地端口转发远程 Docker API）
#
# 用法：
#   ./cicd/cd/docker-remote/deploy-remote.sh                    # 使用 docker compose 远程部署
#   ./cicd/cd/docker-remote/deploy-remote.sh --run             # 使用 docker run 远程部署
#   ./cicd/cd/docker-remote/deploy-remote.sh --ssh-tunnel       # 通过 SSH 隧道连接远程 Docker
#   ./cicd/cd/docker-remote/deploy-remote.sh --host ssh://user@remote
#   ./cicd/cd/docker-remote/deploy-remote.sh --host tcp://remote:2375
#
# 配置：修改 docker-remote.conf 或通过环境变量 DOCKER_HOST 指定
# ============================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/common.sh"

trap 'error "远程部署过程中发生错误，行号: $LINENO"' ERR

# ============================================================
# 1. 解析命令行参数
# ============================================================
DEPLOY_MODE="compose"   # 默认使用 docker compose
SSH_TUNNEL="false"      # 默认不使用 SSH 隧道
CUSTOM_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)
            DEPLOY_MODE="run"
            shift
            ;;
        --ssh-tunnel)
            SSH_TUNNEL="true"
            shift
            ;;
        --host)
            CUSTOM_HOST="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: deploy-remote.sh [--run] [--ssh-tunnel] [--host <DOCKER_HOST>]"
            echo ""
            echo "选项:"
            echo "  --run          使用 docker run 模式（默认使用 docker compose）"
            echo "  --ssh-tunnel   通过 SSH 隧道连接远程 Docker API"
            echo "  --host <H>     指定 DOCKER_HOST（如 ssh://user@remote 或 tcp://remote:2375）"
            echo "  --help         显示帮助信息"
            exit 0
            ;;
        *)
            error "未知参数: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# ============================================================
# 2. 定位项目根目录与配置文件
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

info "项目根目录: ${PROJECT_ROOT}"
cd "${PROJECT_ROOT}"

# ---- 加载 .env 文件 ----
ENV_FILE="${PROJECT_ROOT}/.env"
info "加载环境变量: ${ENV_FILE}"
load_env "${ENV_FILE}" || exit 1

# ---- 加载远程配置文件（如果存在） ----
REMOTE_CONF="${SCRIPT_DIR}/docker-remote.conf"
if [ -f "${REMOTE_CONF}" ]; then
    info "加载远程配置: ${REMOTE_CONF}"
    set -a
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        export "$line"
    done < "${REMOTE_CONF}"
    set +a
fi

# ---- 校验关键变量 ----
validate_devpilot_env || exit 1
success "环境变量校验通过"

# ============================================================
# 3. 确定 DOCKER_HOST
# ============================================================
# 优先级：命令行参数 > 环境变量 > 配置文件中的 REMOTE_DOCKER_HOST
if [ -n "${CUSTOM_HOST}" ]; then
    export DOCKER_HOST="${CUSTOM_HOST}"
elif [ -z "${DOCKER_HOST:-}" ] && [ -n "${REMOTE_DOCKER_HOST:-}" ]; then
    export DOCKER_HOST="${REMOTE_DOCKER_HOST}"
fi

# SSH 隧道模式：建立本地端口转发到远程 Docker API
SSH_TUNNEL_PID=""
if [ "${SSH_TUNNEL}" = "true" ]; then
    # SSH 隧道需要 SSH 连接信息
    SSH_USER="${REMOTE_SSH_USER:-root}"
    SSH_HOST="${REMOTE_SSH_HOST:-}"
    SSH_PORT="${REMOTE_SSH_PORT:-22}"
    REMOTE_DOCKER_PORT="${REMOTE_DOCKER_PORT:-2375}"
    LOCAL_FORWARD_PORT="${LOCAL_FORWARD_PORT:-23750}"

    if [ -z "${SSH_HOST}" ]; then
        error "SSH 隧道模式需要 REMOTE_SSH_HOST（在 docker-remote.conf 中配置）"
        exit 1
    fi

    info "建立 SSH 隧道: localhost:${LOCAL_FORWARD_PORT} -> ${SSH_HOST}:${REMOTE_DOCKER_PORT}"

    # 建立 SSH 隧道（后台运行）
    ssh -f -N -L "${LOCAL_FORWARD_PORT}:127.0.0.1:${REMOTE_DOCKER_PORT}" \
        -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=60

    # 记录隧道 PID（用于退出时关闭）
    SSH_TUNNEL_PID=$(pgrep -f "ssh.*${LOCAL_FORWARD_PORT}:127.0.0.1:${REMOTE_DOCKER_PORT}" | head -1)

    # 设置 DOCKER_HOST 指向本地转发端口
    export DOCKER_HOST="tcp://localhost:${LOCAL_FORWARD_PORT}"
    success "SSH 隧道已建立 (PID: ${SSH_TUNNEL_PID})"

    # 退出时自动关闭隧道
    cleanup_tunnel() {
        if [ -n "${SSH_TUNNEL_PID}" ]; then
            info "关闭 SSH 隧道 ..."
            kill "${SSH_TUNNEL_PID}" 2>/dev/null || true
        fi
    }
    trap cleanup_tunnel EXIT
fi

# 如果仍未设置 DOCKER_HOST，给出提示并退出
if [ -z "${DOCKER_HOST:-}" ]; then
    error "未设置 DOCKER_HOST，请通过以下方式之一指定远程 Docker 地址："
    error "  1) 环境变量: export DOCKER_HOST=ssh://user@remote"
    error "  2) 命令行:   ./deploy-remote.sh --host ssh://user@remote"
    error "  3) 配置文件: 在 docker-remote.conf 中设置 REMOTE_DOCKER_HOST"
    error "  4) SSH 隧道: ./deploy-remote.sh --ssh-tunnel（需配置 REMOTE_SSH_HOST）"
    exit 1
fi

info "远程 Docker 地址: ${DOCKER_HOST}"

# ============================================================
# 4. 检查远程 Docker 连接
# ============================================================
info "测试远程 Docker 连接 ..."
if ! docker version --format '{{.Server.Version}}' &>/dev/null; then
    error "无法连接远程 Docker: ${DOCKER_HOST}"
    error "请检查："
    error "  - 远程 Docker 守护进程是否运行（systemctl status docker）"
    error "  - 端口 2375 是否开放（TCP 模式需配置 Docker 监听）"
    error "  - SSH 密钥是否已配置（SSH 模式需免密登录）"
    error "  - 防火墙是否放行对应端口"
    exit 1
fi

REMOTE_DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
REMOTE_OS=$(docker version --format '{{.Server.Os}}' 2>/dev/null)
REMOTE_ARCH=$(docker version --format '{{.Server.Arch}}' 2>/dev/null)
success "远程 Docker 连接成功（版本: ${REMOTE_DOCKER_VERSION}, OS: ${REMOTE_OS}, 架构: ${REMOTE_ARCH}）"

# ============================================================
# 5. 检查远程是否有 docker compose
# ============================================================
if [ "${DEPLOY_MODE}" = "compose" ]; then
    info "检查远程 Docker Compose 支持 ..."
    if ! docker compose version &>/dev/null; then
        warn "远程 Docker 不支持 compose 子命令"
        warn "切换为 docker run 模式"
        DEPLOY_MODE="run"
    else
        success "远程 Docker Compose 可用"
    fi
fi

# ============================================================
# 6A. Docker Compose 远程部署模式
# ============================================================
if [ "${DEPLOY_MODE}" = "compose" ]; then
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  远程部署模式：Docker Compose${NC}"
    echo -e "${CYAN}  目标: ${DOCKER_HOST}${NC}"
    echo -e "${CYAN}========================================${NC}"

    # 远程部署需要将项目文件传输到远程主机
    # 使用 docker compose 的上下文构建功能
    info "在远程构建并启动服务 ..."

    # 设置 DOCKER_HOST 后，docker compose 命令会自动使用远程 Docker
    # 但构建上下文文件需要在本地打包后传输
    # docker compose 默认会将构建上下文发送到远程 Docker daemon

    # 创建远程目录结构（通过容器命令在远程创建）
    info "在远程主机创建数据目录 ..."
    # 使用一个临时容器创建目录（挂载宿主机路径）
    docker run --rm -v /:/host alpine sh -c "
        mkdir -p /host/data/redis /host/data/openclaw /host/data/devpilot-claude
        mkdir -p /host/logs/redis /host/logs/openclaw /host/logs/devpilot-claude
        mkdir -p /host/workspace
        touch /host/workspace/.gitkeep
    " 2>/dev/null || warn "远程目录创建可能需要手动执行（权限问题）"

    # 构建并启动（上下文通过 Docker API 传输到远程）
    info "远程构建镜像并启动容器 ..."
    export DOCKER_BUILDKIT=1
    docker compose up -d --build

    success "远程服务已启动"

# ============================================================
# 6B. Docker Run 远程部署模式
# ============================================================
else
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  远程部署模式：Docker Run${NC}"
    echo -e "${CYAN}  目标: ${DOCKER_HOST}${NC}"
    echo -e "${CYAN}========================================${NC}"

    NETWORK_NAME="devpilot-network"

    # 创建远程网络
    info "在远程创建 Docker 网络 ..."
    ensure_docker_network "${NETWORK_NAME}"

    # 构建远程镜像（上下文自动传输）
    info "在远程构建 OpenClaw 镜像 ..."
    export DOCKER_BUILDKIT=1
    docker build \
        --build-arg "OPENCLAW_VERSION=${OPENCLAW_VERSION}" \
        --build-arg "NODE_IMAGE_TAG=${NODE_IMAGE_TAG}" \
        -t devpilot-openclaw:latest \
        -f dockerfiles/openclaw/Dockerfile \
        .
    success "OpenClaw 镜像远程构建完成"

    info "在远程构建 CC-Switch+Claude 镜像 ..."
    docker build \
        --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
        --build-arg "NODE_IMAGE_TAG=${NODE_IMAGE_TAG}" \
        -t devpilot-claude:latest \
        -f dockerfiles/claude/Dockerfile \
        .
    success "CC-Switch+Claude 镜像远程构建完成"

    # 清理旧容器（幂等）
    info "清理远程旧容器 ..."
    remove_container_if_exists "devpilot-redis"
    remove_container_if_exists "devpilot-openclaw"
    remove_container_if_exists "devpilot-claude"
    success "远程旧容器清理完成"

    # 启动 Redis
    info "远程启动 Redis 容器 ..."
    docker run -d \
        --name devpilot-redis \
        --restart unless-stopped \
        --network "${NETWORK_NAME}" \
        --network-alias redis \
        -e "TZ=${TZ}" \
        redis:8.8.1-alpine \
        sh -c "redis-server --requirepass '${REDIS_PASSWORD}' --appendonly yes --save 60 10000 --maxmemory 512mb --maxmemory-policy allkeys-lru"
    success "远程 Redis 容器已启动"

    # 启动 OpenClaw
    info "远程启动 OpenClaw 容器 ..."
    docker run -d \
        --name devpilot-openclaw \
        --restart unless-stopped \
        --network "${NETWORK_NAME}" \
        --network-alias openclaw \
        -e "TZ=${TZ}" \
        -e "AGNES_API_KEY=${AGNES_API_KEY}" \
        -e "AGNES_BASE_URL=${AGNES_BASE_URL}" \
        -e "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" \
        -e "OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}" \
        -e "FEISHU_APP_ID=${FEISHU_APP_ID}" \
        -e "FEISHU_APP_SECRET=${FEISHU_APP_SECRET}" \
        -e "REDIS_PASSWORD=${REDIS_PASSWORD}" \
        -p "${OPENCLAW_GATEWAY_PORT}:18789" \
        devpilot-openclaw:latest
    success "远程 OpenClaw 容器已启动"

    # 启动 CC-Switch + Claude Code
    info "远程启动 CC-Switch+Claude 容器 ..."
    AGNES_MODEL_VALUE="${AGNES_MODEL_FLASH:-agnes-2.5-flash}"
    docker run -d \
        --name devpilot-claude \
        --restart unless-stopped \
        --network "${NETWORK_NAME}" \
        --network-alias devpilot-claude \
        -e "TZ=${TZ}" \
        -e "HOME=/home/node" \
        -e "HOST=0.0.0.0" \
        -e "AGNES_BASE_URL=${AGNES_BASE_URL}" \
        -e "AGNES_API_KEY=${AGNES_API_KEY}" \
        -e "ANTHROPIC_BASE_URL=${AGNES_BASE_URL}" \
        -e "ANTHROPIC_API_KEY=${AGNES_API_KEY}" \
        -e "ANTHROPIC_MODEL=${AGNES_MODEL_VALUE}" \
        -e "DEVPILOT_AUTO_DEPLOY=${DEVPILOT_AUTO_DEPLOY:-false}" \
        -i -t \
        devpilot-claude:latest
    success "远程 CC-Switch+Claude 容器已启动"
fi

# ============================================================
# 7. 远程健康检查
# ============================================================
echo ""
info "远程健康检查 ..."
sleep 5

# Redis 健康检查
wait_for_redis "devpilot-redis" "${REDIS_PASSWORD}" || true

# OpenClaw 健康检查
wait_for_container_http "devpilot-openclaw" "18789" "/healthz" 40 3 || true

# devpilot-claude 容器健康检查（Claude Code + LiteLLM 路由）

# ============================================================
# 8. 输出部署结果
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  远程部署完成！${NC}"
echo -e "${GREEN}  目标: ${DOCKER_HOST}${NC}"
echo -e "${GREEN}  模式: ${DEPLOY_MODE}${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

info "远程容器状态："
docker ps --filter "name=devpilot-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
# 提取远程主机地址用于显示访问链接
REMOTE_ADDR=$(echo "${DOCKER_HOST}" | sed 's|.*://||; s|/.*||; s|:.*||')
echo -e "${CYAN}远程访问地址（替换为实际远程 IP）：${NC}"
echo -e "  OpenClaw Gateway:  http://${REMOTE_ADDR}:${OPENCLAW_GATEWAY_PORT}/healthz"
echo -e "  Claude Code:       docker exec -it devpilot-claude claude"
    echo -e "  litellm 代理:      http://${REMOTE_ADDR}:4000/health/liveliness"
echo ""
echo -e "${CYAN}注意：${NC}"
echo -e "  - 远程部署不挂载本地 conf 目录（redis.conf 等），Redis 使用命令行参数配置"
echo -e "  - 如需远程持久化数据，请在远程主机手动创建 data/ logs/ 目录并挂载"
echo -e "  - 确保远程防火墙开放 ${OPENCLAW_GATEWAY_PORT} 和 4000 (litellm) 端口"
echo ""
