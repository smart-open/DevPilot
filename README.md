# DevPilot

Docker Compose 一键部署 AI 自动开发平台：飞书 AI 机器人 + Claude Code 编程助手 + Redis 缓存 + 服务自动部署。全部组件在 Docker 容器内运行，不依赖宿主机环境。Claude Code 开发的服务可自动构建并部署到 Docker / Kubernetes / 远程服务器。

## 快速开始

```bash
git clone <repo-url> devpilot && cd devpilot
./init.sh && ./deploy.sh
```

`init.sh` 配置向导只需填写 **3 个必填项**，其余密码自动生成：

- API Key（agnes-ai）
- 飞书 App ID
- 飞书 App Secret

部署完成后：

- 飞书机器人：在飞书中搜索添加机器人，发消息即可获得 AI 回复
- Claude Code：`docker compose exec cc-switch-claude claude`
- CC-Switch Web UI：浏览器打开 `http://localhost:8890`
- OpenClaw Gateway：`http://localhost:18789/healthz`

## 架构

| 容器 | 镜像 | 端口 | 职责 |
|------|------|------|------|
| Redis | `redis:8.8.1-alpine` | 6379（内部） | 缓存 + AOF/RDB 持久化 |
| OpenClaw | `node:22.23.1` + `openclaw@2026.7.1-2` | 18789 | 飞书 AI 机器人（WebSocket 长连接）+ agnes-ai 对接 |
| CC-Switch + Claude Code | `node:22.23.1` + `cc-switch@v0.21.0` + `claude-code@2.1.220` | 8890 | 供应商配置管理 + 编程助手 + Git |

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
├── init.sh                     # 配置向导（3 个必填项，密码自动生成）
├── deploy.sh                   # 一键部署脚本（7 步详细日志）
├── service.sh                  # 一键启停脚本（start/stop/restart/status/health/logs）
├── setup-skills.sh             # 技能文件安装脚本（复制到 ~/.openclaw/skills/）
├── versions.env                # 组件版本单一配置源
├── .env / .env.example         # 环境变量
├── .dockerignore               # Docker 构建优化
├── conf/                       # 配置文件
│   ├── redis/redis.conf
│   ├── openclaw/
│   └── cc-switch-claude/
├── dockerfiles/                # Dockerfile
├── skills/                     # AI 研发流程技能（7 个阶段）
│   ├── explore-SKILL.md        # 需求探索
│   ├── prd-SKILL.md            # 需求分析
│   ├── plan-SKILL.md           # 计划拆解
│   ├── dev-SKILL.md            # 开发执行
│   ├── review-SKILL.md         # 代码审查（alibaba/open-code-review）
│   ├── test-SKILL.md           # 测试验证
│   └── deploy-SKILL.md         # 提交部署
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
