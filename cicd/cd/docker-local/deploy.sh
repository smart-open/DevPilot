#!/bin/bash
set -e

# ============================================================
# DevPilot - 本地 Docker Compose 部署脚本
# 功能：使用 docker compose 在本机一键部署 3 个容器
# 用法：./cicd/cd/docker-local/deploy.sh
# 依赖：Docker Engine 24+、Docker Compose v2.20+
# ============================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/common.sh"

# ---- 错误处理 ----
trap 'error "部署过程中发生错误，行号: $LINENO"' ERR

# ============================================================
# 1. 定位项目根目录与 .env 文件
# ============================================================
# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CI/CD 目录位于项目根目录下的 cicd/，向上回溯两级到项目根目录
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

info "项目根目录: ${PROJECT_ROOT}"

# 切换到项目根目录
cd "${PROJECT_ROOT}"

# ---- 加载 .env 文件 ----
ENV_FILE="${PROJECT_ROOT}/.env"
info "加载环境变量: ${ENV_FILE}"
load_env "${ENV_FILE}" || exit 1

# ---- 校验关键变量是否存在 ----
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

if ! docker compose version &>/dev/null; then
    error "未安装 Docker Compose v2，请安装 Docker Compose v2.20+"
    exit 1
fi

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
success "Docker 版本: ${DOCKER_VERSION}，Compose 版本: ${COMPOSE_VERSION}"

# ============================================================
# 3. 创建必要的目录（幂等操作）
# ============================================================
info "创建数据、日志和工作空间目录 ..."
create_data_dirs "${PROJECT_ROOT}"
success "目录已就绪"

# ============================================================
# 4. 构建并启动服务
# ============================================================
info "开始构建并启动服务（docker compose up -d --build）..."
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  构建 3 个容器：${NC}"
echo -e "${CYAN}  1. Redis (redis:8.8.1-alpine, 端口 6379)${NC}"
echo -e "${CYAN}  2. OpenClaw (端口 ${OPENCLAW_GATEWAY_PORT})${NC}"
echo -e "${CYAN}  3. devpilot-claude (Claude Code 容器)${NC}"
echo -e "${CYAN}========================================${NC}"

# 使用 docker compose 构建（--build 强制重新构建镜像）
docker compose up -d --build

success "所有服务已启动"

# ============================================================
# 5. 等待服务健康就绪
# ============================================================
info "等待服务健康就绪 ..."

wait_for_redis "devpilot-redis" "${REDIS_PASSWORD}" || true
wait_for_container_http "devpilot-openclaw" "18789" "/healthz" 40 3 || true

# ============================================================
# 6. 输出部署状态
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 显示容器状态
info "容器状态："
docker compose ps

echo ""
echo -e "${CYAN}访问地址：${NC}"
echo -e "  OpenClaw Gateway:  http://localhost:${OPENCLAW_GATEWAY_PORT}/healthz"
echo -e "  Claude Code:      docker exec -it devpilot-claude claude"
    echo -e "  litellm 代理:      http://localhost:4000/health/liveliness"
echo ""
echo -e "${CYAN}常用命令：${NC}"
echo -e "  查看日志:     docker compose logs -f"
echo -e "  进入容器:     docker compose exec openclaw bash"
echo -e "  使用 Claude:  docker compose exec devpilot-claude claude"
echo -e "  停止服务:     docker compose down"
echo -e "  重启服务:     docker compose restart"
echo ""
