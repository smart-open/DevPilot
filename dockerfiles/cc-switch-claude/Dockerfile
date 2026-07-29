# syntax=docker/dockerfile:1
#
# CC-Switch Web + Claude Code + Git 合体容器镜像
#
# 构建提示：
#   - 启用 BuildKit 以支持缓存挂载（--mount=type=cache）:
#       export DOCKER_BUILDKIT=1
#   - 常规构建:
#       docker build -f dockerfiles/cc-switch-claude/Dockerfile \
#         --build-arg CC_SWITCH_VERSION=v0.21.0 \
#         --build-arg CLAUDE_CODE_VERSION=2.1.220 \
#         -t devpilot-cc-switch-claude .
#   - 强制无缓存重建（排查问题 / 跳过所有缓存层）:
#       docker build --no-cache -f dockerfiles/cc-switch-claude/Dockerfile -t devpilot-cc-switch-claude .
ARG NODE_IMAGE_TAG=22.23.1-bookworm
FROM node:${NODE_IMAGE_TAG}

LABEL org.opencontainers.image.title="devpilot-cc-switch-claude" \
      org.opencontainers.image.description="CC-Switch Web + Claude Code + Git (Combined Container)" \
      org.opencontainers.image.source="https://github.com/devpilot/devpilot" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="devpilot"

# ---- 版本参数（提前声明，供 LABEL 与后续 RUN 使用） ----
ARG CC_SWITCH_VERSION=v0.21.0
ARG CLAUDE_CODE_VERSION=2.1.220
LABEL org.opencontainers.image.version="${CC_SWITCH_VERSION}" \
      devpilot.cc-switch.version="${CC_SWITCH_VERSION}" \
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

# ---- 下载并安装 CC-Switch Web ----
RUN curl -fsSL \
    "https://github.com/Laliet/cc-switch-web/releases/download/${CC_SWITCH_VERSION}/cc-switch-server-linux-x86_64" \
    -o /usr/local/bin/cc-switch-web && \
    chmod +x /usr/local/bin/cc-switch-web

# ---- 安装 Claude Code（BuildKit 缓存挂载加速重建） ----
RUN --mount=type=cache,target=/root/.npm \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# ---- 设置工作目录和工作空间 ----
WORKDIR /workspace

# ---- 设置 HOME 目录（CC-Switch 配置存储位置） ----
ENV HOME=/home/node

# ---- 复制启动脚本并初始化目录（合并为单层） ----
COPY conf/cc-switch-claude/start.sh /usr/local/bin/start.sh
# 修复 Windows 换行符问题
RUN sed -i 's/\r$//' /usr/local/bin/start.sh \
    && chmod +x /usr/local/bin/start.sh \
    && mkdir -p /home/node/.cc-switch \
    && chown -R node:node /home/node

# ---- 暴露端口 ----
# CC-Switch Web UI 端口通过 PORT 环境变量配置（默认 8890）
EXPOSE 8890

# ---- 启动 ----
CMD ["/usr/local/bin/start.sh"]
