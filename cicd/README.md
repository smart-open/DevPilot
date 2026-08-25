# DevPilot CI/CD 配置文档

> DevPilot 项目的持续集成与持续部署完整方案，支持 GitHub / Gitee / GitLab CI 流水线，以及 Docker Compose / Docker Run / 远程 Docker / Kubernetes（Helm）多种部署方式。

---

## 目录

- [概述](#概述)
- [目录结构](#目录结构)
- [公共函数库 (common.sh)](#公共函数库-commonsh)
- [版本管理 (versions.env)](#版本管理-versionsenv)
- [CI Lint 检查 (lint.sh)](#ci-lint-检查-lintsh)
- [CI 持续集成](#ci-持续集成)
  - [GitHub Actions](#github-actions)
  - [Gitee Go](#gitee-go)
  - [GitLab CI](#gitlab-ci)
  - [CI 变量配置](#ci-变量配置)
- [CD 持续部署](#cd-持续部署)
  - [Docker 本地部署](#docker-本地部署)
  - [Docker 远程部署](#docker-远程部署)
  - [Kubernetes Helm Chart](#kubernetes-helm-chart)
- [统一部署脚本](#统一部署脚本)
- [服务自动部署](#服务自动部署)
- [环境变量参考](#环境变量参考)
- [Docker 构建参数](#docker-构建参数)
- [脚本规范](#脚本规范)
- [快速开始](#快速开始)
- [常见问题](#常见问题)

---

## 概述

DevPilot CI/CD 体系围绕 3 个 Docker 容器构建：

| 容器 | 镜像基础 | 版本 | 端口 |
|------|---------|------|------|
| Redis | `redis:8.8.1-alpine` | 8.8.1 | 6379（仅内部） |
| OpenClaw | `node:22.23.1-bookworm` | `openclaw@2026.7.1-2` | 18789 |
| Claude Code | `node:22.23.1-bookworm` | `claude-code@2.1.241` | - |

CI 负责代码检查、镜像构建、镜像推送和安全扫描；CD 负责将构建好的镜像部署到不同环境。

---

## 目录结构

```
cicd/
├── README.md                          # 本文档
├── lib/
│   └── common.sh                      # 公共函数库（所有脚本共享）
│
├── ci/                                # 平台持续集成配置（部署 DevPilot 本身）
│   ├── scripts/
│   │   └── lint.sh                    # 统一 CI Lint 检查脚本
│   ├── github/
│   │   └── workflows/
│   │       └── ci.yml                 # GitHub Actions 工作流
│   ├── gitee/
│   │   └── workflows/
│   │       └── ci.yml                 # Gitee Go 流水线
│   └── gitlab/
│       └── .gitlab-ci.yml             # GitLab CI/CD 配置
│
├── cd/                                # 平台持续部署配置（部署 DevPilot 本身）
│   ├── docker-local/
│   │   ├── deploy.sh                  # 本地 docker compose 部署
│   │   └── docker-run.sh              # 本地 docker run 部署（不依赖 compose）
│   │
│   ├── docker-remote/
│   │   ├── deploy-remote.sh           # 远程 Docker 部署
│   │   └── docker-remote.conf.example  # 远程连接配置示例
│   │
│   └── k8s/
│       └── helm/
│           └── devpilot/              # Helm Chart（K8s 唯一部署方式）
│               ├── Chart.yaml
│               ├── values.yaml
│               └── templates/
│                   ├── _helpers.tpl
│                   ├── configmap.yaml
│                   ├── secret.yaml
│                   ├── deployment.yaml
│                   ├── service.yaml
│                   └── ingress.yaml
│
├── service-deploy/                    # 服务自动部署（部署 Claude Code 开发的服务）
│   ├── README.md                      # 服务自动部署文档
│   ├── deploy-service.sh              # 核心部署脚本
│   ├── post-dev-hook.sh               # 开发完成后自动部署钩子
│   ├── feishu-deploy-handler.sh       # 飞书 Bot 部署命令处理器
│   ├── service.yaml.example           # 服务部署描述符模板
│   ├── lib/
│   │   └── yaml-parser.sh            # 轻量级 YAML 解析库
│   ├── k8s/
│   │   └── service-template.yaml      # K8s 服务部署模板
│   └── ci/                            # 服务部署 CI 工作流
│       ├── github/workflows/
│       │   └── service-deploy.yml     # GitHub Actions
│       ├── gitee/workflows/
│       │   └── service-deploy.yml     # Gitee Go
│       └── gitlab/
│           └── .gitlab-ci-service-deploy.yml  # GitLab CI
│
└── scripts/
    └── deploy.sh                     # 统一部署交互脚本
```

> 注：K8s 部署已统一为 Helm Chart 方式，不再提供 kubectl 原生清单。

---

## 公共函数库 (common.sh)

**文件**：`cicd/lib/common.sh`

所有部署、CI、CD 脚本通过 `source` 加载此文件，消除重复代码、统一行为规范。`init.sh`、`deploy.sh`、各 CD 脚本与服务部署脚本均依赖此库。

**加载方式**：

```bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
```

**提供的函数与能力**：

| 类别 | 函数 | 说明 |
|------|------|------|
| 日志输出 | `info` / `success` / `warn` / `error` / `die` | 统一带颜色的日志输出 |
| 排版 | `print_separator` / `print_header` | 分隔线与标题块 |
| 路径定位 | `get_project_root` | 向上回溯定位项目根目录 |
| 环境变量 | `load_env` | 加载 `.env` 文件并导出变量 |
| 环境变量 | `validate_required_vars` / `validate_devpilot_env` | 校验必需变量 |
| 命令执行 | `run_cmd` | 支持 `DRY_RUN` 模式的命令执行 |
| 健康检查 | `wait_for_http` / `wait_for_container_http` / `wait_for_redis` | 等待服务就绪 |
| Docker 辅助 | `ensure_docker_network` / `remove_container_if_exists` / `create_data_dirs` | 幂等的 Docker 操作 |
| 密码生成 | `gen_password` | 生成随机十六进制密码 |
| 错误处理 | `setup_error_trap` | 捕获错误并报告行号 |

同时导出统一的颜色常量（`RED` / `GREEN` / `YELLOW` / `BLUE` / `CYAN` / `MAGENTA` / `NC`），所有脚本共用，无需各自定义。

---

## 版本管理 (versions.env)

**文件**：`versions.env`（位于项目根目录）

这是组件版本的**单一配置源**，集中管理所有组件版本号：

```bash
NODE_IMAGE_TAG=22.23.1-bookworm      # Node.js 基础镜像版本
OPENCLAW_VERSION=2026.7.1-2          # OpenClaw 版本
CLAUDE_CODE_VERSION=2.1.241          # Claude Code 版本
```

**加载机制**：

- `init.sh` 配置向导自动 `source versions.env`，无需手动询问版本号
- 各部署脚本通过 `common.sh` 间接使用这些版本变量
- Dockerfile 通过 `--build-arg` 接收版本参数

**修改版本**：

只需编辑 `versions.env`，本地脚本与 Dockerfile 会自动加载新版本。CI 流水线的 `env` 块中保留与 `versions.env` 对齐的默认值，升级时需同步更新以保持一致。

---

## CI Lint 检查 (lint.sh)

**文件**：`cicd/ci/scripts/lint.sh`

共享的 CI 代码质量与安全校验脚本，所有 CI 平台（GitHub / Gitee / GitLab）可统一调用，也可本地手动执行。

**用法**：

```bash
bash cicd/ci/scripts/lint.sh
```

**检查项**：

| 检查 | 级别 | 说明 |
|------|------|------|
| Shell 脚本语法 | 必须 | 对所有 `.sh` 文件执行 `bash -n` 语法检查 |
| YAML 合法性 | 必须 | 校验所有 YAML 文件（优先 python3+PyYAML，回退基础结构检查；含 `{{` 占位符的模板降级为基础检查） |
| 硬编码密钥扫描 | 必须 | 扫描脚本中的高置信度密钥模式（AWS / GitHub / Slack / Stripe / Google / OpenAI / 私钥）及赋值式硬编码密钥 |
| 可执行权限 | 报告 | 检查脚本是否具备可执行权限（仅告警，不影响退出码） |

**退出码**：`0` 表示所有必须检查通过，`1` 表示存在失败项。

该脚本自身通过 `source` 加载 `cicd/lib/common.sh`，复用统一的日志与排版函数。

---

## CI 持续集成

### GitHub Actions

**文件**：`cicd/ci/github/workflows/ci.yml`

**触发条件**：
- 推送到 `main` / `master` 分支
- 针对 `main` / `master` 的 Pull Request
- 手动触发（`workflow_dispatch`）

**流水线阶段**：

| 阶段 | 任务名 | 说明 |
|------|--------|------|
| Lint | `lint` | Shell 脚本语法检查、Dockerfile 存在性检查、docker-compose.yml 语法校验、`.env.example` 变量完整性检查 |
| Build | `build-openclaw` | 构建 OpenClaw 镜像，推送至 `ghcr.io`，缓存 Docker 层 |
| Build | `build-devpilot-claude-litellm` | 构建 devpilot-claude-litellm 镜像，推送至 `ghcr.io`，缓存 Docker 层 |
| Scan | `security-scan` | Trivy 安全扫描两个镜像 + 文件系统扫描，结果上传至 GitHub Security |

**镜像仓库**：GitHub Container Registry（`ghcr.io`）

**镜像标签策略**：
- `latest`（默认分支）
- 分支名（如 `main`）
- PR 编号
- commit SHA（`sha-<短哈希>`）

**Docker 层缓存**：使用 GitHub Actions Cache（`type=gha`），按镜像名分 scope：
- `openclaw` scope
- `devpilot-claude-litellm` scope

**使用方式**：

该文件需要放置在仓库根目录的 `.github/workflows/` 下（或直接使用此路径）：

```bash
# 创建符号链接或复制到 .github/workflows/
mkdir -p .github/workflows
cp cicd/ci/github/workflows/ci.yml .github/workflows/ci.yml
```

**所需 Secrets**：

| Secret 名 | 说明 |
|-----------|------|
| `GITHUB_TOKEN` | GitHub 自动提供，用于推送镜像到 GHCR |

无需额外配置 Secret，`GITHUB_TOKEN` 由 GitHub Actions 自动注入。

---

### Gitee Go

**文件**：`cicd/ci/gitee/workflows/ci.yml`

**触发条件**：
- 推送到 `master` / `main` 分支
- 针对对 `master` / `main` 的 Pull Request

**流水线阶段**：

| 阶段 | 阶段名 | 说明 |
|------|--------|------|
| 1 | `lint-stage` | Shell 语法检查、Dockerfile 检查、compose 语法校验、env 模板检查 |
| 2 | `build-stage` | 构建 OpenClaw 和 devpilot-claude-litellm 两个镜像 |
| 3 | `push-stage` | 登录镜像仓库并推送镜像（需配置仓库变量） |
| 4 | `scan-stage` | Trivy 安全扫描镜像和文件系统 |

**镜像仓库**：Gitee 容器镜像仓库或自定义仓库（如阿里云 ACR）

**所需流水线变量**：

在 Gitee Go 流水线设置中配置以下变量：

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `REGISTRY` | 镜像仓库地址 | `registry.cn-beijing.aliyuncs.com` |
| `REGISTRY_USER` | 仓库用户名 | `your-username` |
| `REGISTRY_PASSWORD` | 仓库密码/Token | `your-password` |
| `REGISTRY_NAMESPACE` | 镜像命名空间 | `devpilot` |

> 如果未配置仓库变量，推送阶段会自动跳过，不影响构建和扫描。

**使用方式**：

Gitee Go 需要将流水线配置文件放在仓库根目录的 `.workflow/` 目录下：

```bash
mkdir -p .workflow
cp cicd/ci/gitee/workflows/ci.yml .workflow/devpilot-ci.yml
```

或在 Gitee Go 流水线配置界面中直接指定文件路径。

---

### GitLab CI

**文件**：`cicd/ci/gitlab/.gitlab-ci.yml`

**触发条件**：
- 针对 `main` / `master` 的 Merge Request
- 推送到 `main` / `master` 分支
- 手动触发

**流水线阶段**：

| 阶段 | 任务 | 说明 |
|------|------|------|
| `lint` | `lint:shell-scripts` | Shell 脚本语法检查 |
| `lint` | `lint:dockerfiles` | Dockerfile 存在性检查 |
| `lint` | `lint:compose` | docker-compose.yml 语法校验 |
| `lint` | `lint:env-template` | .env.example 变量完整性检查 |
| `build` | `build:openclaw` | 构建 OpenClaw 镜像（Docker-in-Docker） |
| `build` | `build:devpilot-claude-litellm` | 构建 devpilot-claude-litellm 镜像 |
| `push` | `push:openclaw` | 推送至 GitLab 镜像仓库 |
| `push` | `push:devpilot-claude-litellm` | 推送至 GitLab 镜像仓库 |
| `scan` | `scan:openclaw` | Trivy 安全扫描 OpenClaw |
| `scan` | `scan:devpilot-claude-litellm` | Trivy 安全扫描 devpilot-claude-litellm |
| `scan` | `scan:filesystem` | 文件系统安全扫描 |

**技术要点**：
- 使用 Docker-in-Docker（`docker:24.0-dind`）构建镜像
- 镜像构建后通过 `docker save` 导出为 artifact，避免重复构建
- 使用 BuildKit 和 registry 缓存加速构建
- 镜像标签包含版本号、`latest` 和 commit 短哈希

**镜像仓库**：GitLab 内置容器镜像仓库（`CI_REGISTRY_IMAGE`）

**所需 CI/CD 变量**（GitLab 自动提供）：

| 变量名 | 说明 |
|--------|------|
| `CI_REGISTRY` | GitLab 镜像仓库地址（自动） |
| `CI_REGISTRY_USER` | 仓库用户名（自动） |
| `CI_REGISTRY_PASSWORD` | 仓库密码/Token（自动） |
| `CI_REGISTRY_IMAGE` | 镜像仓库路径（自动） |

**使用方式**：

该文件需要放在仓库根目录：

```bash
cp cicd/ci/gitlab/.gitlab-ci.yml .gitlab-ci.yml
```

GitLab Runner 需配置 Docker 执行器并启用 Docker-in-Docker 服务。

---

### CI 变量配置

三种 CI 平台共享同一套构建参数。版本号以根目录的 `versions.env` 为单一配置源，CI 配置文件的 `env` / `vars` / `variables` 中保留与之对齐的默认值：

| 构建参数 | 默认值 | 用途 |
|----------|--------|------|
| `NODE_IMAGE_TAG` | `22.23.1-bookworm` | Node.js 基础镜像版本 |
| `OPENCLAW_VERSION` | `2026.7.1-2` | OpenClaw npm 包版本 |

| `CLAUDE_CODE_VERSION` | `2.1.241` | Claude Code npm 包版本 |

升级组件版本时，修改 `versions.env` 后同步更新对应 CI 配置文件中的默认值。

---

## CD 持续部署

### Docker 本地部署

#### deploy.sh（Docker Compose 模式）

**文件**：`cicd/cd/docker-local/deploy.sh`

**功能**：使用 `docker compose` 在本机一键部署全部 3 个容器

**流程**：
1. 定位项目根目录，加载 `.env` 文件
2. 校验 13 个必需环境变量
3. 检查 Docker Engine 和 Compose 版本
4. 创建 `data/`、`logs/`、`workspace/` 目录（幂等）
5. 执行 `docker compose up -d --build` 构建并启动
6. 等待 Redis / OpenClaw / devpilot-claude-litellm 三个服务健康就绪
7. 输出容器状态和访问地址

**使用方式**：

```bash
# 直接执行
bash cicd/cd/docker-local/deploy.sh

# 或通过统一脚本
bash cicd/scripts/deploy.sh --mode compose
```

**幂等性**：可重复执行，目录创建使用 `mkdir -p`，服务启动使用 `docker compose up -d`（已存在则重建）。

---

#### docker-run.sh（Docker Run 模式）

**文件**：`cicd/cd/docker-local/docker-run.sh`

**功能**：使用原生 `docker run` 命令逐个启动容器，不依赖 docker compose

**适用场景**：
- 未安装 Docker Compose 的环境
- 需要精细控制每个容器启动参数的场景
- 调试和排查问题

**流程**：
1. 加载 `.env` 文件并校验变量
2. 检查 Docker 环境
3. 创建目录（幂等）
4. 创建 Docker 桥接网络 `devpilot-network`（幂等）
5. 构建两个自建镜像（OpenClaw + devpilot-claude-litellm）
6. 清理同名旧容器（幂等，存在则删除）
7. 按 Redis -> OpenClaw -> devpilot-claude-litellm 顺序启动容器
8. 每个容器启动后等待健康就绪
9. 输出容器状态和常用命令

**与 deploy.sh 的区别**：

| 对比项 | deploy.sh | docker-run.sh |
|--------|-----------|---------------|
| 依赖 | Docker Compose v2.20+ | 仅 Docker Engine 24+ |
| 网络管理 | compose 自动管理 | 手动创建 `devpilot-network` |
| 配置文件挂载 | 通过 compose volumes | 手动 `-v` 挂载 |
| 容器编排 | 单命令管理全部 | 逐个 `docker run` |
| 推荐 | 日常使用首选 | 无 compose 环境备选 |

**使用方式**：

```bash
# 直接执行
bash cicd/cd/docker-local/docker-run.sh

# 或通过统一脚本
bash cicd/scripts/deploy.sh --mode run
```

---

### Docker 远程部署

**文件**：`cicd/cd/docker-remote/deploy-remote.sh`

**功能**：通过 `DOCKER_HOST` 连接远程 Docker 守护进程进行部署

**支持三种连接方式**：

| 方式 | DOCKER_HOST 格式 | 安全性 | 适用场景 |
|------|-----------------|--------|---------|
| TCP 明文 | `tcp://remote:2375` | 低（无加密） | 内网/信任网络 |
| SSH 直连 | `ssh://user@remote` | 高（SSH 加密） | 推荐，生产环境 |
| SSH 隧道 | `--ssh-tunnel` 参数 | 高 | 远程 Docker 仅监听 127.0.0.1 |

**支持两种部署模式**：
- `compose`（默认）：通过远程 Docker 执行 `docker compose`
- `run`（`--run` 参数）：通过远程 Docker 逐个 `docker run`

**参数说明**：

| 参数 | 说明 |
|------|------|
| `--host <H>` | 指定 DOCKER_HOST 地址 |
| `--run` | 使用 docker run 模式 |
| `--ssh-tunnel` | 使用 SSH 隧道连接 |
| `--help` | 显示帮助 |

**使用示例**：

```bash
# SSH 直连模式（推荐）
bash cicd/cd/docker-remote/deploy-remote.sh --host ssh://root@192.168.1.100

# TCP 明文模式
bash cicd/cd/docker-remote/deploy-remote.sh --host tcp://192.168.1.100:2375

# SSH 隧道模式（需先配置 docker-remote.conf）
cp cicd/cd/docker-remote/docker-remote.conf.example cicd/cd/docker-remote/docker-remote.conf
# 编辑 docker-remote.conf 填入 REMOTE_SSH_HOST 等
bash cicd/cd/docker-remote/deploy-remote.sh --ssh-tunnel

# 使用 docker run 远程模式
bash cicd/cd/docker-remote/deploy-remote.sh --host ssh://root@192.168.1.100 --run
```

**配置文件**：

复制 `docker-remote.conf.example` 为 `docker-remote.conf` 并填入实际值：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `REMOTE_DOCKER_HOST` | 远程 Docker 地址 | 无（需配置） |
| `REMOTE_SSH_USER` | SSH 用户名 | `root` |
| `REMOTE_SSH_HOST` | SSH 主机地址 | `192.168.1.100` |
| `REMOTE_SSH_PORT` | SSH 端口 | `22` |
| `REMOTE_DOCKER_PORT` | 远程 Docker API 端口 | `2375` |
| `LOCAL_FORWARD_PORT` | 本地转发端口 | `23750` |

**远程主机准备**：

```bash
# 1. 安装 Docker Engine 24+
# 2. 配置 Docker 监听（TCP 模式）
cat > /etc/docker/daemon.json << 'EOF'
{ "hosts": ["fd://", "tcp://0.0.0.0:2375"] }
EOF
systemctl restart docker

# 3. 配置 SSH 免密登录（SSH 模式）
ssh-keygen -t ed25519
ssh-copy-id root@192.168.1.100

# 4. 开放防火墙端口
# TCP 模式: 2375
# 服务端口: 18789（OpenClaw Gateway）、4000（LiteLLM 代理，仅回环）
```

---

### Kubernetes Helm Chart

K8s 部署统一采用 **Helm Chart 唯一方式**，不再提供 kubectl 原生清单（`manifests/` 已移除）。所有部署通过 Helm 模板渲染，密钥由统一脚本自动从 `.env` 注入。

**目录**：`cicd/cd/k8s/helm/devpilot/`

**Chart 信息**：

| 属性 | 值 |
|------|-----|
| 名称 | `devpilot` |
| 版本 | `1.0.0` |
| App 版本 | `2026.7.1` |
| 类型 | `application` |

**模板文件**：

| 文件 | 说明 |
|------|------|
| `_helpers.tpl` | 模板辅助函数（名称、标签生成） |
| `configmap.yaml` | ConfigMap 模板（非敏感配置） |
| `secret.yaml` | Secret 模板（敏感数据） |
| `deployment.yaml` | 3 个 Deployment 模板（Redis + OpenClaw + devpilot-claude-litellm） |
| `service.yaml` | 3 个 Service 模板 |
| `ingress.yaml` | Ingress 模板（可选） |

**values.yaml 主要参数**：

| 参数路径 | 说明 | 默认值 |
|----------|------|--------|
| `global.namespace` | 命名空间 | `devpilot` |
| `global.tz` | 时区 | `Asia/Shanghai` |
| `agnes.baseUrl` | agnes-ai API 地址 | `https://api.agnes-ai.cn/v1` |
| `agnes.apiKey` | agnes-ai API 密钥 | `your-agnes-api-key` |
| `feishu.appId` | 飞书 App ID | `your-feishu-app-id` |
| `feishu.appSecret` | 飞书 App Secret | `your-feishu-app-secret` |
| `redis.password` | Redis 密码 | `change-me-...` |
| `redis.persistence.size` | Redis 存储大小 | `1Gi` |
| `openclaw.image` | OpenClaw 镜像 | `devpilot-openclaw:latest` |
| `openclaw.gatewayPort` | Gateway 端口 | `18789` |
| `ccSwitchClaude.image` | devpilot-claude-litellm 镜像 | `devpilot-claude-litellm:latest` |
| `ccSwitchClaude.webPort` | LiteLLM 代理端口（回环） | `4000` |
| `ingress.enabled` | 是否启用 Ingress | `false` |

**使用方式**：

```bash
# 方式 1：使用默认 values 部署（需先修改 values.yaml 中的密钥）
helm install devpilot cicd/cd/k8s/helm/devpilot \
    --namespace devpilot \
    --create-namespace

# 方式 2：通过 --set 覆盖参数
helm install devpilot cicd/cd/k8s/helm/devpilot \
    --namespace devpilot \
    --create-namespace \
    --set agnes.apiKey="sk-xxxx" \
    --set redis.password="your-password" \
    --set feishu.appId="cli_xxxx" \
    --set feishu.appSecret="xxxx"

# 方式 3：使用自定义 values 文件
cat > custom-values.yaml << 'EOF'
agnes:
  apiKey: "sk-8TIy..."
  baseUrl: "https://api.agnes-ai.cn/v1"
feishu:
  appId: "cli_a962..."
  appSecret: "gsNus..."
redis:
  password: "DevPilotRedis2026Secure"
openclaw:
  gatewayToken: "DevPilotGatewayToken2026Secure"
EOF

helm install devpilot cicd/cd/k8s/helm/devpilot \
    --namespace devpilot \
    --create-namespace \
    -f custom-values.yaml

# 方式 4：通过统一脚本自动从 .env 生成 values 并部署（推荐）
bash cicd/scripts/deploy.sh --mode k8s --helm

# 升级
helm upgrade devpilot cicd/cd/k8s/helm/devpilot \
    --namespace devpilot \
    -f custom-values.yaml

# 卸载
helm uninstall devpilot --namespace devpilot
```

**统一脚本自动生成 values 的逻辑**：

`cicd/scripts/deploy.sh --mode k8s --helm` 会自动从 `.env` 文件读取变量，生成临时 `values-override.yaml` 文件，传递给 `helm upgrade --install`，部署完成后自动清理临时文件。

---

## 统一部署脚本

**文件**：`cicd/scripts/deploy.sh`

**功能**：交互式选择部署方式，统一入口一键部署

**支持的部署方式**：

| 选项 | 模式 | 说明 | 调用的脚本 |
|------|------|------|-----------|
| 1 | `compose` | 本地 Docker Compose（推荐） | `cd/docker-local/deploy.sh` |
| 2 | `run` | 本地 Docker Run | `cd/docker-local/docker-run.sh` |
| 3 | `remote` | 远程 Docker | `cd/docker-remote/deploy-remote.sh` |
| 4 | `k8s` | Kubernetes Helm Chart | `helm install` |

**使用方式**：

```bash
# 交互式选择
bash cicd/scripts/deploy.sh

# 非交互式指定模式
bash cicd/scripts/deploy.sh --mode compose
bash cicd/scripts/deploy.sh --mode run
bash cicd/scripts/deploy.sh --mode remote
bash cicd/scripts/deploy.sh --mode k8s
bash cicd/scripts/deploy.sh --mode k8s --helm

# 查看帮助
bash cicd/scripts/deploy.sh --help
```

**参数说明**：

| 参数 | 说明 |
|------|------|
| `--mode <m>` | 指定部署模式（compose / run / remote / k8s） |
| `--helm` | 使用 Helm Chart 部署（k8s 模式默认即 Helm） |
| `--help` / `-h` | 显示帮助信息 |

**脚本流程**：

1. **定位项目根目录**：自动向上回溯到 `devpilot/` 根目录
2. **加载 .env 文件**：逐行解析，跳过注释和空行，导出为环境变量
3. **校验 13 个必需变量**：缺少任何一个都会报错退出
4. **解析命令行参数**：支持非交互模式
5. **交互式选择**（未指定 `--mode` 时）：显示菜单供用户选择
6. **执行部署**：调用对应子脚本或直接执行 helm 命令
7. **健康检查**：根据部署模式执行 Docker 或 Kubernetes 健康检查
8. **输出结果**：显示访问地址和下一步操作建议

**健康检查**：

- **Docker 模式**：检查 Redis PONG、OpenClaw /healthz、LiteLLM /health/liveliness 200
- **Kubernetes 模式**：检查 Pod 状态、Service 状态、PVC 状态，等待 Pod 就绪

---

## 服务自动部署

> 详细文档请参考 [服务自动部署 README](service-deploy/README.md)

DevPilot 不仅部署平台本身，还支持自动部署 Claude Code 开发出的服务。

### 与平台 CD 的区别

| 对比项 | 平台 CD（cicd/cd/） | 服务自动部署（cicd/service-deploy/） |
|--------|--------------------|---------------------------------------|
| 部署对象 | DevPilot 平台（Redis/OpenClaw/devpilot-claude-litellm） | Claude Code 开发的服务 |
| 服务来源 | 项目内置的 docker-compose.yml / Helm Chart | workspace/ 下每个服务的 service.yaml |
| 触发方式 | 手动 / CI 流水线 | 开发完成钩子 / 飞书命令 / Git 推送 / 手动 |
| 部署目标 | 固定的 3 个容器 | 动态的多个服务 |

### 核心组件

| 组件 | 文件 | 说明 |
|------|------|------|
| 部署脚本 | `service-deploy/deploy-service.sh` | 读取 service.yaml 构建并部署 |
| 开发完成钩子 | `service-deploy/post-dev-hook.sh` | 开发完成后自动触发部署 |
| 飞书命令处理器 | `service-deploy/feishu-deploy-handler.sh` | 解析 /deploy 命令 |
| YAML 解析库 | `service-deploy/lib/yaml-parser.sh` | 纯 bash YAML 解析 |
| K8s 模板 | `service-deploy/k8s/service-template.yaml` | K8s 部署清单模板 |
| 服务描述符模板 | `service-deploy/service.yaml.example` | service.yaml 模板 |

### 触发方式

| 触发方式 | 脚本 | 说明 |
|---------|------|------|
| 开发完成自动触发 | `post-dev-hook.sh` | Claude Code 开发完后自动部署变更的服务（由 `DEVPILOT_AUTO_DEPLOY` 控制） |
| 飞书 Bot 命令 | `feishu-deploy-handler.sh` | 飞书群聊发送 /deploy 命令 |
| Git 推送触发 | `ci/` 下的工作流 | 代码推送到仓库自动部署 |
| 手动执行 | `deploy-service.sh` | 命令行直接部署 |

### 快速使用

```bash
# 1. 创建服务
mkdir -p workspace/my-api
cp cicd/service-deploy/service.yaml.example workspace/my-api/service.yaml
vim workspace/my-api/service.yaml

# 2. 部署服务
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api

# 3. 查看所有可部署服务
bash cicd/service-deploy/deploy-service.sh --list
```

---

## 环境变量参考

所有部署脚本均从项目根目录的 `.env` 文件读取环境变量。

### 必需变量

| 变量名 | 说明 | 示例值 |
|--------|------|--------|
| `AGNES_API_KEY` | agnes-ai API 密钥 | `sk-8TIy...` |
| `AGNES_BASE_URL` | agnes-ai API 地址 | `https://api.agnes-ai.cn/v1` |
| `FEISHU_APP_ID` | 飞书应用 App ID | `cli_a962...` |
| `FEISHU_APP_SECRET` | 飞书应用 App Secret | `gsNus...` |
| `REDIS_PASSWORD` | Redis 认证密码 | `DevPilotRedis2026Secure` |
| `OPENCLAW_GATEWAY_TOKEN` | OpenClaw Gateway Token | `DevPilotGatewayToken2026Secure` |
| `OPENCLAW_GATEWAY_PORT` | OpenClaw Gateway 端口 | `18789` |

| `NODE_IMAGE_TAG` | Node.js 基础镜像版本 | `22.23.1-bookworm` |
| `OPENCLAW_VERSION` | OpenClaw npm 版本 | `2026.7.1-2` |

| `CLAUDE_CODE_VERSION` | Claude Code 版本 | `2.1.241` |
| `TZ` | 时区 | `Asia/Shanghai` |

### 可选变量

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `AGNES_MODEL` | 默认文本模型名称 | `agnes-2.5-flash` |
| `DEVPILOT_AUTO_DEPLOY` | 开发完成后自动部署服务 | `false` |

> 组件版本变量（`NODE_IMAGE_TAG` / `OPENCLAW_VERSION` / `CLAUDE_CODE_VERSION` / `LITELLM_VERSION`）由 `versions.env` 统一管理，`init.sh` 会自动加载，一般无需在 `.env` 中重复配置。

---

## Docker 构建参数

CI 流水线和部署脚本通过 `--build-arg` 向 Dockerfile 传递构建参数。版本号统一来源于 `versions.env`：

| 构建参数 | 说明 | 默认值 | 使用的 Dockerfile |
|----------|------|--------|-------------------|
| `NODE_IMAGE_TAG` | Node.js 基础镜像版本 | `22.23.1-bookworm` | 两个 Dockerfile |
| `OPENCLAW_VERSION` | OpenClaw npm 版本 | `2026.7.1-2` | `dockerfiles/openclaw/Dockerfile` |
| `CLAUDE_CODE_VERSION` | Claude Code 版本 | `2.1.241` | `dockerfiles/claude/Dockerfile` |

**Dockerfile 中的 CRLF 修复**：

所有 Dockerfile 均包含 Windows CRLF 修复命令，确保在 Windows 上编辑的 shell 脚本能正确执行：

```dockerfile
# 修复 Windows CRLF 换行符问题
RUN sed -i 's/\r$//' /usr/local/bin/*.sh /entrypoint.sh 2>/dev/null || true
```

---

## 脚本规范

所有 shell 脚本遵循以下规范。

### 公共函数库

所有脚本通过 `source cicd/lib/common.sh` 加载统一的颜色定义、日志函数（`info` / `success` / `warn` / `error`）、错误陷阱与辅助函数，无需各自重复定义。详见 [公共函数库 (common.sh)](#公共函数库-commonsh)。

### 头部声明

```bash
#!/bin/bash
set -e
```

### 错误处理

通过 `common.sh` 提供的 `setup_error_trap` 统一捕获错误并报告行号：

```bash
setup_error_trap
# 等价于：trap 'error "执行过程中发生错误，行号: $LINENO"' ERR
```

### 幂等性

- 目录创建使用 `mkdir -p`（`create_data_dirs`）
- 网络创建前先检查是否存在（`ensure_docker_network`）
- 容器启动前先检查并清理同名旧容器（`remove_container_if_exists`）
- `docker compose up -d` 本身具有幂等性

### 中文注释

所有脚本使用中文注释说明功能、参数和流程步骤。

---

## 快速开始

### 1. 本地快速部署（Docker Compose）

```bash
cd devpilot

# 使用配置向导（只需 3 个必填项）
./init.sh

# 一键部署
./deploy.sh
# 或：bash cicd/scripts/deploy.sh --mode compose
```

### 2. 远程部署

```bash
cd devpilot

# SSH 直连远程部署
bash cicd/scripts/deploy.sh --mode remote
# 输入 DOCKER_HOST: ssh://root@192.168.1.100
```

### 3. Kubernetes 部署（Helm）

```bash
cd devpilot

# 自动从 .env 生成 values 并部署
bash cicd/scripts/deploy.sh --mode k8s --helm
```

### 4. CI 流水线启用

根据使用的 Git 平台，将对应 CI 配置复制到仓库根目录：

```bash
# GitHub Actions
mkdir -p .github/workflows
cp cicd/ci/github/workflows/ci.yml .github/workflows/ci.yml

# Gitee Go
mkdir -p .workflow
cp cicd/ci/gitee/workflows/ci.yml .workflow/devpilot-ci.yml

# GitLab CI
cp cicd/ci/gitlab/.gitlab-ci.yml .gitlab-ci.yml
```

### 5. 本地运行 CI Lint

无需启动 CI 平台即可在本地执行代码质量检查：

```bash
bash cicd/ci/scripts/lint.sh
```

---

## 常见问题

### Q: 脚本在 Windows 上执行报错 `bad interpreter`

这是 Windows CRLF 换行符问题。解决方案：

1. 项目已配置 `.gitattributes` 强制 `.sh` 文件使用 LF 换行符
2. Git 克隆后执行 `git add --renormalize .` 修复
3. 或在 Dockerfile 中已包含 `sed -i 's/\r$//'` 修复命令
4. 建议在 Linux/WSL 环境中执行部署脚本

### Q: CI 构建中镜像推送失败

- **GitHub Actions**：确认仓库 Settings -> Actions -> General -> Workflow permissions 设为 Read and write
- **Gitee Go**：确认已在流水线变量中配置 `REGISTRY`、`REGISTRY_USER`、`REGISTRY_PASSWORD`
- **GitLab CI**：确认项目已启用 Container Registry 功能

### Q: 远程 Docker 部署连接超时

1. 检查远程 Docker 是否监听对应端口：`systemctl status docker`
2. 检查防火墙是否放行 2375 端口（TCP 模式）
3. SSH 模式检查免密登录是否配置：`ssh root@remote-host echo ok`
4. 尝试使用 `--ssh-tunnel` 模式（更安全，适合 Docker 仅监听 127.0.0.1 的场景）

### Q: Kubernetes 部署后 Pod 一直 Pending

1. 检查 PVC 是否绑定：`kubectl get pvc -n devpilot`
2. 检查 StorageClass 是否存在：`kubectl get storageclass`
3. 检查节点资源是否充足：`kubectl describe node`
4. 查看 Pod 事件：`kubectl describe pod <pod-name> -n devpilot`

### Q: Helm 部署密钥如何注入

推荐三种方式：

```bash
# 方式 1：统一脚本自动从 .env 注入（最简单）
bash cicd/scripts/deploy.sh --mode k8s --helm

# 方式 2：通过 --set 参数
helm install devpilot cicd/cd/k8s/helm/devpilot \
    --set agnes.apiKey="sk-xxx" \
    --set redis.password="xxx"

# 方式 3：使用自定义 values 文件
helm install devpilot cicd/cd/k8s/helm/devpilot -f custom-values.yaml
```

### Q: 如何更新镜像版本

1. 修改 `versions.env` 文件中的版本号
2. 同步修改 CI 配置文件中的对应默认值
3. 重新构建部署：

```bash
# Docker 部署
bash cicd/scripts/deploy.sh --mode compose

# Kubernetes Helm 部署
bash cicd/scripts/deploy.sh --mode k8s --helm
```

### Q: 各部署方式如何选择

| 场景 | 推荐方式 |
|------|---------|
| 本地开发测试 | Docker Compose（`--mode compose`） |
| 无 Compose 的环境 | Docker Run（`--mode run`） |
| 远程服务器部署 | 远程 Docker SSH 模式（`--mode remote`） |
| 生产环境/集群部署 | Kubernetes Helm（`--mode k8s --helm`） |
| CI/CD 自动化 | CI 流水线构建镜像 + Helm 部署 |
