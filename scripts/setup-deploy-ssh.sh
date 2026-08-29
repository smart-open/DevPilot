#!/bin/bash

# ============================================================
# DevPilot - SSH 受控部署通道一键配置（宿主机执行，需 root）
# ============================================================
# 对应《用户操作手册》4.7.3 Phase 2 的宿主机侧步骤，一次性完成：
#   1. 创建受限部署用户 devpilot-deploy（加入 docker 组以执行构建）
#   2. 生成专用密钥对
#   3. 写入 forced-command 锁定的 authorized_keys —— 无论该密钥请求执行
#      什么命令，sshd 都强制改跑 feishu-deploy-handler.sh，且禁用
#      端口转发 / X11 转发 / agent 转发 / 伪终端
#   4. 生成 known_hosts（含 host.docker.internal / 网关 IP / LAN IP 条目）
#      并把私钥 + known_hosts 放入 data/deploy-keys/（compose 只读挂载进
#      openclaw 容器 /opt/devpilot/deploy-keys）
#
# 用法（宿主机项目根目录）：
#   sudo bash scripts/setup-deploy-ssh.sh
#
# 幂等：重复执行安全（用户/密钥/authorized_keys 均存在则跳过或原样覆盖）。
#
# 配置完成后还需（见脚本末尾输出）：
#   - .env 中设置 DEPLOY_SSH_HOST=host.docker.internal
#   - docker compose up -d --build openclaw（镜像新增 openssh-client）
# ============================================================

set -euo pipefail

# ---- 简单输出函数（独立于 common.sh，避免路径耦合） ----
info()  { echo -e "\033[36m[setup-deploy-ssh]\033[0m $*"; }
ok()    { echo -e "\033[32m[setup-deploy-ssh]\033[0m ✓ $*"; }
warn()  { echo -e "\033[33m[setup-deploy-ssh]\033[0m ! $*" >&2; }
die()   { echo -e "\033[31m[setup-deploy-ssh]\033[0m ✗ $*" >&2; exit 1; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLER="${PROJECT_ROOT}/cicd/service-deploy/feishu-deploy-handler.sh"
DEPLOY_USER="devpilot-deploy"
SSH_HOME="/home/${DEPLOY_USER}"
KEY_NAME="id_ed25519"
KEY_DIR="${PROJECT_ROOT}/data/deploy-keys"

# ============================================================
# 1. 前置检查
# ============================================================
[ "$(id -u)" -eq 0 ] || die "请以 root 运行: sudo bash scripts/setup-deploy-ssh.sh"

[ -f "${HANDLER}" ] || die "未找到部署处理器: ${HANDLER}"

command -v ssh-keygen &>/dev/null || die "缺少 ssh-keygen（安装 openssh-server/openssh-client）"
command -v ssh-keyscan &>/dev/null || die "缺少 ssh-keyscan（安装 openssh-client）"

# sshd 运行状态（systemd 与非 systemd 两套探测）
SSHD_OK=0
if command -v systemctl &>/dev/null && systemctl is-active ssh sshd 2>/dev/null | grep -q active; then
    SSHD_OK=1
elif pgrep -x sshd &>/dev/null; then
    SSHD_OK=1
fi
[ "${SSHD_OK}" -eq 1 ] || warn "未探测到运行中的 sshd——请确认 openssh-server 已启动，否则容器无法连入"

command -v docker &>/dev/null || die "宿主机缺少 docker CLI（本通道的核心就是宿主机代为构建）"
docker info &>/dev/null || die "docker daemon 不可达（docker info 失败）"

# ============================================================
# 2. 受限部署用户（幂等）
# ============================================================
if id "${DEPLOY_USER}" &>/dev/null; then
    ok "用户 ${DEPLOY_USER} 已存在，跳过创建"
else
    useradd -m -s /bin/bash "${DEPLOY_USER}"
    ok "已创建受限用户 ${DEPLOY_USER}"
fi

# 构建需要 docker CLI；forced-command 已限制该用户只能跑部署处理器，
# 无法直接执行 docker run 等任意命令
if id -nG "${DEPLOY_USER}" | tr ' ' '\n' | grep -qx docker; then
    ok "${DEPLOY_USER} 已在 docker 组"
else
    usermod -aG docker "${DEPLOY_USER}"
    ok "已将 ${DEPLOY_USER} 加入 docker 组（执行构建）"
fi

# 项目目录读权限检查（git 仓库默认 755/644 可满足；不满足时给出提示）
if ! sudo -u "${DEPLOY_USER}" test -r "${HANDLER}"; then
    warn "${DEPLOY_USER} 无法读取 ${HANDLER}，部署时会被拒绝"
    warn "检查项目目录权限: ls -ld ${PROJECT_ROOT}（需 o+rx）"
fi

# ============================================================
# 3. 专用密钥对（幂等：已存在不覆盖）
# ============================================================
mkdir -p "${SSH_HOME}/.ssh"
if [ -f "${SSH_HOME}/.ssh/${KEY_NAME}" ]; then
    ok "密钥已存在，复用: ${SSH_HOME}/.ssh/${KEY_NAME}"
else
    ssh-keygen -t ed25519 -f "${SSH_HOME}/.ssh/${KEY_NAME}" -N "" -C "devpilot-deploy-channel" -q
    ok "已生成密钥对: ${SSH_HOME}/.ssh/${KEY_NAME}"
fi

# ============================================================
# 4. forced-command 锁定的 authorized_keys
# ============================================================
# 注意转义：authorized_keys 内字面保留 "$SSH_ORIGINAL_COMMAND"，
# 由远端 shell 在执行时展开为用户请求的原始命令（作为单一参数，无注入面）
PUB_KEY="$(cat "${SSH_HOME}/.ssh/${KEY_NAME}.pub")"
cat > "${SSH_HOME}/.ssh/authorized_keys" <<EOF
command="bash ${HANDLER} \"\$SSH_ORIGINAL_COMMAND\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${PUB_KEY}
EOF
chmod 700 "${SSH_HOME}/.ssh"
chmod 600 "${SSH_HOME}/.ssh/authorized_keys" "${SSH_HOME}/.ssh/${KEY_NAME}"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${SSH_HOME}/.ssh"
ok "已写入 forced-command 锁定的 authorized_keys（只能执行部署处理器）"

# ============================================================
# 5. known_hosts + 私钥 → data/deploy-keys/（compose 挂载源）
# ============================================================
# known_hosts 条目需与容器内连接目标名匹配，收集多个候选名：
#   - host.docker.internal（DEPLOY_SSH_HOST 默认值，compose extra_hosts → host-gateway）
#   - devpilot-network 网关 IP（host-gateway 的实际值）
#   - 宿主机 LAN IP（.env 显式指定 LAN IP 的场景）
HOST_ENTRY="host.docker.internal"
GATEWAY_IP="$(docker network inspect devpilot-network -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
[ -n "${GATEWAY_IP}" ] && HOST_ENTRY="${HOST_ENTRY},${GATEWAY_IP}"
LAN_IP="$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
[ -n "${LAN_IP}" ] && HOST_ENTRY="${HOST_ENTRY},${LAN_IP}"

# ssh-keyscan localhost 采集的就是本机 sshd host key（与容器经网关连入是同一 sshd），
# 把条目主机名替换为上述候选名集合
if ssh-keyscan -t ed25519 localhost 2>/dev/null | sed "s/^localhost /${HOST_ENTRY} /" > /tmp/devpilot-known-hosts.$$ \
   && [ -s /tmp/devpilot-known-hosts.$$ ]; then
    mv /tmp/devpilot-known-hosts.$$ /tmp/devpilot-known-hosts
else
    rm -f /tmp/devpilot-known-hosts.$$
    die "ssh-keyscan 采集宿主机 host key 失败（sshd 未运行或端口非 22）"
fi

mkdir -p "${KEY_DIR}"
cp "${SSH_HOME}/.ssh/${KEY_NAME}" "${KEY_DIR}/${KEY_NAME}"
cp /tmp/devpilot-known-hosts "${KEY_DIR}/known_hosts"
rm -f /tmp/devpilot-known-hosts
# 私钥 600（ssh 客户端硬性要求，否则拒绝使用）；known_hosts 644 可读
chmod 600 "${KEY_DIR}/${KEY_NAME}"
chmod 644 "${KEY_DIR}/known_hosts"
ok "已生成 ${KEY_DIR}/id_ed25519 + known_hosts（条目: ${HOST_ENTRY}）"

# ============================================================
# 6. 本机连通性自测（模拟容器视角，验证 forced-command 生效）
# ============================================================
info "自测受控通道（同机模拟，应返回 /deploy 帮助卡片而非任意命令执行）..."
TEST_OUT="$(sudo -u "${DEPLOY_USER}" ssh -o BatchMode=yes -o ConnectTimeout=5 \
    -o UserKnownHostsFile="${KEY_DIR}/known_hosts" -o CheckHostIP=no \
    -i "${SSH_HOME}/.ssh/${KEY_NAME}" \
    "${DEPLOY_USER}@localhost" "/deploy --help" 2>&1 || true)"
if echo "${TEST_OUT}" | grep -q "部署命令帮助"; then
    ok "受控通道自测通过（forced-command 正常锁定）"
else
    warn "自测输出异常（可能仍可用，建议人工复核）:"
    echo "${TEST_OUT}" | sed 's/^/    /'
fi

# ============================================================
# 7. 后续步骤提示
# ============================================================
echo ""
info "宿主机侧配置完成。还需以下步骤启用通道："
echo "  1. ${PROJECT_ROOT}/.env 中设置（默认值即可，无需填 IP）:"
echo "       DEPLOY_SSH_HOST=host.docker.internal"
echo "  2. 重建并重启 openclaw（镜像新增 openssh-client）:"
echo "       docker compose up -d --build openclaw"
echo "  3. 容器内验证通道:"
echo "       docker compose exec openclaw bash /opt/devpilot/cicd/service-deploy/feishu-deploy-handler.sh \"/deploy --list\""
echo "     输出应含 [ssh] 转发标记与真实服务列表（而非「请在宿主机执行」拦截提示）"
echo "  4. 飞书发送 /deploy --list 做端到端验收"
