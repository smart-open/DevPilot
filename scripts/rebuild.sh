#!/bin/bash
# ============================================================
# DevPilot 全量清空重建脚本
#
# 用途：在一个全新环境或需要彻底重建时，按以下流程重置整个栈：
#   1. 加载 versions.env + .env
#   2. git pull 同步最新代码
#   3. docker compose down 停掉所有容器
#   4. 数据目录迁移（旧名 cc-switch-claude -> 新名 devpilot-claude-litellm）
#   5. 清理旧容器/卷/镜像残留
#   6. （可选）清空 data/ 与 logs/
#   7. docker compose build --no-cache 无缓存重建所有镜像
#   8. docker compose up -d 启动
#   9. 端到端验证（litellm 健康 / 模型注册 / Claude Code 配置）
#
# 保留：项目根目录的 .env（API Key / 密码不会丢）
# 清掉：data/ 下的 openclaw 配置、cc-switch-claude 数据、redis dump 等
#       logs/ 下的所有容器日志
# ============================================================

set -e

# 颜色（无 tty 时降级为纯文本）
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

# ---- 切到仓库根目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(get_project_root)"
cd "$PROJECT_ROOT"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  DevPilot 全量清空重建${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  工作目录: ${PROJECT_ROOT}"
echo ""

# ---- 1. 加载 versions.env ----
echo -e "${GREEN}[1/8]${NC} 加载 versions.env..."
if [ ! -f versions.env ]; then
    echo -e "${RED}  错误：versions.env 不存在，请在 DevPilot 仓库根目录运行${NC}"
    exit 1
fi
set -a
source versions.env
set +a
echo -e "  ✓ NODE=${NODE_IMAGE_TAG} OPENCLAW=${OPENCLAW_VERSION} CLAUDE_CODE=${CLAUDE_CODE_VERSION} LITELLM=${LITELLM_VERSION}"

# ---- 2. 校验 .env ----
echo -e "${GREEN}[2/8]${NC} 校验 .env..."
if [ ! -f .env ]; then
    echo -e "${RED}  错误：.env 不存在，请先执行 cp .env.example .env 并填入 API Key${NC}"
    exit 1
fi
set -a
source .env
set +a
if [ -z "${LLM_PLATFORM:-}" ]; then
    echo -e "${RED}  错误：.env 中 LLM_PLATFORM 未设置${NC}"
    exit 1
fi
# 检查激活平台的 API Key
ACTIVE_KEY_VAR="${LLM_PLATFORM^^}_API_KEY"
ACTIVE_KEY="${!ACTIVE_KEY_VAR:-}"
if [ -z "$ACTIVE_KEY" ] || [[ "$ACTIVE_KEY" == your-* ]] || [[ "$ACTIVE_KEY" == change-me* ]]; then
    echo -e "${RED}  错误：${LLM_PLATFORM} 平台的 ${ACTIVE_KEY_VAR} 未正确配置（仍为占位符）${NC}"
    exit 1
fi
echo -e "  ✓ LLM_PLATFORM=${LLM_PLATFORM} (${ACTIVE_KEY_VAR} 已配置)"

# ---- 3. Git 同步 ----
echo -e "${GREEN}[3/8]${NC} 同步代码..."
if [ -d .git ]; then
    if git pull --rebase --autostash 2>&1 | tail -3; then
        echo -e "  ✓ HEAD: $(git rev-parse --short HEAD)"
    else
        echo -e "${YELLOW}  git pull 有冲突，请手动处理后重跑${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}  非 git 仓库，跳过 pull${NC}"
fi

# ---- 4. 停止现有容器 ----
echo -e "${GREEN}[4/8]${NC} 停止并删除现有容器 + 网络..."
docker compose down -v 2>&1 | tail -5 || true

# ---- 5. 数据目录迁移 + 残留清理 ----
echo -e "${GREEN}[5/8]${NC} 数据目录迁移与残留清理..."
if [ -d data/cc-switch-claude ] && [ ! -d data/devpilot-claude ]; then
    mv data/cc-switch-claude data/devpilot-claude
    echo -e "  ✓ data/cc-switch-claude -> data/devpilot-claude (一次性迁移)"
elif [ -d data/cc-switch-claude ] && [ -d data/devpilot-claude ]; then
    echo -e "${YELLOW}  data/cc-switch-claude 与 data/devpilot-claude 同时存在，请人工处理（合并后保留 devpilot-claude-litellm）${NC}"
fi
if [ -d logs/cc-switch-claude ] && [ ! -d logs/devpilot-claude ]; then
    mv logs/cc-switch-claude logs/devpilot-claude
    echo -e "  ✓ logs/cc-switch-claude -> logs/devpilot-claude"
fi
# 清理旧容器卷
docker volume ls -q 2>/dev/null | grep -E "cc-switch-claude" | xargs -r docker volume rm 2>/dev/null || true
# 清理旧镜像
docker images -q devpilot-cc-switch-claude 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
docker images -q 'cc-switch-web' 2>/dev/null | xargs -r docker rmi -f 2>/dev/null || true
echo -e "  ✓ 旧卷/镜像清理完成"

# ---- 6. 数据清空确认 ----
echo -e "${GREEN}[6/8]${NC} 数据目录..."
read -rp "  是否清空 data/ 与 logs/ 下所有持久化数据（OpenClaw 配置 / Claude Code 设置 / Redis dump / 日志）？[y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -rf data/* logs/*
    echo -e "  ✓ data/ 与 logs/ 已清空（下次启动将由 init 脚本自动重新生成配置）"
else
    echo -e "  保留现有数据"
fi

# ---- 7. 无缓存重建 ----
echo -e "${GREEN}[7/8]${NC} 无缓存重建镜像（devpilot-claude-litellm / openclaw）..."
docker compose build --no-cache devpilot-claude-litellm openclaw 2>&1 | tail -15

# ---- 8. 启动 + 验证 ----
echo -e "${GREEN}[8/8]${NC} 启动服务..."
docker compose up -d
echo ""
echo -e "${CYAN}等待服务就绪（约 30 秒）...${NC}"
sleep 30

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  验证${NC}"
echo -e "${CYAN}========================================${NC}"

echo -e "${GREEN}▶ 容器状态：${NC}"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || docker compose ps

echo ""
echo -e "${GREEN}▶ litellm 健康检查：${NC}"
curl -s -o /dev/null -w "  GET /health/liveliness -> HTTP %{http_code}\n" http://localhost:4000/health/liveliness

echo ""
echo -e "${GREEN}▶ litellm 注册的模型：${NC}"
docker exec devpilot-claude-litellm cat /opt/litellm/litellm_config.yaml 2>/dev/null | grep -E "model_name:" | sed 's/^/  /' || echo "  (无法读取)"

echo ""
echo -e "${GREEN}▶ Claude Code 配置：${NC}"
docker compose exec -T devpilot-claude-litellm sh -c 'cat /home/node/.claude/settings.json 2>/dev/null' 2>/dev/null | sed 's/^/  /' || echo "  (无法读取)"

echo ""
echo -e "${GREEN}▶ Claude Code 版本：${NC}"
docker compose exec -T devpilot-claude-litellm claude --version 2>/dev/null | sed 's/^/  /' || echo "  (无法读取)"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}  重建完成！${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "  常用命令："
echo -e "    ${YELLOW}docker compose exec devpilot-claude-litellm claude \"你是谁\"${NC}    # 端到端测试"
echo -e "    ${YELLOW}docker compose logs -f devpilot-claude-litellm${NC}  # 实时日志"
echo -e "    ${YELLOW}make health${NC}                                              # 健康检查"
echo -e "    ${YELLOW}docker compose restart devpilot-claude-litellm${NC}                  # 仅重启 Claude 容器"
echo -e "    ${YELLOW}docker compose restart devpilot-claude-litellm${NC}                 # 仅重启 litellm 代理"
