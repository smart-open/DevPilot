#!/bin/bash
set -e

# ============================================================
# DevPilot 一键部署脚本
# 功能：环境检查、目录创建、配置验证、构建启动、健康检查
# 用法: ./deploy.sh
# ============================================================

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- 项目根目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

echo "========================================"
echo "  DevPilot 一键部署"
echo "========================================"
echo ""

# ============================================================
# 1. 环境检查
# ============================================================
info "检查运行环境..."

# Docker
if ! command -v docker &>/dev/null; then
    err "Docker 未安装，请先安装 Docker Engine 24.0+"
    err "安装指南: https://docs.docker.com/engine/install/"
    exit 1
fi
DOCKER_VERSION=$(docker --version | grep -oP 'Docker version \K[0-9]+\.[0-9]+')
ok "Docker 版本: $(docker --version | awk '{print $3}' | tr -d ',')"

# Docker Compose
if ! docker compose version &>/dev/null; then
    err "Docker Compose v2 未安装"
    err "请安装 Docker Compose v2.20+"
    exit 1
fi
ok "Docker Compose: $(docker compose version --short)"

# Docker 守护进程
if ! docker info &>/dev/null; then
    err "Docker 守护进程未运行，请启动 Docker"
    exit 1
fi
ok "Docker 守护进程运行中"

# Make (可选)
if command -v make &>/dev/null; then
    ok "Make 已安装（可用 make 命令）"
else
    warn "Make 未安装（可选，安装后可用 make 命令快捷操作）"
fi

echo ""

# ============================================================
# 2. 创建必要目录
# ============================================================
info "创建数据目录..."

mkdir -p data/redis data/openclaw data/cc-switch-claude
mkdir -p logs/redis logs/openclaw logs/cc-switch-claude
mkdir -p workspace
mkdir -p backups

# workspace 目录添加 .gitkeep
touch workspace/.gitkeep

ok "目录结构已创建"

echo ""

# ============================================================
# 3. 检查 .env 文件
# ============================================================
info "检查环境变量配置..."

if [ ! -f ".env" ]; then
    # 尝试使用配置向导
    if [ -f "./init.sh" ]; then
        warn ".env 文件不存在，启动配置向导..."
        echo ""
        bash ./init.sh
        # 向导执行后如果 .env 仍不存在，退出
        if [ ! -f ".env" ]; then
            err "配置未完成，请重新运行 ./deploy.sh"
            exit 1
        fi
    elif [ -f ".env.example" ]; then
        warn ".env 文件不存在，从模板创建..."
        cp .env.example .env
        # 自动生成密码
        AUTO_REDIS_PASS=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n')
        AUTO_TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n')
        sed -i.bak \
            -e "s|REDIS_PASSWORD=change-me-to-strong-password|REDIS_PASSWORD=${AUTO_REDIS_PASS}|" \
            -e "s|OPENCLAW_GATEWAY_TOKEN=change-me-to-secure-token|OPENCLAW_GATEWAY_TOKEN=${AUTO_TOKEN}|" \
            .env
        rm -f .env.bak
        ok "已自动生成 Redis 密码和 Gateway Token"
        warn "请编辑 .env 文件填入 agnes-ai API Key 和飞书凭证"
        echo ""
        echo "  vim .env"
        echo ""
        exit 0
    else
        err ".env 文件、init.sh 和 .env.example 都不存在"
        exit 1
    fi
fi

# 检查必需的环境变量
ENV_ERRORS=0
check_env() {
    local var_name="$1"
    local var_desc="$2"
    local var_value=$(grep "^${var_name}=" .env 2>/dev/null | cut -d'=' -f2-)
    if [ -z "${var_value}" ] || [ "${var_value}" = "your-agnes-api-key" ] || [ "${var_value}" = "your-feishu-app-id" ] || [ "${var_value}" = "your-feishu-app-secret" ] || [ "${var_value}" = "change-me-to-strong-password" ] || [ "${var_value}" = "change-me-to-secure-token" ]; then
        err "${var_desc} 未配置（${var_name}）"
        ENV_ERRORS=$((ENV_ERRORS + 1))
    fi
}

check_env "AGNES_API_KEY"          "agnes-ai API Key"
check_env "AGNES_BASE_URL"         "agnes-ai API 地址"
check_env "FEISHU_APP_ID"          "飞书 App ID"
check_env "FEISHU_APP_SECRET"      "飞书 App Secret"

# 密码类：如果仍是占位符，自动生成
auto_fix_password() {
    local var_name="$1"
    local var_desc="$2"
    local var_value=$(grep "^${var_name}=" .env 2>/dev/null | cut -d'=' -f2-)
    if [ -z "${var_value}" ] || [ "${var_value}" = "change-me-to-strong-password" ] || [ "${var_value}" = "change-me-to-secure-token" ]; then
        local new_pass=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n')
        sed -i.bak "s|^${var_name}=.*|${var_name}=${new_pass}|" .env
        rm -f .env.bak
        ok "已自动生成 ${var_desc}"
    fi
}

auto_fix_password "REDIS_PASSWORD"         "Redis 密码"
auto_fix_password "OPENCLAW_GATEWAY_TOKEN" "OpenClaw Gateway Token"

if [ ${ENV_ERRORS} -gt 0 ]; then
    echo ""
    err "有 ${ENV_ERRORS} 个必需变量未配置，请编辑 .env 文件"
    echo ""
    echo "  vim .env"
    echo "  或运行配置向导: ./init.sh"
    echo ""
    exit 1
fi

ok ".env 配置检查通过"

echo ""

# ============================================================
# 4. 构建并启动
# ============================================================
info "构建并启动服务（首次构建需 5-10 分钟）..."
echo ""

docker compose up -d --build 2>&1 | while read line; do
    echo "  ${line}"
done

echo ""

# ============================================================
# 5. 等待健康检查
# ============================================================
info "等待服务就绪..."

GATEWAY_PORT=$(grep "^OPENCLAW_GATEWAY_PORT=" .env | cut -d'=' -f2)
WEB_PORT=$(grep "^CC_SWITCH_WEB_PORT=" .env | cut -d'=' -f2)
REDIS_PASS=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)

MAX_WAIT=90
WAITED=0

# Redis
while [ ${WAITED} -lt ${MAX_WAIT} ]; do
    if docker compose exec -T redis redis-cli -a "${REDIS_PASS}" ping 2>/dev/null | grep -q PONG; then
        ok "Redis 就绪"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done
if [ ${WAITED} -ge ${MAX_WAIT} ]; then
    warn "Redis 未就绪（可能仍在初始化）"
fi

# OpenClaw
WAITED=0
while [ ${WAITED} -lt ${MAX_WAIT} ]; do
    if curl -sf "http://localhost:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then
        ok "OpenClaw 就绪"
        break
    fi
    sleep 3
    WAITED=$((WAITED + 3))
done
if [ ${WAITED} -ge ${MAX_WAIT} ]; then
    warn "OpenClaw 未就绪（查看日志: docker compose logs openclaw）"
fi

# CC-Switch Web
WAITED=0
while [ ${WAITED} -lt ${MAX_WAIT} ]; do
    if curl -sf "http://localhost:${WEB_PORT}" >/dev/null 2>&1; then
        ok "CC-Switch Web 就绪"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done
if [ ${WAITED} -ge ${MAX_WAIT} ]; then
    warn "CC-Switch Web 未就绪（查看日志: docker compose logs cc-switch-claude）"
fi

echo ""

# ============================================================
# 6. 打印状态
# ============================================================
echo "========================================"
ok "部署完成"
echo "========================================"
echo ""
echo "${CYAN}服务地址:${NC}"
echo "  Redis:        容器内部 :6379"
echo "  OpenClaw:     http://localhost:${GATEWAY_PORT}"
echo "  CC-Switch:    http://localhost:${WEB_PORT}"
echo ""
echo "${CYAN}常用命令:${NC}"
echo "  进入 Claude Code:   docker compose exec cc-switch-claude claude"
echo "  查看日志:          docker compose logs -f"
echo "  查看状态:          docker compose ps"
echo "  健康检查:          make health"
echo ""
echo "${CYAN}飞书机器人:${NC}"
echo "  在飞书中搜索并添加你的机器人，发送消息即可获得 AI 回复"
echo ""
echo "${CYAN}CC-Switch 配置:${NC}"
echo "  1. 浏览器打开 http://localhost:${WEB_PORT}"
echo "  2. 添加 agnes-ai 供应商（API Key 在 .env 文件中）"
echo "  3. 启用 Claude Code takeover"
echo ""
echo "========================================"
