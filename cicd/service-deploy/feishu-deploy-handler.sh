#!/bin/bash

# ============================================================
# DevPilot - 飞书 Bot 部署命令处理器
# 接收飞书消息文本，解析部署命令并执行
#
# 支持的命令:
#   /deploy <service-name>              部署指定服务
#   /deploy <service-name> --tag v1.0   指定标签部署
#   /deploy --list                      列出所有可部署服务
#   /deploy --status <service-name>     查看服务状态
#   /deploy --logs <service-name>       查看服务日志
#   /deploy --restart <service-name>    重启服务
#   /deploy --cleanup <service-name>    清理服务
#   /deploy --help                      显示帮助
#
# 集成方式:
#   通过 OpenClaw 的插件机制或 Webhook 回调
#   将 /deploy 命令路由到此脚本
#   脚本接收消息文本作为参数，输出飞书消息卡片格式
# ============================================================

# ---- 加载公共函数库（颜色定义、日志函数等） ----
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

# ---- 定位脚本目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-service.sh"
WORKSPACE_DIR="${PROJECT_ROOT}/workspace"

# ---- 加载 YAML 解析库 ----
source "${SCRIPT_DIR}/lib/yaml-parser.sh"

# ============================================================
# 输出飞书消息卡片格式
# ============================================================
output_card() {
    local title="$1"
    local content="$2"
    local color="${3:-blue}"

    # 输出简单的文本格式（可由 OpenClaw 转换为飞书卡片）
    echo "【${title}】"
    echo "${content}"
}

# ============================================================
# 命令处理
# ============================================================

# 获取输入（参数或 stdin）
INPUT_TEXT="$*"
if [ -z "${INPUT_TEXT}" ]; then
    read -r INPUT_TEXT
fi

# 去除前缀
INPUT_TEXT="${INPUT_TEXT#/deploy }"
INPUT_TEXT="${INPUT_TEXT#/deploy}"
INPUT_TEXT="${INPUT_TEXT#deploy }"

# 解析子命令
SUBCMD="${INPUT_TEXT%% *}"
REST="${INPUT_TEXT#* }"

case "${SUBCMD}" in
    --list|list)
        # 列出所有服务
        result=$(bash "${DEPLOY_SCRIPT}" --list 2>&1)
        output_card "可部署服务列表" "${result}" "blue"
        ;;

    --status|status)
        # 查看服务状态
        svc_name="${REST%% *}"
        if [ -z "${svc_name}" ]; then
            output_card "错误" "请指定服务名称: /deploy --status <service-name>" "red"
            exit 0
        fi

        svc_dir="${WORKSPACE_DIR}/${svc_name}"
        if [ ! -f "${svc_dir}/service.yaml" ]; then
            output_card "错误" "服务不存在: ${svc_name}" "red"
            exit 0
        fi

        # 检查 Docker 容器状态
        container_name="devpilot-${svc_name}"
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            status=$(docker ps --filter "name=^${container_name}$" --format "{{.Status}}")
            ports=$(docker ps --filter "name=^${container_name}$" --format "{{.Ports}}")
            output_card "服务状态: ${svc_name}" "状态: 运行中\n容器: ${container_name}\nDocker 状态: ${status}\n端口: ${ports}" "green"
        elif docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            output_card "服务状态: ${svc_name}" "状态: 已停止\n容器: ${container_name}" "yellow"
        else
            # 检查 K8s
            ns=$(yaml_get_nested "deploy.k8s.namespace" "${svc_dir}/service.yaml" 2>/dev/null)
            [ -z "${ns}" ] && ns="devpilot-services"
            if command -v kubectl &>/dev/null && kubectl get deployment "${svc_name}" -n "${ns}" &>/dev/null 2>&1; then
                pods=$(kubectl get pods -n "${ns}" -l "app.kubernetes.io/name=${svc_name}" --no-headers 2>/dev/null | wc -l)
                output_card "服务状态: ${svc_name}" "状态: K8s 运行中\n命名空间: ${ns}\nPod 数: ${pods}" "green"
            else
                output_card "服务状态: ${svc_name}" "状态: 未部署" "grey"
            fi
        fi
        ;;

    --cleanup|cleanup)
        # 清理服务
        svc_name="${REST%% *}"
        if [ -z "${svc_name}" ]; then
            output_card "错误" "请指定服务名称: /deploy --cleanup <service-name>" "red"
            exit 0
        fi

        svc_dir="${WORKSPACE_DIR}/${svc_name}"
        if [ ! -f "${svc_dir}/service.yaml" ]; then
            output_card "错误" "服务不存在: ${svc_name}" "red"
            exit 0
        fi

        result=$(bash "${DEPLOY_SCRIPT}" --service-dir "${svc_dir}" --cleanup 2>&1)
        output_card "清理服务: ${svc_name}" "${result}" "orange"
        ;;

    --logs|logs)
        # 查看服务日志
        svc_name="${REST%% *}"
        if [ -z "${svc_name}" ]; then
            output_card "错误" "请指定服务名称: /deploy --logs <service-name>" "red"
            exit 0
        fi

        container_name="devpilot-${svc_name}"
        # 优先检查 Docker 容器
        if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            logs=$(docker logs --tail 50 "${container_name}" 2>&1)
            output_card "服务日志: ${svc_name}" "${logs}" "blue"
        else
            # 检查 K8s 部署
            ns="devpilot-services"
            svc_dir="${WORKSPACE_DIR}/${svc_name}"
            if [ -f "${svc_dir}/service.yaml" ]; then
                ns=$(yaml_get_nested "deploy.k8s.namespace" "${svc_dir}/service.yaml" 2>/dev/null)
                [ -z "${ns}" ] && ns="devpilot-services"
            fi
            if command -v kubectl &>/dev/null && kubectl get deployment "${svc_name}" -n "${ns}" &>/dev/null 2>&1; then
                logs=$(kubectl logs -n "${ns}" deployment/"${svc_name}" --tail=50 2>&1)
                output_card "服务日志: ${svc_name}" "${logs}" "blue"
            else
                output_card "错误" "服务未部署，无法获取日志: ${svc_name}" "red"
            fi
        fi
        ;;

    --restart|restart)
        # 重启服务
        svc_name="${REST%% *}"
        if [ -z "${svc_name}" ]; then
            output_card "错误" "请指定服务名称: /deploy --restart <service-name>" "red"
            exit 0
        fi

        container_name="devpilot-${svc_name}"
        # 优先检查 Docker 容器
        if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            if docker restart "${container_name}" &>/dev/null; then
                output_card "重启服务: ${svc_name}" "服务已成功重启\n容器: ${container_name}" "green"
            else
                output_card "重启失败: ${svc_name}" "Docker 容器重启失败\n容器: ${container_name}" "red"
            fi
        else
            # 检查 K8s 部署
            ns="devpilot-services"
            svc_dir="${WORKSPACE_DIR}/${svc_name}"
            if [ -f "${svc_dir}/service.yaml" ]; then
                ns=$(yaml_get_nested "deploy.k8s.namespace" "${svc_dir}/service.yaml" 2>/dev/null)
                [ -z "${ns}" ] && ns="devpilot-services"
            fi
            if command -v kubectl &>/dev/null && kubectl get deployment "${svc_name}" -n "${ns}" &>/dev/null 2>&1; then
                if kubectl rollout restart deployment "${svc_name}" -n "${ns}" &>/dev/null; then
                    output_card "重启服务: ${svc_name}" "K8s 部署已触发滚动重启\n命名空间: ${ns}" "green"
                else
                    output_card "重启失败: ${svc_name}" "K8s 部署重启失败\n命名空间: ${ns}" "red"
                fi
            else
                output_card "错误" "服务未部署，无法重启: ${svc_name}" "red"
            fi
        fi
        ;;

    --help|help|"")
        # 显示帮助
        output_card "DevPilot 部署命令帮助" "可用命令:
/deploy <service-name>              部署指定服务
/deploy <service-name> --tag v1.0   指定标签部署
/deploy --list                      列出所有可部署服务
/deploy --status <service-name>     查看服务状态
/deploy --logs <service-name>       查看服务最近日志
/deploy --restart <service-name>    重启服务
/deploy --cleanup <service-name>    清理服务
/deploy --help                      显示此帮助" "blue"
        ;;

    *)
        # 部署指定服务
        svc_name="${SUBCMD}"

        # 检查是否有 --tag 参数
        tag=""
        if echo "${REST}" | grep -q "\-\-tag"; then
            tag=$(echo "${REST}" | sed 's/.*--tag[[:space:]]*//' | awk '{print $1}')
        fi

        svc_dir="${WORKSPACE_DIR}/${svc_name}"
        if [ ! -f "${svc_dir}/service.yaml" ]; then
            output_card "错误" "服务不存在: ${svc_name}
请先在 workspace/${svc_name}/ 下创建 service.yaml
模板: cp cicd/service-deploy/service.yaml.example workspace/${svc_name}/service.yaml" "red"
            exit 0
        fi

        # 构建部署命令
        deploy_args="--service-dir ${svc_dir}"
        if [ -n "${tag}" ]; then
            deploy_args="${deploy_args} --tag ${tag}"
        fi

        # 执行部署
        info "开始部署服务: ${svc_name} (tag: ${tag:-latest})"
        result=$(bash "${DEPLOY_SCRIPT}" ${deploy_args} 2>&1)
        exit_code=$?

        if [ ${exit_code} -eq 0 ]; then
            output_card "部署成功: ${svc_name}" "${result}" "green"
        else
            output_card "部署失败: ${svc_name}" "${result}" "red"
        fi
        ;;
esac
