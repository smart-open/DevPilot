# syntax=docker/dockerfile:1
#
# OpenClaw 镜像（飞书 AI 机器人 + agnes-ai，WebSocket 长连接）
#
# 构建提示：
#   - 启用 BuildKit 以支持缓存挂载（--mount=type=cache）:
#       export DOCKER_BUILDKIT=1
#   - 常规构建:
#       docker build -f dockerfiles/openclaw/Dockerfile \
#         --build-arg OPENCLAW_VERSION=2026.7.1-2 \
#         -t devpilot-openclaw .
#   - 强制无缓存重建（排查问题 / 跳过所有缓存层）:
#       docker build --no-cache -f dockerfiles/openclaw/Dockerfile -t devpilot-openclaw .
# ARG 默认值须与 versions.env 保持一致（直接 docker build 不传参时也能用正确版本）
ARG NODE_IMAGE_TAG=24.17.0-bookworm
FROM node:${NODE_IMAGE_TAG}

LABEL org.opencontainers.image.title="devpilot-openclaw" \
      org.opencontainers.image.description="OpenClaw - Feishu AI Bot with agnes-ai (Long Connection)" \
      org.opencontainers.image.source="https://github.com/devpilot/devpilot" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="devpilot"

# ---- 系统依赖（安装与清理合并为单层，减少镜像层数） ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---- 设置时区 ----
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# ---- 安装 OpenClaw（BuildKit 缓存挂载加速重建） ----
ARG OPENCLAW_VERSION=2026.7.1-2
LABEL org.opencontainers.image.version="${OPENCLAW_VERSION}"
RUN --mount=type=cache,target=/root/.npm \
    npm install -g openclaw@${OPENCLAW_VERSION}

# ---- 创建工作目录 ----
WORKDIR /app

# ---- 复制配置文件 ----
COPY conf/openclaw/openclaw.default.json /app/conf/openclaw.default.json
COPY conf/openclaw/init-openclaw.sh /app/conf/init-openclaw.sh
# 公共函数库（含 configure_platform 等）：镜像内 init-openclaw.sh 直接 source，
# 不重新在镜像里塞一份完整 cicd/ 树。
COPY cicd/lib/common.sh /usr/local/lib/devpilot-common.sh
# 修复 Windows 换行符问题
RUN sed -i 's/\r$//' /app/conf/init-openclaw.sh /usr/local/lib/devpilot-common.sh \
    && chmod +x /app/conf/init-openclaw.sh /usr/local/lib/devpilot-common.sh

# ---- 环境变量 ----
ENV OPENCLAW_HOME=/data/openclaw
ENV NODE_ENV=production

# ---- 暴露 Gateway 端口 ----
EXPOSE 18789

# ---- 健康检查 ----
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://127.0.0.1:18789/healthz || exit 1

# ---- 启动 ----
CMD ["/app/conf/init-openclaw.sh"]
