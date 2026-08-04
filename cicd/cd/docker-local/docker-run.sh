#!/bin/bash
set -e

# ============================================================
# DevPilot - 本地 Docker Run 部署脚本（不依赖 docker compose）
# 功能：使用 docker run 命令逐个启动 3 个容器
# 用法：./cicd/cd/docker-local/docker-run.sh
# 依赖：Docker Engine 24+
#
# 与 deploy.sh 的区别：
#   - deploy.sh 使用 docker compose 编排（推荐）
#   - docker-run.sh 使用原生 docker run 命令（适用于无 compose 的环境）
# ============================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/common.sh"

# ---- 错误处理 ----
trap 'error "部署过程中发生错误，行号: $LINENO"' ERR

# ============================================================
# 1. 定位项目根目录与 .env 文件
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

info "项目根目录: ${PROJECT_ROOT}"
cd "${PROJECT_ROOT}"

# ---- 加载 .env 文件 ----
ENV_FILE="${PROJECT_ROOT}/.env"
info "加载环境变量: ${ENV_FILE}"
load_env "${ENV_FILE}" || exit 1

# ---- 校验关键变量 ----
validate_devpilot_env || exit 1
success "环境变量校验通过"

# ============================================================
# 2. 检查 Docker 环境
# ============================================================
info "检查 Docker 环境 ..."
if ! command -v docker &>/dev/null; then
    error "未安装 Docker，请先安装 Docker Engine 24+"
    exit 1
fi
if ! docker info &>/dev/null; then
    error "Docker 守护进程未运行，请启动 Docker 服务"
    exit 1
fi
success "Docker 环境正常"

# ============================================================
# 3. 创建必要目录（幂等）
# ============================================================
info "创建数据、日志和工作空间目录 ..."
create_data_dirs "${PROJECT_ROOT}"
success "目录已就绪"

# ============================================================
# 4. 创建 Docker 网络（幂等）
# ============================================================
NETWORK_NAME="devpilot-network"
info "检查 Docker 网络: ${NETWORK_NAME}"
ensure_docker_network "${NETWORK_NAME}"

# ============================================================
# 5. 构建自建镜像（幂等，仅本地构建）
# ============================================================
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  构建 Docker 镜像${NC}"
echo -e "${CYAN}========================================${NC}"

# 构建参数（与 .env 保持一致）
BUILD_ARGS=(
    --build-arg "NODE_IMAGE_TAG=${NODE_IMAGE_TAG}"
)

info "构建 OpenClaw 镜像 ..."
docker build \
    --build-arg "OPENCLAW_VERSION=${OPENCLAW_VERSION}" \
    --build-arg "NODE_IMAGE_TAG=${NODE_IMAGE_TAG}" \
    -t devpilot-openclaw:latest \
    -t "devpilot-openclaw:${OPENCLAW_VERSION}" \
    -f dockerfiles/openclaw/Dockerfile \
    .
success "OpenClaw 镜像构建完成"

info "构建 CC-Switch+Claude 镜像 ..."
docker build \
    --build-arg "CC_SWITCH_VERSION=${CC_SWITCH_VERSION}" \
    --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
    --build-arg "NODE_IMAGE_TAG=${NODE_IMAGE_TAG}" \
    -t devpilot-cc-switch-claude:latest \
    -t "devpilot-cc-switch-claude:${CC_SWITCH_VERSION}" \
    -f dockerfiles/cc-switch-claude/Dockerfile \
    .
success "CC-Switch+Claude 镜像构建完成"

# ============================================================
# 6. 清理旧容器（幂等：存在则删除后重建）
# ============================================================
info "清理旧容器（如存在） ..."
remove_container_if_exists "devpilot-redis"
remove_container_if_exists "devpilot-openclaw"
remove_container_if_exists "devpilot-cc-switch-claude"
success "旧容器清理完成"

# ============================================================
# 7. 启动 Redis 容器
# ============================================================
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  启动容器 1/3：Redis${NC}"
echo -e "${CYAN}========================================${NC}"
info "启动 Redis 容器 ..."

docker run -d \
    --name devpilot-redis \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    --network-alias redis \
    -e "TZ=${TZ}" \
    -v "${PROJECT_ROOT}/conf/redis/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
    -v "${PROJECT_ROOT}/data/redis:/data" \
    -v "${PROJECT_ROOT}/logs/redis:/logs" \
    redis:8.8.1-alpine \
    sh -c "redis-server /usr/local/etc/redis/redis.conf --requirepass '${REDIS_PASSWORD}'"

success "Redis 容器已启动 (端口 6379，仅内部网络)"

# 等待 Redis 就绪
wait_for_redis "devpilot-redis" "${REDIS_PASSWORD}" || true

# ============================================================
# 8. 启动 OpenClaw 容器
# ============================================================
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  启动容器 2/3：OpenClaw${NC}"
echo -e "${CYAN}========================================${NC}"
info "启动 OpenClaw 容器 ..."

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
    -v "${PROJECT_ROOT}/data/openclaw:/data/openclaw" \
    -v "${PROJECT_ROOT}/logs/openclaw:/logs" \
    -p "${OPENCLAW_GATEWAY_PORT}:18789" \
    devpilot-openclaw:latest

success "OpenClaw 容器已启动 (端口 ${OPENCLAW_GATEWAY_PORT} -> 18789)"

# 等待 OpenClaw 就绪
wait_for_container_http "devpilot-openclaw" "18789" "/healthz" 40 3 || true

# ============================================================
# 9. 启动 CC-Switch + Claude Code 容器
# ============================================================
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  启动容器 3/3：CC-Switch + Claude Code${NC}"
echo -e "${CYAN}========================================${NC}"
info "启动 CC-Switch+Claude 容器 ..."

# 处理可选的 AGNES_MODEL 变量（.env.example 中有 AGNES_MODEL_FLASH）
AGNES_MODEL_VALUE="${AGNES_MODEL_FLASH:-agnes-2.5-flash}"

docker run -d \
    --name devpilot-cc-switch-claude \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    --network-alias cc-switch-claude \
    -e "TZ=${TZ}" \
    -e "HOME=/home/node" \
    -e "PORT=${CC_SWITCH_WEB_PORT}" \
    -e "HOST=0.0.0.0" \
    -e "AGNES_BASE_URL=${AGNES_BASE_URL}" \
    -e "AGNES_API_KEY=${AGNES_API_KEY}" \
    -e "ANTHROPIC_BASE_URL=${AGNES_BASE_URL}" \
    -e "ANTHROPIC_API_KEY=${AGNES_API_KEY}" \
    -e "ANTHROPIC_MODEL=${AGNES_MODEL_VALUE}" \
    -e "DEVPILOT_AUTO_DEPLOY=${DEVPILOT_AUTO_DEPLOY:-false}" \
    -v "${PROJECT_ROOT}/workspace:/workspace" \
    -v "${PROJECT_ROOT}/data/cc-switch-claude:/home/node" \
    -v "${PROJECT_ROOT}/logs/cc-switch-claude:/logs" \
    -p "${CC_SWITCH_WEB_PORT}:${CC_SWITCH_WEB_PORT}" \
    -i -t \
    devpilot-cc-switch-claude:latest

success "CC-Switch+Claude 容器已启动 (端口 ${CC_SWITCH_WEB_PORT})"

# 等待 CC-Switch Web 就绪
wait_for_http "CC-Switch Web" "http://127.0.0.1:${CC_SWITCH_WEB_PORT}" || true

# ============================================================
# 10. 输出部署结果
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署完成！（docker run 模式）${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

info "容器状态："
docker ps --filter "name=devpilot-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo -e "${CYAN}访问地址：${NC}"
echo -e "  OpenClaw Gateway:  http://localhost:${OPENCLAW_GATEWAY_PORT}/healthz"
echo -e "  CC-Switch Web UI: http://localhost:${CC_SWITCH_WEB_PORT}"
echo ""
echo -e "${CYAN}常用命令：${NC}"
echo -e "  查看日志:     docker logs -f devpilot-openclaw"
echo -e "  进入容器:     docker exec -it devpilot-openclaw bash"
echo -e "  使用 Claude:  docker exec -it devpilot-cc-switch-claude claude"
echo -e "  停止容器:     docker stop devpilot-redis devpilot-openclaw devpilot-cc-switch-claude"
echo -e "  删除容器:     docker rm -f devpilot-redis devpilot-openclaw devpilot-cc-switch-claude"
echo ""
