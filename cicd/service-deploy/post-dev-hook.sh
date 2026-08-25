#!/bin/bash
set -e

# ============================================================
# DevPilot - 开发完成后自动触发部署钩子
# Claude Code 开发会话结束后自动调用此脚本
# 检测 workspace/ 下有变更的服务并自动部署
#
# 用法:
#   ./post-dev-hook.sh                    # 部署所有有变更的服务
#   ./post-dev-hook.sh --service <name>   # 仅部署指定服务
#   ./post-dev-hook.sh --all              # 部署所有含 service.yaml 的服务
#
# 集成方式:
#   在 devpilot-claude-litellm 容器的 start.sh 中添加（通过环境变量控制）：
#   if [ "$DEVPILOT_AUTO_DEPLOY" = "true" ]; then
#       bash /workspace/cicd/service-deploy/post-dev-hook.sh
#   fi
# ============================================================

# ---- 加载公共函数库（颜色定义、日志函数等） ----
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

# ---- 定位脚本目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# 允许调用方（如容器内 start.sh）通过环境变量覆盖 workspace 路径，
# 否则按宿主机布局推算（SCRIPT_DIR/../.. 的 workspace 子目录）。
WORKSPACE_DIR="${WORKSPACE_DIR:-${PROJECT_ROOT}/workspace}"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-service.sh"

# ---- 参数解析 ----
TARGET_SERVICE=""
DEPLOY_ALL="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service)
            TARGET_SERVICE="$2"
            shift 2
            ;;
        --all)
            DEPLOY_ALL="true"
            shift
            ;;
        --help|-h)
            echo "用法: post-dev-hook.sh [--service <name>] [--all]"
            echo ""
            echo "  无参数    部署所有有变更的服务"
            echo "  --service 部署指定服务"
            echo "  --all     部署所有含 service.yaml 的服务"
            exit 0
            ;;
        *)
            error "未知参数: $1"
            exit 1
            ;;
    esac
done

echo ""
echo -e "${MAGENTA}========================================${NC}"
echo -e "${MAGENTA}  DevPilot Post-Dev 自动部署钩子${NC}"
echo -e "${MAGENTA}========================================${NC}"
echo ""

# 检查 workspace 目录
if [ ! -d "${WORKSPACE_DIR}" ]; then
    warn "workspace 目录不存在: ${WORKSPACE_DIR}"
    exit 0
fi

# 检查部署脚本
if [ ! -f "${DEPLOY_SCRIPT}" ]; then
    error "部署脚本不存在: ${DEPLOY_SCRIPT}"
    exit 1
fi

# ---- 查找可部署的服务 ----
SERVICES=()

for dir in "${WORKSPACE_DIR}"/*/; do
    if [ -f "${dir}service.yaml" ]; then
        local_name=$(basename "${dir}")
        # 如果指定了服务名，只匹配该服务
        if [ -n "${TARGET_SERVICE}" ] && [ "${local_name}" != "${TARGET_SERVICE}" ]; then
            continue
        fi
        SERVICES+=("${local_name}")
    fi
done

if [ ${#SERVICES[@]} -eq 0 ]; then
    if [ -n "${TARGET_SERVICE}" ]; then
        warn "未找到服务: ${TARGET_SERVICE}"
        echo -e "  请确认 workspace/${TARGET_SERVICE}/service.yaml 存在"
    else
        warn "未找到任何可部署的服务"
        echo -e "  在 workspace/ 下的服务目录中创建 service.yaml 即可"
    fi
    exit 0
fi

info "发现 ${#SERVICES[@]} 个服务: ${SERVICES[*]}"
echo ""

# ---- 部署服务 ----
deployed=0
failed=0
skipped=0

for svc in "${SERVICES[@]}"; do
    svc_dir="${WORKSPACE_DIR}/${svc}"
    timestamp_file="${svc_dir}/.devpilot-last-deploy"

    # 检查是否有变更（非 --all 模式）
    if [ "${DEPLOY_ALL}" = "false" ] && [ -z "${TARGET_SERVICE}" ]; then
        if [ -f "${timestamp_file}" ]; then
            last_deploy=$(cat "${timestamp_file}" 2>/dev/null)
            # 检查 service.yaml 和源码文件的修改时间
            has_changes=false
            while IFS= read -r -d '' file; do
                file_mtime=$(stat -c %Y "${file}" 2>/dev/null || stat -f %m "${file}" 2>/dev/null || echo 0)
                if [ "${file_mtime}" -gt "${last_deploy}" ]; then
                    has_changes=true
                    break
                fi
            done < <(find "${svc_dir}" -type f -not -name '.devpilot-*' -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 2>/dev/null)

            if [ "${has_changes}" = "false" ]; then
                info "服务 ${svc} 无变更，跳过"
                skipped=$((skipped + 1))
                continue
            fi
        fi
    fi

    info "部署服务: ${svc}"
    if bash "${DEPLOY_SCRIPT}" --service-dir "${svc_dir}"; then
        success "服务 ${svc} 部署成功"
        date +%s > "${timestamp_file}"
        deployed=$((deployed + 1))
    else
        error "服务 ${svc} 部署失败"
        failed=$((failed + 1))
    fi
    echo ""
done

# ---- 输出摘要 ----
echo -e "${MAGENTA}========================================${NC}"
echo -e "${MAGENTA}  自动部署摘要${NC}"
echo -e "${MAGENTA}========================================${NC}"
echo ""
echo -e "  ${GREEN}成功: ${deployed}${NC}"
echo -e "  ${YELLOW}跳过: ${skipped}${NC}"
echo -e "  ${RED}失败: ${failed}${NC}"
echo ""

if [ ${failed} -gt 0 ]; then
    exit 1
fi
