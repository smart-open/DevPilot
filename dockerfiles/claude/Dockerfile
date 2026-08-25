# syntax=docker/dockerfile:1
#
# DevPilot Claude Code + LiteLLM 合体容器镜像
# 合并原 devpilot-claude 与 devpilot-litellm 两个容器为一个：
#   - Claude Code（node + @anthropic-ai/claude-code）
#   - LiteLLM 代理（python3 venv + litellm，Anthropic↔OpenAI 翻译）
# 启动时由 start.sh 后台拉起 litellm（监听 0.0.0.0:4000），
# Claude Code 经同容器 http://127.0.0.1:4000 访问，无需跨容器网络。
#
# 构建提示：
#   - 启用 BuildKit 以支持缓存挂载（--mount=type=cache）:
#       export DOCKER_BUILDKIT=1
#   - 常规构建:
#       docker build -f dockerfiles/claude/Dockerfile \
#         --build-arg CLAUDE_CODE_VERSION=2.1.241 \
#         --build-arg LITELLM_VERSION=1.82.6 \
#         -t devpilot-claude-litellm .

# ARG 默认值须与 versions.env 保持一致（直接 docker build 不传参时也能用正确版本）
ARG NODE_IMAGE_TAG=24.17.0-bookworm
FROM node:${NODE_IMAGE_TAG}

LABEL org.opencontainers.image.title="devpilot-claude-litellm" \
      org.opencontainers.image.description="Claude Code + LiteLLM (combined container; Anthropic<->OpenAI translation)" \
      org.opencontainers.image.source="https://github.com/devpilot/devpilot" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="devpilot"

# ---- 版本参数（提前声明，供 LABEL 与后续 RUN 使用） ----
ARG CLAUDE_CODE_VERSION=2.1.241
ARG LITELLM_VERSION=1.82.6
LABEL org.opencontainers.image.version="claude-${CLAUDE_CODE_VERSION}/litellm-${LITELLM_VERSION}" \
      devpilot.claude-code.version="${CLAUDE_CODE_VERSION}" \
      devpilot.litellm.version="${LITELLM_VERSION}"

# ---- 系统依赖：claude（git/curl）+ litellm（python3/venv），合并单层 ----
ENV TZ=Asia/Shanghai
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    openssh-client \
    vim \
    python3 \
    python3-venv \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# ---- 安装 Claude Code（BuildKit 缓存挂载加速重建） ----
RUN --mount=type=cache,target=/root/.npm \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# ---- 安装 LiteLLM（venv 隔离，不污染系统 python；固定 1.82.6，1.82.7/1.82.8 投毒） ----
# 供应链加固：固定版本已大幅降低投毒风险；进一步可改用 --require-hashes + pip-compile 锁文件
RUN python3 -m venv /opt/litellm/venv \
    && /opt/litellm/venv/bin/pip install --no-cache-dir "litellm==${LITELLM_VERSION}"

# litellm v1.82 起 /v1/messages 默认路由到 /responses API，
# 而各上游仅支持 OpenAI chat/completions；必须改回 chat/completions 转发。
ENV LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true

# ---- 设置工作目录与 HOME ----
WORKDIR /workspace
ENV HOME=/home/node

# ---- litellm 配置目录（gen_config.py 输出 litellm_config.yaml，需 node 可写） ----
RUN mkdir -p /opt/litellm && chown -R node:node /opt/litellm /home/node

# ---- 复制启动脚本 + litellm 配置生成器 ----
COPY conf/claude/start.sh /usr/local/bin/start.sh
COPY conf/litellm/gen_config.py /opt/litellm/gen_config.py
# 修复 Windows 换行符问题
RUN sed -i 's/\r$//' /usr/local/bin/start.sh /opt/litellm/gen_config.py \
    && chmod +x /usr/local/bin/start.sh

# ---- 以非 root 用户运行（最小权限）----
# 注意：宿主机 ./workspace 与 ./data/devpilot-claude 挂载目录需对 node 用户(uid 1000)可写；
#       否则容器内 Claude Code 写文件会权限失败。部署时可用 init container 或显式 chown 修正属主。
USER node

# ---- 启动（后台 litellm + Claude Code 保活） ----
CMD ["/usr/local/bin/start.sh"]
