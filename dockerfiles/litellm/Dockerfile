# ============================================================
# DevPilot LiteLLM 代理镜像
# 复刻 CC-Switch 官方“本地路由”：对 Claude Code 暴露 Anthropic Messages
# 端点（/v1/messages），翻译成 OpenAI Chat Completions 转发给各平台
# （agnes / deepseek / glm / ark / bailian），使 5 个平台均可被 Claude Code 使用。
# ============================================================

FROM python:3.13-slim

LABEL org.opencontainers.image.title="devpilot-litellm" \
      org.opencontainers.image.description="LiteLLM proxy: Anthropic /v1/messages -> OpenAI Chat Completions for Claude Code"

# LiteLLM 版本（构建期参数，单一来源见 versions.env）
# 注意：1.82.7 / 1.82.8 存在供应链投毒，固定使用干净的 1.82.6
ARG LITELLM_VERSION=1.82.6
ENV LITELLM_VERSION=${LITELLM_VERSION}

RUN pip install --no-cache-dir "litellm==${LITELLM_VERSION}"

WORKDIR /app

# 配置生成脚本：读取 .env 中各平台凭据，生成 litellm_config.yaml
COPY conf/litellm/gen_config.py /app/gen_config.py

# 关键：litellm v1.82 起 /v1/messages 默认路由到 /responses API，
# 而各上游仅支持 OpenAI chat/completions；必须改回 chat/completions 转发。
ENV LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true

EXPOSE 4000

# 先生成配置（含模型注册与鉴权 master_key），再启动代理
CMD ["sh", "-c", "python /app/gen_config.py && litellm --config /app/litellm_config.yaml --port 4000 --host 0.0.0.0"]
