# DevPilot

Docker Compose 一键部署 AI 自动开发平台：飞书 AI 机器人 + Claude Code 编程助手 + Redis 缓存 + 服务自动部署。全部组件在 Docker 容器内运行，不依赖宿主机环境。Claude Code 开发的服务可自动构建并部署到 Docker / Kubernetes / 远程服务器。

## 支持的大模型平台

DevPilot 支持 5 个主流大模型平台，通过 `LLM_PLATFORM` 环境变量选择，所有平台均走 **OpenAI Chat Completion 协议**：

| 平台名称 | 标识 | API Base URL | 默认模型 | 文档 |
|---------|------|-------------|---------|------|
| Agnes AI | `agnes` | `https://api.agnes-ai.cn/v1` | agnes-2.5-flash | [文档](https://www.agnes-ai.cn/zh-Hans/docs/agnes-25-flash) |
| DeepSeek | `deepseek` | `https://api.deepseek.com/v1` | DeepSeek-V4-Flash | [文档](https://api-docs.deepseek.com/zh-cn/) |
| GLM（智谱） | `glm` | `https://open.bigmodel.cn/api/paas/v4` | GLM-5.2 | [文档](https://docs.bigmodel.cn/cn/coding-plan/quick-start) |
| 火山方舟 | `ark` | `https://ark.cn-beijing.volces.com/api/v3` | doubao-seed-2.1-turbo | [文档](https://console.volcengine.com/ark/region:cn-beijing/docs/82379/1928261) |
| 百炼 | `bailian` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | Qwen3.7-Plus | [文档](https://bailian.console.aliyun.com) |

## 快速开始

### 系统要求
- **Docker Engine 24.0+**
- **Docker Compose v2.20+**
- **操作系统**：Linux 或 macOS（Windows 建议使用 WSL2）
- **内存**：推荐 4GB+（生产环境建议 8GB+）
- **磁盘**：推荐 10GB+ 可用空间

### 部署步骤
```bash
git clone <repo-url> devpilot && cd devpilot
./init.sh && ./deploy.sh
```

### 配置说明

`init.sh` 配置向导会引导你完成配置，流程如下：

1. **选择大模型平台**：agnes / deepseek / glm / ark / bailian
2. **配置对应平台的 API Key**
3. **配置飞书机器人**：App ID 和 App Secret
4. **其他选项**（端口、自动部署等）使用默认值即可

### 部署完成后访问

- **飞书机器人**：在飞书客户端搜索并添加机器人，发送消息即可获得 AI 回复
- **Claude Code**：运行 `docker compose exec devpilot-claude claude` 或 `make claude`
- **OpenClaw Gateway**：`http://localhost:18789/healthz`

### 一键启停（推荐使用）

```bash
./service.sh start      # 启动服务（默认 full 模式）
./service.sh start bot  # 仅启动飞书机器人
./service.sh start dev  # 仅启动开发环境
./service.sh stop       # 停止服务
./service.sh status     # 查看容器状态
./service.sh health     # 健康检查
./service.sh logs       # 查看日志
./service.sh help       # 查看完整帮助
```

### 切换大模型平台

修改 `.env` 文件中的 `LLM_PLATFORM` 和对应平台的配置：

```bash
# 切换到 DeepSeek
vi .env  # 修改 LLM_PLATFORM=deepseek，配置 DEEPSEEK_API_KEY
./service.sh restart
```

> 所有平台均走 OpenAI Chat Completion 协议，切换平台只需修改 `LLM_PLATFORM` 和对应平台的 API Key。

## 架构

| 容器 | 镜像 | 端口 | 职责 |
|------|------|------|------|
| Redis | `redis:8.8.1-alpine3.23` | 6379（内部） | 缓存 + AOF/RDB 持久化 |
| OpenClaw | `node:24.17.0` + `openclaw@2026.7.1-2` | 18789 | 飞书 AI 机器人（WebSocket 长连接）+ 多平台大模型对接 |
| Claude Code | `node:24.17.0` + `claude-code@2.1.220` | (无宿主端口，CLI 调用) | 编程助手 + Git |
| devpilot-litellm | `python:3.13-slim` + `litellm==1.82.6` | (容器内 4000，仅 docker network 内可达) | Anthropic ↔ OpenAI 协议翻译（CC-Switch 本地路由能力的复刻） |

> 组件版本统一在 [`versions.env`](versions.env) 中管理，这是版本号的单一配置源。修改版本只需编辑该文件，本地脚本与 Dockerfile 会自动加载，无需多处同步。

## 部署模式

```bash
docker compose up -d --build            # 全部启动（默认）
docker compose --profile bot up -d     # 仅飞书机器人（Redis + OpenClaw）
docker compose --profile dev up -d     # 仅开发环境（CC-Switch + Claude Code）
```

### Kubernetes 部署（Helm）

K8s 部署采用 **Helm Chart 唯一方式**，不再提供 kubectl 原生清单。统一脚本会自动从 `.env` 生成 values 并部署：

```bash
bash cicd/scripts/deploy.sh --mode k8s --helm
```

## 常用命令

```bash
# 服务管理（推荐）
./service.sh start           # 启动全部服务
./service.sh start bot       # 仅启动飞书机器人
./service.sh stop            # 停止所有服务
./service.sh status          # 查看容器状态
./service.sh health          # 健康检查
./service.sh logs redis      # 查看 Redis 日志

# Makefile 快捷命令
make init        # 配置向导
make up          # 构建并启动
make up-bot      # 仅启动飞书机器人
make up-dev      # 仅启动开发环境
make down        # 停止服务
make logs        # 查看日志
make health      # 健康检查
make claude      # 启动 Claude Code
make setup-skills # 安装技能文件到 ~/.openclaw/skills/
make help        # 查看所有命令
```

## 服务自动部署

Claude Code 在 `workspace/` 下开发的服务可自动构建并部署到 Docker / K8s / 远程服务器。在 `.env` 中开启：

```bash
DEVPILOT_AUTO_DEPLOY=true
```

开启后，开发完成钩子（`post-dev-hook.sh`）会自动检测 `workspace/` 下有变更的服务并部署。也可通过飞书 `/deploy` 命令或手动执行 `deploy-service.sh` 触发。详见 [服务自动部署文档](cicd/service-deploy/README.md)。

## AI 研发流程技能

项目内置 7 个 AI 研发流程技能，覆盖从需求探索到提交部署的完整闭环：

| 技能 | 文件 | 角色 | 门控 |
|------|------|------|------|
| 需求探索 | `explore-SKILL.md` | 产品经理 | G1 - 需求确认 |
| 需求分析 | `prd-SKILL.md` | 系统架构师 | G2 - PRD 审核 |
| 计划拆解 | `plan-SKILL.md` | 技术主管 | G3 - 计划审查 |
| 开发执行 | `dev-SKILL.md` | 全栈工程师 | 无（全自动） |
| 代码审查 | `review-SKILL.md` | 质量工程师 | 无（自动审查） |
| 测试验证 | `test-SKILL.md` | QA 工程师 | G4 - 部署验收 |
| 提交部署 | `deploy-SKILL.md` | DevOps 工程师 | G5 - 上线确认 |

```
需求探索(G1) -> 需求分析(G2) -> 计划拆解(G3) -> 开发执行 -> 代码审查 -> 测试验证(G4) -> 提交部署(G5)
```

**一键安装技能到 OpenClaw：**

```bash
make setup-skills    # 或 ./setup-skills.sh
```

技能文件将复制到 `~/.openclaw/skills/` 目录，支持多技术栈（Node.js / Python / Go / Java / Rust / .NET / PHP）、多部署目标（Docker / Docker Compose / K8s / Helm）和多代码托管平台（GitHub / Gitee / GitLab）。代码审查阶段使用 `alibaba/open-code-review`（TRAE-code-review）技能对代码变更进行智能审查。

## 目录结构

```
devpilot/
├── docker-compose.yml          # 主编排文件
├── Makefile                    # 快捷命令
├── init.sh                     # 配置向导（选择大模型平台、配置 API Key）
├── deploy.sh                   # 一键部署脚本（7 步详细日志）
├── service.sh                  # 一键启停脚本（start/stop/restart/status/health/logs）
├── setup-skills.sh             # 技能文件安装脚本（复制到 ~/.openclaw/skills/）
├── versions.env                # 组件版本单一配置源
├── .env / .env.example         # 环境变量（含多平台配置）
├── .dockerignore               # Docker 构建优化
├── conf/                       # 配置文件
│   ├── redis/redis.conf
│   ├── openclaw/
│   └── devpilot-claude/
├── dockerfiles/                # Dockerfile
├── skills/                     # AI 研发流程技能（7 个阶段）
│   ├── explore-SKILL.md        # 需求探索
│   ├── prd-SKILL.md            # 需求分析
│   ├── plan-SKILL.md           # 计划拆解
│   ├── dev-SKILL.md            # 开发执行
│   ├── review-SKILL.md         # 代码审查（alibaba/open-code-review）
│   ├── test-SKILL.md           # 测试验证
│   └── deploy-SKILL.md         # 提交部署
├── scripts/                    # 工具脚本
│   └── llm-init.sh             # 多平台大模型统一初始化脚本
├── cicd/                       # CI/CD 配置
│   ├── lib/common.sh           # 公共函数库（颜色/日志/校验/健康检查）
│   ├── ci/                     # 平台 CI（GitHub / Gitee / GitLab）
│   │   └── scripts/lint.sh     # 统一 CI Lint 检查脚本
│   ├── cd/                     # 平台 CD（Docker / K8s Helm）
│   └── service-deploy/         # 服务自动部署（开发完成 -> 自动构建部署）
└── workspace/                  # Claude Code 工作目录（开发的服务存放于此）
```

## 文档

- [用户操作手册](用户操作手册.md) - 平台使用指南（部署、飞书机器人、Claude Code、CC-Switch、技能、服务部署、FAQ）
- [运维操作手册](运维操作手册.md) - 运维管理指南（安装、配置、监控、备份、CI/CD、K8s、故障排查）
- [产品架构技术设计说明书](产品架构技术设计说明书.md) - 架构设计文档（系统架构、组件设计、数据流、安全、性能、演进规划）
- [CI/CD 文档](cicd/README.md) - 持续集成与持续部署配置（含公共函数库、版本管理、CI Lint）
- [服务自动部署](cicd/service-deploy/README.md) - Claude Code 开发的服务自动构建部署
- [环境变量模板](.env.example) - 配置项说明
- [版本配置](versions.env) - 组件版本单一配置源
