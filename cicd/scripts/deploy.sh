#!/bin/bash
set -e

# ============================================================
# DevPilot - 统一部署交互脚本
# 功能：交互式选择部署方式，一键部署 DevPilot 环境
# 支持的部署方式：
#   1) 本地 Docker Compose（推荐）
#   2) 本地 Docker Run（不依赖 compose）
#   3) 远程 Docker（通过 DOCKER_HOST 连接远程主机）
#   4) Kubernetes（Helm Chart）
#
# 用法：./cicd/scripts/deploy.sh
#       ./cicd/scripts/deploy.sh --mode compose
#       ./cicd/scripts/deploy.sh --mode run
#       ./cicd/scripts/deploy.sh --mode remote
#       ./cicd/scripts/deploy.sh --mode k8s
# ============================================================

# ---- 加载公共函数库（颜色、日志、env 校验、健康检查等） ----
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

# ============================================================
# 1. 定位项目根目录
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CICD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

info "项目根目录: ${PROJECT_ROOT}"
cd "${PROJECT_ROOT}"

# ============================================================
# 2. 加载并校验 .env 文件
# ============================================================
ENV_FILE="${PROJECT_ROOT}/.env"

info "加载环境变量: ${ENV_FILE}"
load_env "${ENV_FILE}" || exit 1

# ---- 校验关键变量 ----
validate_devpilot_env || exit 1
success "环境变量校验通过"

# ============================================================
# 3. 解析命令行参数（支持非交互模式）
# ============================================================
DEPLOY_MODE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            DEPLOY_MODE="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: deploy.sh [--mode <compose|run|remote|k8s>]"
            echo ""
            echo "选项:"
            echo "  --mode <m>   指定部署模式（不指定则交互式选择）"
            echo "                compose: 本地 Docker Compose"
            echo "                run:     本地 Docker Run"
            echo "                remote:  远程 Docker"
            echo "                k8s:     Kubernetes (Helm Chart)"
            echo "  --help       显示帮助信息"
            exit 0
            ;;
        *)
            error "未知参数: $1"
            exit 1
            ;;
    esac
done

# ============================================================
# 4. 交互式选择部署方式（未指定 --mode 时）
# ============================================================
if [ -z "${DEPLOY_MODE}" ]; then
    print_header "DevPilot 统一部署工具"
    echo -e "  请选择部署方式："
    echo ""
    echo -e "  ${GREEN}1)${NC} 本地 Docker Compose ${CYAN}(推荐)${NC}"
    echo -e "     使用 docker compose 编排启动 3 个容器"
    echo ""
    echo -e "  ${GREEN}2)${NC} 本地 Docker Run"
    echo -e "     使用 docker run 逐个启动容器（不依赖 compose）"
    echo ""
    echo -e "  ${GREEN}3)${NC} 远程 Docker"
    echo -e "     通过 DOCKER_HOST 连接远程 Docker 守护进程部署"
    echo ""
    echo -e "  ${GREEN}4)${NC} Kubernetes (Helm Chart)"
    echo -e "     使用 Helm Chart 部署"
    echo ""
    echo -ne "${YELLOW}请输入选项 (1-4): ${NC}"
    read -r CHOICE

    case "${CHOICE}" in
        1) DEPLOY_MODE="compose" ;;
        2) DEPLOY_MODE="run" ;;
        3) DEPLOY_MODE="remote" ;;
        4) DEPLOY_MODE="k8s" ;;
        *)
            error "无效选项: ${CHOICE}"
            exit 1
            ;;
    esac
fi

info "选择的部署方式: ${DEPLOY_MODE}"

# ============================================================
# 5. 执行部署
# ============================================================
case "${DEPLOY_MODE}" in
    # ---- 1. 本地 Docker Compose ----
    compose)
        info "启动本地 Docker Compose 部署 ..."
        DEPLOY_SCRIPT="${CICD_DIR}/cd/docker-local/deploy.sh"
        if [ ! -f "${DEPLOY_SCRIPT}" ]; then
            error "部署脚本不存在: ${DEPLOY_SCRIPT}"
            exit 1
        fi
        bash "${DEPLOY_SCRIPT}"
        ;;

    # ---- 2. 本地 Docker Run ----
    run)
        info "启动本地 Docker Run 部署 ..."
        DEPLOY_SCRIPT="${CICD_DIR}/cd/docker-local/docker-run.sh"
        if [ ! -f "${DEPLOY_SCRIPT}" ]; then
            error "部署脚本不存在: ${DEPLOY_SCRIPT}"
            exit 1
        fi
        bash "${DEPLOY_SCRIPT}"
        ;;

    # ---- 3. 远程 Docker ----
    remote)
        info "启动远程 Docker 部署 ..."
        DEPLOY_SCRIPT="${CICD_DIR}/cd/docker-remote/deploy-remote.sh"
        if [ ! -f "${DEPLOY_SCRIPT}" ]; then
            error "部署脚本不存在: ${DEPLOY_SCRIPT}"
            exit 1
        fi
        echo ""
        echo -e "${CYAN}远程 Docker 部署需要指定连接方式：${NC}"
        echo -e "  1) TCP 明文:  --host tcp://remote:2375"
        echo -e "  2) SSH 直连:  --host ssh://user@remote"
        echo -e "  3) SSH 隧道:  --ssh-tunnel（需配置 docker-remote.conf）"
        echo ""
        echo -ne "${YELLOW}请输入 DOCKER_HOST（如 ssh://root@192.168.1.100）或留空跳过: ${NC}"
        read -r REMOTE_HOST
        if [ -n "${REMOTE_HOST}" ]; then
            bash "${DEPLOY_SCRIPT}" --host "${REMOTE_HOST}"
        else
            warn "未指定 DOCKER_HOST，尝试使用默认配置 ..."
            bash "${DEPLOY_SCRIPT}"
        fi
        ;;

    # ---- 4. Kubernetes（仅支持 Helm Chart 部署） ----
    k8s)
        info "启动 Kubernetes 部署 ..."

        # 检查 kubectl
        if ! command -v kubectl &>/dev/null; then
            error "未安装 kubectl，请先安装："
            echo -e "  ${CYAN}curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl${NC}"
            exit 1
        fi
        success "kubectl 可用: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

        # 检查集群连接
        if ! kubectl cluster-info &>/dev/null; then
            error "无法连接 Kubernetes 集群，请检查 kubeconfig 配置"
            exit 1
        fi
        success "Kubernetes 集群连接正常"

        # ---- Helm Chart 部署 ----
        info "使用 Helm Chart 部署 ..."

        # 检查 helm
        if ! command -v helm &>/dev/null; then
            error "未安装 helm，请先安装："
            echo -e "  ${CYAN}curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash${NC}"
            exit 1
        fi
        success "helm 可用: $(helm version --short 2>/dev/null)"

        HELM_CHART_DIR="${CICD_DIR}/cd/k8s/helm/devpilot"
        if [ ! -d "${HELM_CHART_DIR}" ]; then
            error "Helm Chart 目录不存在: ${HELM_CHART_DIR}"
            exit 1
        fi

        # 从 .env 生成 Helm values 覆盖文件
        HELM_OVERRIDE="${CICD_DIR}/cd/k8s/helm/values-override.yaml"
        info "从 .env 生成 Helm values 覆盖文件 ..."
        cat > "${HELM_OVERRIDE}" <<EOF
# 自动生成的 values 覆盖文件（请勿手动编辑）
agnes:
  apiKey: "${AGNES_API_KEY}"
  baseUrl: "${AGNES_BASE_URL}"
feishu:
  appId: "${FEISHU_APP_ID}"
  appSecret: "${FEISHU_APP_SECRET}"
redis:
  password: "${REDIS_PASSWORD}"
openclaw:
  gatewayToken: "${OPENCLAW_GATEWAY_TOKEN}"
  gatewayPort: ${OPENCLAW_GATEWAY_PORT}
ccSwitchClaude:
  autoDeploy: "${DEVPILOT_AUTO_DEPLOY:-false}"
global:
  tz: "${TZ}"
nodeImageTag: "${NODE_IMAGE_TAG}"
EOF
        success "values 覆盖文件已生成: ${HELM_OVERRIDE}"

        # 执行 Helm 部署
        RELEASE_NAME="devpilot"
        NAMESPACE="devpilot"

        info "创建命名空间: ${NAMESPACE}"
        kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

        info "执行 Helm 部署 ..."
        helm upgrade --install "${RELEASE_NAME}" "${HELM_CHART_DIR}" \
            --namespace "${NAMESPACE}" \
            --values "${HELM_CHART_DIR}/values.yaml" \
            --values "${HELM_OVERRIDE}" \
            --timeout 10m

        success "Helm 部署完成"

        # 清理临时文件
        rm -f "${HELM_OVERRIDE}"
        ;;

    *)
        error "未知的部署模式: ${DEPLOY_MODE}"
        echo "可选模式: compose | run | remote | k8s"
        exit 1
        ;;
esac

# ============================================================
# 6. 部署后健康检查
# ============================================================
print_header "部署后健康检查"

# 健康检查函数（Docker 模式）
# 注意：此处为部署后状态检查，复用 common.sh 中的 wait_for_* 函数
# 以较小的重试次数快速确认服务状态（非阻塞式长等待）
health_check_docker() {
    info "Docker 健康检查 ..."

    # Redis
    if docker ps --format '{{.Names}}' | grep -q "devpilot-redis"; then
        wait_for_redis "devpilot-redis" "${REDIS_PASSWORD}" 3 || true
    else
        warn "Redis: 容器未运行"
    fi

    # OpenClaw（容器内 /healthz）
    if docker ps --format '{{.Names}}' | grep -q "devpilot-openclaw"; then
        wait_for_container_http "devpilot-openclaw" "18789" "/healthz" 3 2 || true
    else
        warn "OpenClaw: 容器未运行"
    fi

    # CC-Switch Web（从宿主机访问 Web 端口）
    if docker ps --format '{{.Names}}' | grep -q "devpilot-claude"; then
    else
        warn "CC-Switch Web: 容器未运行"
    fi
}

# 健康检查函数（Kubernetes 模式）
health_check_k8s() {
    info "Kubernetes 健康检查 ..."
    NAMESPACE="devpilot"

    # 检查 Pod 状态
    info "Pod 状态："
    kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || {
        warn "无法获取 Pod 状态"
        return 0
    }

    echo ""
    # 检查 Service
    info "Service 状态："
    kubectl get svc -n "${NAMESPACE}" 2>/dev/null || true

    echo ""
    # 检查 PVC
    info "PVC 状态："
    kubectl get pvc -n "${NAMESPACE}" 2>/dev/null || true

    # 等待 Pod 就绪
    echo ""
    info "等待所有 Pod 就绪 ..."
    kubectl wait --for=condition=Ready pods -n "${NAMESPACE}" \
        --all --timeout=300s 2>/dev/null || {
        warn "部分 Pod 未在 300s 内就绪，请检查 Pod 日志"
        warn "查看日志: kubectl logs -n devpilot -l app.kubernetes.io/part-of=devpilot"
    }
}

# 根据部署模式执行健康检查
case "${DEPLOY_MODE}" in
    compose|run)
        sleep 5
        health_check_docker
        ;;
    remote)
        sleep 5
        health_check_docker
        ;;
    k8s)
        health_check_k8s
        ;;
esac

# ============================================================
# 7. 输出最终结果
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署流程完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${CYAN}访问地址：${NC}"
echo -e "  OpenClaw Gateway:  http://localhost:${OPENCLAW_GATEWAY_PORT}/healthz"
echo -e "  Claude Code:       docker exec -it devpilot-claude claude"
  echo -e "  litellm 代理:      http://localhost:4000/health/liveliness"
echo ""
echo -e "${CYAN}下一步：${NC}"
echo -e "  1. 浏览器访问 CC-Switch Web UI（agnes-ai 供应商已自动配置）"
echo -e "  2. 使用 Claude Code: docker exec -it devpilot-claude claude"
echo -e "  3. 在飞书中测试机器人回复"
echo ""
