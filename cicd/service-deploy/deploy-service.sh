#!/bin/bash
set -e

# ============================================================
# DevPilot - 服务自动部署脚本
# 读取 service.yaml 描述符，自动构建并部署服务到 Docker/K8s/Remote
#
# 用法:
#   ./deploy-service.sh --service-dir <dir> [--tag <tag>] [--build-only] [--dry-run] [--cleanup] [--list] [--help]
#
# 参数:
#   --service-dir <dir>   服务目录路径（含 service.yaml）
#   --tag <tag>           镜像标签（默认 latest）
#   --build-only          仅构建不部署
#   --dry-run             仅打印将执行的命令，不实际执行
#   --cleanup             停止并清理服务容器/资源
#   --list                列出所有可部署的服务
#   --help, -h            显示帮助信息
# ============================================================

# ---- 加载公共函数库（颜色定义、日志函数、错误陷阱等） ----
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

# ---- 错误捕获 ----
setup_error_trap

# ---- 定位脚本目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---- 加载 YAML 解析库 ----
source "${SCRIPT_DIR}/lib/yaml-parser.sh"

# ---- 全局变量 ----
DRY_RUN="false"
SERVICE_DIR=""
IMAGE_TAG="latest"
BUILD_ONLY="false"
CLEANUP="false"
LIST_ONLY="false"
SERVICE_YAML=""
SERVICE_NAME=""
BUILD_TYPE=""
DEPLOY_TARGET=""

# ============================================================
# 1. 参数解析
# ============================================================
show_help() {
    cat << 'HELP'
DevPilot 服务自动部署脚本

用法:
  deploy-service.sh --service-dir <dir> [选项]
  deploy-service.sh --list
  deploy-service.sh --help

选项:
  --service-dir <dir>   服务目录路径（含 service.yaml）
  --tag <tag>           镜像标签（默认 latest）
  --build-only          仅构建镜像，不部署
  --dry-run             仅打印命令，不实际执行
  --cleanup             停止并清理服务
  --list                列出所有可部署的服务
  --help, -h            显示帮助

示例:
  deploy-service.sh --service-dir workspace/my-service
  deploy-service.sh --service-dir workspace/my-service --tag v1.0.0
  deploy-service.sh --service-dir workspace/my-service --build-only
  deploy-service.sh --service-dir workspace/my-service --dry-run
  deploy-service.sh --list
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service-dir)
            SERVICE_DIR="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --build-only)
            BUILD_ONLY="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --cleanup)
            CLEANUP="true"
            shift
            ;;
        --list)
            LIST_ONLY="true"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            error "未知参数: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 执行命令（支持 dry-run）
# 注意: 此 run_cmd 覆盖 common.sh 中的同名函数。
# deploy-service.sh 以字符串形式传递命令（如 run_cmd "docker build ..."），
# 需要 eval 来正确处理变量展开与复杂命令，因此保留此本地版本。
run_cmd() {
    if [ "${DRY_RUN}" = "true" ]; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$@"
    fi
}

# ============================================================
# 2. 列出所有可部署的服务
# ============================================================
list_services() {
    # 容器内启动时 WORKSPACE_DIR 由 conf/claude/start.sh 注入为 /workspace
    # （与 docker-compose.yml 卷挂载 ./workspace:/workspace 对齐）。
    # 宿主机直接调用时可默认不设，落到 ${PROJECT_ROOT}/workspace。
    # 与 cicd/service-deploy/post-dev-hook.sh:29 行为对齐（同样的 env override 模式）。
    local workspace_dir="${WORKSPACE_DIR:-${PROJECT_ROOT}/workspace}"
    if [ ! -d "${workspace_dir}" ]; then
        warn "workspace 目录不存在: ${workspace_dir}"
        exit 0
    fi

    echo -e "${MAGENTA}========================================${NC}"
    echo -e "${MAGENTA}  DevPilot 可部署服务列表${NC}"
    echo -e "${MAGENTA}========================================${NC}"
    echo ""

    local found=0
    for dir in "${workspace_dir}"/*/; do
        if [ -f "${dir}service.yaml" ]; then
            local name=$(yaml_get "name" "${dir}service.yaml")
            local desc=$(yaml_get "description" "${dir}service.yaml")
            local target=$(yaml_get_nested "deploy.target" "${dir}service.yaml")
            local btype=$(yaml_get_nested "build.type" "${dir}service.yaml")
            [ -z "${name}" ] && name=$(basename "${dir}")
            [ -z "${desc}" ] && desc="(无描述)"
            [ -z "${target}" ] && target="(未配置)"
            [ -z "${btype}" ] && btype="(未配置)"
            echo -e "  ${GREEN}${name}${NC}"
            echo -e "    描述:     ${desc}"
            echo -e "    构建类型: ${btype}"
            echo -e "    部署目标: ${target}"
            echo -e "    目录:     ${dir}"
            echo ""
            found=1
        fi
    done

    if [ ${found} -eq 0 ]; then
        warn "未找到任何可部署的服务"
        echo -e "  在 workspace/ 下的服务目录中创建 service.yaml 即可"
        echo -e "  模板参考: cicd/service-deploy/service.yaml.example"
    fi
}

if [ "${LIST_ONLY}" = "true" ]; then
    list_services
    exit 0
fi

# ============================================================
# 3. 校验参数和加载 service.yaml
# ============================================================
if [ -z "${SERVICE_DIR}" ]; then
    error "未指定服务目录，使用 --service-dir <dir> 指定"
    echo "使用 --help 查看帮助"
    exit 1
fi

# 处理相对路径
if [[ "${SERVICE_DIR}" != /* ]]; then
    SERVICE_DIR="${PROJECT_ROOT}/${SERVICE_DIR}"
fi

if [ ! -d "${SERVICE_DIR}" ]; then
    error "服务目录不存在: ${SERVICE_DIR}"
    exit 1
fi

SERVICE_YAML="${SERVICE_DIR}/service.yaml"
if [ ! -f "${SERVICE_YAML}" ]; then
    error "未找到 service.yaml: ${SERVICE_YAML}"
    echo -e "  请从模板创建: cp cicd/service-deploy/service.yaml.example ${SERVICE_YAML}"
    exit 1
fi

# ---- 构建类型自动推断 ----
# 根据服务目录中的文件特征自动推断 build.type：
#   Dockerfile       -> dockerfile
#   package.json     -> nodejs
#   requirements.txt -> python
#   其他             -> static
infer_build_type() {
    local svc_dir="$1"
    if [ -f "${svc_dir}/Dockerfile" ]; then
        echo "dockerfile"
    elif [ -f "${svc_dir}/package.json" ]; then
        echo "nodejs"
    elif [ -f "${svc_dir}/requirements.txt" ]; then
        echo "python"
    else
        echo "static"
    fi
}

# 加载服务配置
SERVICE_NAME=$(yaml_get "name" "${SERVICE_YAML}")
BUILD_TYPE=$(yaml_get_nested "build.type" "${SERVICE_YAML}")
DEPLOY_TARGET=$(yaml_get_nested "deploy.target" "${SERVICE_YAML}")

# 校验必填字段
if [ -z "${SERVICE_NAME}" ]; then
    error "service.yaml 中缺少必填字段: name"
    exit 1
fi

# build.type 未指定时根据服务目录文件自动推断
if [ -z "${BUILD_TYPE}" ]; then
    BUILD_TYPE=$(infer_build_type "${SERVICE_DIR}")
    info "自动推断构建类型: ${BUILD_TYPE}"
fi

if [ -z "${DEPLOY_TARGET}" ] && [ "${CLEANUP}" = "false" ]; then
    error "service.yaml 中缺少必填字段: deploy.target"
    exit 1
fi

# 设置默认值
BUILD_CONTEXT=$(yaml_get_nested "build.context" "${SERVICE_YAML}")
[ -z "${BUILD_CONTEXT}" ] && BUILD_CONTEXT="."
DOCKERFILE_PATH=$(yaml_get_nested "build.dockerfile" "${SERVICE_YAML}")
[ -z "${DOCKERFILE_PATH}" ] && DOCKERFILE_PATH="Dockerfile"

IMAGE_NAME="devpilot-${SERVICE_NAME}:${IMAGE_TAG}"

echo ""
echo -e "${MAGENTA}========================================${NC}"
echo -e "${MAGENTA}  DevPilot 服务部署${NC}"
echo -e "${MAGENTA}========================================${NC}"
echo ""
echo -e "${CYAN}服务信息:${NC}"
echo -e "  名称:       ${SERVICE_NAME}"
echo -e "  镜像:       ${IMAGE_NAME}"
echo -e "  构建类型:   ${BUILD_TYPE}"
if [ "${CLEANUP}" = "false" ]; then
    echo -e "  部署目标:   ${DEPLOY_TARGET}"
fi
echo -e "  服务目录:   ${SERVICE_DIR}"
if [ "${DRY_RUN}" = "true" ]; then
    echo -e "  ${YELLOW}(DRY-RUN 模式: 仅打印命令不执行)${NC}"
fi
echo ""

# ============================================================
# 4. 清理模式
# ============================================================
if [ "${CLEANUP}" = "true" ]; then
    info "清理服务: ${SERVICE_NAME}..."

    # 获取部署目标（清理时可能没有 deploy.target）
    if [ -z "${DEPLOY_TARGET}" ]; then
        DEPLOY_TARGET="docker"
    fi

    case "${DEPLOY_TARGET}" in
        docker)
            local_container="devpilot-${SERVICE_NAME}"
            if docker ps -a --format '{{.Names}}' | grep -q "^${local_container}$"; then
                run_cmd "docker rm -f ${local_container}"
                success "已删除容器: ${local_container}"
            else
                warn "容器不存在: ${local_container}"
            fi
            # 删除镜像
            if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
                run_cmd "docker rmi ${IMAGE_NAME}"
                success "已删除镜像: ${IMAGE_NAME}"
            fi
            ;;
        k8s)
            local_ns=$(yaml_get_nested "deploy.k8s.namespace" "${SERVICE_YAML}")
            [ -z "${local_ns}" ] && local_ns="devpilot-services"
            run_cmd "kubectl delete deployment ${SERVICE_NAME} -n ${local_ns} --ignore-not-found=true"
            run_cmd "kubectl delete service ${SERVICE_NAME} -n ${local_ns} --ignore-not-found=true"
            success "已清理 K8s 资源 (namespace: ${local_ns})"
            ;;
        remote)
            local_container="devpilot-${SERVICE_NAME}"
            remote_host=$(yaml_get_nested "deploy.remote.docker_host" "${SERVICE_YAML}")
            if [ -n "${remote_host}" ]; then
                run_cmd "DOCKER_HOST=${remote_host} docker rm -f ${local_container} 2>/dev/null || true"
                success "已清理远程容器: ${local_container}"
            fi
            ;;
    esac

    echo ""
    success "清理完成"
    exit 0
fi

# ============================================================
# 5. 构建镜像
# ============================================================
build_image() {
    info "构建服务镜像..."

    cd "${SERVICE_DIR}"

    case "${BUILD_TYPE}" in
        dockerfile)
            if [ ! -f "${DOCKERFILE_PATH}" ]; then
                error "Dockerfile 不存在: ${SERVICE_DIR}/${DOCKERFILE_PATH}"
                exit 1
            fi

            # 读取构建参数
            local build_args=""
            local args_list=$(yaml_get_nested_list "build.args" "${SERVICE_YAML}")
            if [ -n "${args_list}" ]; then
                while IFS= read -r arg; do
                    build_args="${build_args} --build-arg ${arg}"
                done <<< "${args_list}"
            fi

            info "构建 Docker 镜像: ${IMAGE_NAME}"
            run_cmd "docker build -t ${IMAGE_NAME} -f ${DOCKERFILE_PATH} ${build_args} ${BUILD_CONTEXT}"
            success "镜像构建完成: ${IMAGE_NAME}"
            ;;

        nodejs)
            info "构建 Node.js 服务..."
            # 通过 stdin 传入 Dockerfile，避免创建临时文件（-f - 表示从标准输入读取）
            if [ "${DRY_RUN}" = "true" ]; then
                echo -e "  ${YELLOW}[DRY-RUN]${NC} docker build -t ${IMAGE_NAME} -f - ${BUILD_CONTEXT} << 'EOF'"
                cat << 'EOF'
FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --production || npm install --production
COPY . .
EXPOSE 8080
CMD ["node", "index.js"]
EOF
                echo "EOF"
            else
                docker build -t ${IMAGE_NAME} -f - ${BUILD_CONTEXT} << 'EOF'
FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --production || npm install --production
COPY . .
EXPOSE 8080
CMD ["node", "index.js"]
EOF
            fi
            success "Node.js 镜像构建完成: ${IMAGE_NAME}"
            ;;

        python)
            info "构建 Python 服务..."
            # 通过 stdin 传入 Dockerfile，避免创建临时文件（-f - 表示从标准输入读取）
            if [ "${DRY_RUN}" = "true" ]; then
                echo -e "  ${YELLOW}[DRY-RUN]${NC} docker build -t ${IMAGE_NAME} -f - ${BUILD_CONTEXT} << 'EOF'"
                cat << 'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python", "app.py"]
EOF
                echo "EOF"
            else
                docker build -t ${IMAGE_NAME} -f - ${BUILD_CONTEXT} << 'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python", "app.py"]
EOF
            fi
            success "Python 镜像构建完成: ${IMAGE_NAME}"
            ;;

        static)
            info "构建静态文件服务..."
            # 通过 stdin 传入 Dockerfile，避免创建临时文件（-f - 表示从标准输入读取）
            if [ "${DRY_RUN}" = "true" ]; then
                echo -e "  ${YELLOW}[DRY-RUN]${NC} docker build -t ${IMAGE_NAME} -f - ${BUILD_CONTEXT} << 'EOF'"
                cat << 'EOF'
FROM nginx:alpine
COPY . /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF
                echo "EOF"
            else
                docker build -t ${IMAGE_NAME} -f - ${BUILD_CONTEXT} << 'EOF'
FROM nginx:alpine
COPY . /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF
            fi
            success "静态文件镜像构建完成: ${IMAGE_NAME}"
            ;;

        *)
            error "不支持的构建类型: ${BUILD_TYPE}"
            echo "支持的类型: dockerfile | nodejs | python | static"
            exit 1
            ;;
    esac

    cd "${PROJECT_ROOT}"
}

build_image

if [ "${BUILD_ONLY}" = "true" ]; then
    echo ""
    success "仅构建模式完成，镜像: ${IMAGE_NAME}"
    echo -e "  ${CYAN}部署命令: ./deploy-service.sh --service-dir ${SERVICE_DIR}${NC}"
    exit 0
fi

# ============================================================
# 6. 部署
# ============================================================

# ---- Docker 部署 ----
deploy_docker() {
    info "部署到 Docker..."

    local container_name=$(yaml_get_nested "deploy.docker.container_name" "${SERVICE_YAML}")
    [ -z "${container_name}" ] && container_name="devpilot-${SERVICE_NAME}"

    local network=$(yaml_get_nested "deploy.docker.network" "${SERVICE_YAML}")
    [ -z "${network}" ] && network="devpilot-network"

    local restart_policy=$(yaml_get_nested "deploy.docker.restart" "${SERVICE_YAML}")
    [ -z "${restart_policy}" ] && restart_policy="unless-stopped"

    local memory_limit=$(yaml_get_nested "deploy.docker.memory_limit" "${SERVICE_YAML}")

    # 构建端口映射参数
    local port_args=""
    local ports_list=$(yaml_get_nested_list "deploy.docker.ports" "${SERVICE_YAML}")
    if [ -n "${ports_list}" ]; then
        while IFS= read -r port; do
            port_args="${port_args} -p ${port}"
        done <<< "${ports_list}"
    fi

    # 构建环境变量参数
    local env_args=""
    local env_file=$(yaml_get_nested "deploy.docker.env_file" "${SERVICE_YAML}")
    if [ -n "${env_file}" ] && [ -f "${SERVICE_DIR}/${env_file}" ]; then
        env_args="${env_args} --env-file ${SERVICE_DIR}/${env_file}"
    fi
    local env_list=$(yaml_get_nested_list "deploy.docker.env" "${SERVICE_YAML}")
    if [ -n "${env_list}" ]; then
        while IFS= read -r env_var; do
            env_args="${env_args} -e ${env_var}"
        done <<< "${env_list}"
    fi

    # 构建数据卷参数
    local volume_args=""
    local volumes_list=$(yaml_get_nested_list "deploy.docker.volumes" "${SERVICE_YAML}")
    if [ -n "${volumes_list}" ]; then
        while IFS= read -r vol; do
            volume_args="${volume_args} -v ${SERVICE_DIR}/${vol}"
        done <<< "${volumes_list}"
    fi

    # 构建内存限制参数
    local mem_args=""
    if [ -n "${memory_limit}" ]; then
        mem_args="--memory=${memory_limit}"
    fi

    # 清理同名旧容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        warn "发现同名旧容器，正在删除: ${container_name}"
        run_cmd "docker rm -f ${container_name}"
    fi

    # 确保网络存在
    if ! docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
        run_cmd "docker network create ${network}"
    fi

    # 启动容器
    info "启动容器: ${container_name}"
    run_cmd "docker run -d \
        --name ${container_name} \
        --network ${network} \
        --restart ${restart_policy} \
        ${port_args} \
        ${env_args} \
        ${volume_args} \
        ${mem_args} \
        ${IMAGE_NAME}"

    success "容器已启动: ${container_name}"
}

# ---- K8s 部署 ----
deploy_k8s() {
    info "部署到 Kubernetes..."

    if ! command -v kubectl &>/dev/null; then
        error "未安装 kubectl"
        exit 1
    fi

    local namespace=$(yaml_get_nested "deploy.k8s.namespace" "${SERVICE_YAML}")
    [ -z "${namespace}" ] && namespace="devpilot-services"

    local replicas=$(yaml_get_nested "deploy.k8s.replicas" "${SERVICE_YAML}")
    [ -z "${replicas}" ] && replicas=1

    local image_pull_policy=$(yaml_get_nested "deploy.k8s.image_pull_policy" "${SERVICE_YAML}")
    [ -z "${image_pull_policy}" ] && image_pull_policy="IfNotPresent"

    local service_type=$(yaml_get_nested "deploy.k8s.service_type" "${SERVICE_YAML}")
    [ -z "${service_type}" ] && service_type="ClusterIP"

    local node_port=$(yaml_get_nested "deploy.k8s.node_port" "${SERVICE_YAML}")

    # 获取端口
    local port=$(yaml_get "port" "${SERVICE_YAML}")
    if [ -z "${port}" ]; then
        local ports_list=$(yaml_get_list "ports" "${SERVICE_YAML}")
        port=$(echo "${ports_list}" | head -1)
    fi
    [ -z "${port}" ] && port=8080

    # 生成 K8s 清单
    local template="${SCRIPT_DIR}/k8s/service-template.yaml"
    local manifest="${SERVICE_DIR}/.devpilot-k8s-manifest.yaml"

    cp "${template}" "${manifest}"

    # 替换占位符（单次 sed 调用，多重 -e 表达式，减少进程创建与文件读写）
    sed -i \
        -e "s|{{NAMESPACE}}|${namespace}|g" \
        -e "s|{{SERVICE_NAME}}|${SERVICE_NAME}|g" \
        -e "s|{{IMAGE}}|${IMAGE_NAME}|g" \
        -e "s|{{REPLICAS}}|${replicas}|g" \
        -e "s|{{IMAGE_PULL_POLICY}}|${image_pull_policy}|g" \
        -e "s|{{SERVICE_TYPE}}|${service_type}|g" \
        -e "s|{{PORT}}|${port}|g" \
        "${manifest}"

    # 处理 NodePort
    if [ "${service_type}" = "NodePort" ] && [ -n "${node_port}" ]; then
        sed -i "s|{{NODE_PORT_BLOCK}}|      nodePort: ${node_port}|" "${manifest}"
    else
        sed -i "s|{{NODE_PORT_BLOCK}}||" "${manifest}"
    fi

    # 处理资源限制
    local resources_block=""
    local cpu_req=$(yaml_get_nested "deploy.k8s.resources.requests.cpu" "${SERVICE_YAML}")
    local mem_req=$(yaml_get_nested "deploy.k8s.resources.requests.memory" "${SERVICE_YAML}")
    local cpu_lim=$(yaml_get_nested "deploy.k8s.resources.limits.cpu" "${SERVICE_YAML}")
    local mem_lim=$(yaml_get_nested "deploy.k8s.resources.limits.memory" "${SERVICE_YAML}")
    if [ -n "${cpu_req}" ] || [ -n "${mem_req}" ] || [ -n "${cpu_lim}" ] || [ -n "${mem_lim}" ]; then
        resources_block="          resources:"
        [ -n "${cpu_req}" ] || [ -n "${mem_req}" ] && resources_block="${resources_block}\n            requests:"
        [ -n "${cpu_req}" ] && resources_block="${resources_block}\n              cpu: ${cpu_req}"
        [ -n "${mem_req}" ] && resources_block="${resources_block}\n              memory: ${mem_req}"
        [ -n "${cpu_lim}" ] || [ -n "${mem_lim}" ] && resources_block="${resources_block}\n            limits:"
        [ -n "${cpu_lim}" ] && resources_block="${resources_block}\n              cpu: ${cpu_lim}"
        [ -n "${mem_lim}" ] && resources_block="${resources_block}\n              memory: ${mem_lim}"
    fi
    sed -i "s|{{RESOURCES_BLOCK}}|${resources_block}|" "${manifest}"

    # 处理健康检查探针
    local hc_type=$(yaml_get_nested "healthcheck.type" "${SERVICE_YAML}")
    local hc_path=$(yaml_get_nested "healthcheck.path" "${SERVICE_YAML}")
    local hc_port=$(yaml_get_nested "healthcheck.port" "${SERVICE_YAML}")

    local liveness_block=""
    local readiness_block=""
    if [ "${hc_type}" = "http" ] && [ -n "${hc_path}" ] && [ -n "${hc_port}" ]; then
        liveness_block="          livenessProbe:\n            httpGet:\n              path: ${hc_path}\n              port: ${hc_port}\n            initialDelaySeconds: 30"
        readiness_block="          readinessProbe:\n            httpGet:\n              path: ${hc_path}\n              port: ${hc_port}\n            initialDelaySeconds: 5"
    elif [ "${hc_type}" = "tcp" ] && [ -n "${hc_port}" ]; then
        liveness_block="          livenessProbe:\n            tcpSocket:\n              port: ${hc_port}\n            initialDelaySeconds: 30"
        readiness_block="          readinessProbe:\n            tcpSocket:\n              port: ${hc_port}\n            initialDelaySeconds: 5"
    fi
    sed -i "s|{{LIVENESS_PROBE_BLOCK}}|${liveness_block}|" "${manifest}"
    sed -i "s|{{READINESS_PROBE_BLOCK}}|${readiness_block}|" "${manifest}"

    # 环境变量块（暂留空）
    sed -i "s|{{ENV_BLOCK}}||" "${manifest}"

    # 应用清单
    info "应用 K8s 清单 (namespace: ${namespace})..."
    run_cmd "kubectl apply -f ${manifest}"

    # 清理临时文件
    rm -f "${manifest}"

    success "K8s 部署完成: ${SERVICE_NAME} (namespace: ${namespace})"
}

# ---- 远程 Docker 部署 ----
deploy_remote() {
    info "部署到远程 Docker..."

    local remote_host=$(yaml_get_nested "deploy.remote.docker_host" "${SERVICE_YAML}")
    if [ -z "${remote_host}" ]; then
        error "service.yaml 中缺少 deploy.remote.docker_host"
        exit 1
    fi

    local container_name="devpilot-${SERVICE_NAME}"
    local network=$(yaml_get_nested "deploy.remote.network" "${SERVICE_YAML}")
    [ -z "${network}" ] && network="devpilot-network"

    # 构建端口映射参数
    local port_args=""
    local ports_list=$(yaml_get_nested_list "deploy.remote.ports" "${SERVICE_YAML}")
    if [ -n "${ports_list}" ]; then
        while IFS= read -r port; do
            port_args="${port_args} -p ${port}"
        done <<< "${ports_list}"
    fi

    # 导出镜像
    info "导出镜像: ${IMAGE_NAME}"
    local tar_file="/tmp/devpilot-${SERVICE_NAME}-${IMAGE_TAG}.tar"
    run_cmd "docker save -o ${tar_file} ${IMAGE_NAME}"

    # 传输到远程
    info "传输镜像到远程: ${remote_host}"
    local ssh_host="${remote_host#ssh://}"
    ssh_host="${ssh_host#tcp://}"
    run_cmd "scp ${tar_file} ${ssh_host}:/tmp/"

    # 在远程加载并运行
    info "远程加载镜像并启动容器..."
    run_cmd "ssh ${ssh_host} 'docker load -i /tmp/devpilot-${SERVICE_NAME}-${IMAGE_TAG}.tar'"
    run_cmd "ssh ${ssh_host} 'docker rm -f ${container_name} 2>/dev/null || true'"
    run_cmd "ssh ${ssh_host} 'docker run -d --name ${container_name} --network ${network} ${port_args} ${IMAGE_NAME}'"
    run_cmd "ssh ${ssh_host} 'rm -f /tmp/devpilot-${SERVICE_NAME}-${IMAGE_TAG}.tar'"
    run_cmd "rm -f ${tar_file}"

    success "远程部署完成: ${container_name} @ ${remote_host}"
}

# 执行部署
case "${DEPLOY_TARGET}" in
    docker)
        deploy_docker
        ;;
    k8s)
        deploy_k8s
        ;;
    remote)
        deploy_remote
        ;;
    *)
        error "不支持的部署目标: ${DEPLOY_TARGET}"
        echo "支持的目标: docker | k8s | remote"
        exit 1
        ;;
esac

# ============================================================
# 7. 健康检查
# ============================================================
wait_health() {
    if [ "${DRY_RUN}" = "true" ]; then
        echo -e "  ${YELLOW}[DRY-RUN] 跳过健康检查${NC}"
        return 0
    fi

    local hc_type=$(yaml_get_nested "healthcheck.type" "${SERVICE_YAML}")
    local hc_path=$(yaml_get_nested "healthcheck.path" "${SERVICE_YAML}")
    local hc_port=$(yaml_get_nested "healthcheck.port" "${SERVICE_YAML}")
    local hc_interval=$(yaml_get_nested "healthcheck.interval" "${SERVICE_YAML}")
    local hc_timeout=$(yaml_get_nested "healthcheck.timeout" "${SERVICE_YAML}")
    local hc_retries=$(yaml_get_nested "healthcheck.retries" "${SERVICE_YAML}")
    local hc_start=$(yaml_get_nested "healthcheck.start_period" "${SERVICE_YAML}")

    [ -z "${hc_type}" ] && hc_type="http"
    [ -z "${hc_interval}" ] && hc_interval=10
    [ -z "${hc_retries}" ] && hc_retries=5

    local interval_sec=$(echo "${hc_interval}" | grep -oP '^\d+')
    [ -z "${interval_sec}" ] && interval_sec=10
    local start_sec=30
    if [ -n "${hc_start}" ]; then
        start_sec=$(echo "${hc_start}" | grep -oP '^\d+')
        [ -z "${start_sec}" ] && start_sec=30
    fi

    info "等待服务就绪（启动等待 ${start_sec}s，最多重试 ${hc_retries} 次）..."
    sleep "${start_sec}"

    local container_name="devpilot-${SERVICE_NAME}"
    local healthy=false
    local attempt=0

    while [ ${attempt} -lt ${hc_retries} ]; do
        attempt=$((attempt + 1))

        case "${hc_type}" in
            http)
                if [ "${DEPLOY_TARGET}" = "docker" ]; then
                    if docker exec "${container_name}" curl -sf "http://127.0.0.1:${hc_port}${hc_path}" >/dev/null 2>&1; then
                        healthy=true
                        break
                    fi
                elif [ "${DEPLOY_TARGET}" = "k8s" ]; then
                    local ns=$(yaml_get_nested "deploy.k8s.namespace" "${SERVICE_YAML}")
                    [ -z "${ns}" ] && ns="devpilot-services"
                    if kubectl exec -n "${ns}" "deployment/${SERVICE_NAME}" -- curl -sf "http://127.0.0.1:${hc_port}${hc_path}" >/dev/null 2>&1; then
                        healthy=true
                        break
                    fi
                fi
                ;;
            tcp)
                if [ "${DEPLOY_TARGET}" = "docker" ]; then
                    if docker exec "${container_name}" sh -c "echo > /dev/tcp/127.0.0.1/${hc_port}" 2>/dev/null; then
                        healthy=true
                        break
                    fi
                fi
                ;;
            command)
                local hc_cmd=$(yaml_get_nested "healthcheck.command" "${SERVICE_YAML}")
                if [ -n "${hc_cmd}" ] && [ "${DEPLOY_TARGET}" = "docker" ]; then
                    if docker exec "${container_name}" sh -c "${hc_cmd}" >/dev/null 2>&1; then
                        healthy=true
                        break
                    fi
                fi
                ;;
        esac

        warn "健康检查未通过 (${attempt}/${hc_retries})，等待 ${interval_sec}s..."
        sleep "${interval_sec}"
    done

    if [ "${healthy}" = "true" ]; then
        success "服务健康检查通过"
    else
        warn "服务健康检查未通过（可能仍在启动中）"
        echo -e "  查看日志: docker logs -f ${container_name}"
    fi
}

if [ "${DRY_RUN}" = "false" ]; then
    wait_health
fi

# ============================================================
# 8. 输出结果
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${CYAN}服务信息:${NC}"
echo -e "  名称:   ${SERVICE_NAME}"
echo -e "  镜像:   ${IMAGE_NAME}"

case "${DEPLOY_TARGET}" in
    docker)
        container_name=$(yaml_get_nested "deploy.docker.container_name" "${SERVICE_YAML}")
        [ -z "${container_name}" ] && container_name="devpilot-${SERVICE_NAME}"
        echo -e "  容器:   ${container_name}"
        ports_list=$(yaml_get_nested_list "deploy.docker.ports" "${SERVICE_YAML}")
        if [ -n "${ports_list}" ]; then
            echo -e "  端口:   $(echo ${ports_list} | tr '\n' ' ')"
        fi
        echo ""
        echo -e "${CYAN}常用命令:${NC}"
        echo -e "  查看日志:   docker logs -f ${container_name}"
        echo -e "  进入容器:   docker exec -it ${container_name} bash"
        echo -e "  停止服务:   ./deploy-service.sh --service-dir ${SERVICE_DIR} --cleanup"
        ;;
    k8s)
        namespace=$(yaml_get_nested "deploy.k8s.namespace" "${SERVICE_YAML}")
        [ -z "${namespace}" ] && namespace="devpilot-services"
        echo -e "  命名空间: ${namespace}"
        echo ""
        echo -e "${CYAN}常用命令:${NC}"
        echo -e "  查看 Pod:   kubectl get pods -n ${namespace} -l app.kubernetes.io/name=${SERVICE_NAME}"
        echo -e "  查看日志:   kubectl logs -n ${namespace} -l app.kubernetes.io/name=${SERVICE_NAME} -f"
        echo -e "  清理服务:   ./deploy-service.sh --service-dir ${SERVICE_DIR} --cleanup"
        ;;
    remote)
        echo -e "  远程主机: ${remote_host}"
        echo ""
        echo -e "${CYAN}常用命令:${NC}"
        echo -e "  查看日志:   ssh ${ssh_host} docker logs -f devpilot-${SERVICE_NAME}"
        echo -e "  清理服务:   ./deploy-service.sh --service-dir ${SERVICE_DIR} --cleanup"
        ;;
esac

echo ""
