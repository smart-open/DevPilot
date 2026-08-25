#!/bin/bash
set -e

# ============================================================
# DevPilot Claude Code + LiteLLM 合体容器入口脚本
# 问题背景：
#   docker-compose.yml 将宿主机 ./data/devpilot-claude bind mount 到
#   /home/node（用于持久化 Claude Code 配置）。该挂载点会覆盖镜像层里
#   构建期 chown 的结果，在容器内对 node(uid 1000) 不可写，导致 start.sh
#   执行 `mkdir -p $HOME/.claude` 报 Permission denied 并因 set -e 退出。
# 修复策略：
#   1) 以 root 启动时，先把 /home/node（挂载点）属主修正为 node:node；
#   2) 再降权回 node 用户执行 start.sh，保持最小权限，且 claude 写入
#      /workspace 的文件属主仍为 node（而非 root）。
# 注：在 Docker Desktop(Windows/Mac) 上 chown 作用于挂载的容器内视图，
#     足以让 node 在容器内获得写权限；Linux 原生 bind mount 同理。
# ============================================================

if [ "$(id -u)" = "0" ]; then
  # 修正挂载点属主，使其对 node 可写（失败不影响后续，2>/dev/null 兜底）
  chown -R node:node /home/node 2>/dev/null || true
  # 确保目录本身对 node 可执行/可进入
  chmod 755 /home/node 2>/dev/null || true
  # 降权回 node 用户执行 start.sh：
  #   - runuser（util-linux，首选）：不重置 PAM/环境，完整保留 compose 注入的
  #     环境变量（API Key 等），仅切换 uid/gid 到 node，HOME 正确指向 /home/node。
  #   - 回退 su node：兼容未装 runuser 的镜像。
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u node -- /usr/local/bin/start.sh
  else
    exec su node -s /bin/bash -c 'exec /usr/local/bin/start.sh'
  fi
fi

# 非 root 直接运行（如本地调试），原样启动
exec /usr/local/bin/start.sh
