# syntax=docker/dockerfile:1
#
# Claude Code + Git 合体容器镜像（主路由由 devpilot-litellm 承担）
#
# 构建提示：
#   - 启用 BuildKit 以支持缓存挂载（--mount=type=cache）:
#       export DOCKER_BUILDKIT=1
#   - 常规构建:
#       docker build -f dockerfiles/claude/Dockerfile \
#         --build-arg CLAUDE_CODE_VERSION=2.1.241 \
#         -t devpilot-claude .
#   - 强制无缓存重建（排查问题 / 跳过所有缓存层）:
#       docker build --no-cache -f dockerfiles/claude/Dockerfile -t devpilot-claude .
# ARG 默认值须与 versions.env 保持一致（直接 docker build 不传参时也能用正确版本）
ARG NODE_IMAGE_TAG=24.17.0-bookworm
FROM node:${NODE_IMAGE_TAG}

LABEL org.opencontainers.image.title="devpilot-claude" \
      org.opencontainers.image.description="Claude Code + Git (Combined Container; LLM routing via devpilot-litellm)" \
      org.opencontainers.image.source="https://github.com/devpilot/devpilot" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="devpilot"

# ---- 版本参数（提前声明，供 LABEL 与后续 RUN 使用） ----
ARG CLAUDE_CODE_VERSION=2.1.241
LABEL org.opencontainers.image.version="${CLAUDE_CODE_VERSION}" \
      devpilot.claude-code.version="${CLAUDE_CODE_VERSION}"

# ---- 系统依赖（含 git）+ 时区（合并为单层，减少镜像层数） ----
ENV TZ=Asia/Shanghai
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    openssh-client \
    vim \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# ---- 安装 Claude Code（BuildKit 缓存挂载加速重建） ----
RUN --mount=type=cache,target=/root/.npm \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# ---- 设置工作目录和工作空间 ----
WORKDIR /workspace

# ---- 设置 HOME 目录（Claude Code 配置存储位置） ----
ENV HOME=/home/node

# ---- 复制启动脚本并初始化目录（合并为单层） ----
COPY conf/claude/start.sh /usr/local/bin/start.sh
# 修复 Windows 换行符问题
RUN sed -i 's/\r$//' /usr/local/bin/start.sh \
    && chmod +x /usr/local/bin/start.sh \
    && chown -R node:node /home/node

# ---- 以非 root 用户运行（最小权限）----
# 注意：宿主机 ./workspace 与 ./data/devpilot-claude 挂载目录需对 node 用户(uid 1000)可写；
#       否则容器内 Claude Code 写文件会权限失败。部署时可用 init container 或显式 chown 修正属主。
USER node

# ---- 启动 ----
CMD ["/usr/local/bin/start.sh"]
