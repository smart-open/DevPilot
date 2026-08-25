# DevPilot 服务自动部署

> Claude Code 开发完成的服务，自动构建并部署到 Docker / Kubernetes / 远程 Docker。

DevPilot 的核心理念：**AI 开发 -> 自动部署 -> 飞书通知**。Claude Code 在 `workspace/` 目录下开发服务，开发完成后通过多种触发方式自动部署。

---

## 目录

- [架构概览](#架构概览)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [服务部署描述符 (service.yaml)](#服务部署描述符-serviceyaml)
  - [极简模式](#极简模式)
  - [完整模式](#完整模式)
  - [构建类型自动推断](#构建类型自动推断)
- [核心脚本](#核心脚本)
  - [deploy-service.sh](#deploy-servicesh)
  - [post-dev-hook.sh](#post-dev-hooksh)
  - [feishu-deploy-handler.sh](#feishu-deploy-handlersh)
- [触发方式](#触发方式)
- [部署目标](#部署目标)
- [CI/CD 工作流](#cicd-工作流)
- [构建类型](#构建类型)
- [健康检查](#健康检查)
- [Claude Code 供应商自动配置](#claude-code-供应商自动配置)
- [配置参考](#配置参考)
- [常见问题](#常见问题)

---

## 架构概览

```
                    ┌─────────────────────────────────────────────────┐
                    │              DevPilot 平台容器                   │
                    │  ┌───────────┐  ┌────────────────────────────┐ │
  飞书消息 ────────>│  │ OpenClaw   │  │  CC-Switch + Claude Code    │ │
  /deploy xxx       │  │ (Bot)      │  │  workspace/ 下开发服务      │ │
                    │  └─────┬─────┘  └──────────┬─────────────────┘ │
                    └────────┼───────────────────┼───────────────────┘
                             │                   │
                     飞书命令触发          开发完成触发
                             │                   │
                             ▼                   ▼
                    ┌─────────────────────────────────────────────────┐
                    │          feishu-deploy-handler.sh               │
                    │          post-dev-hook.sh                       │
                    │                    │                            │
                    │                    ▼                            │
                    │          deploy-service.sh                     │
                    │     (读取 service.yaml 构建并部署)                │
                    └────────────────────┬────────────────────────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
              ┌──────────┐       ┌──────────┐        ┌──────────────┐
              │  Docker   │       │   K8s    │        │ Remote Docker │
              │ (本地容器) │       │ (集群)   │        │ (远程服务器)   │
              └──────────┘       └──────────┘        └──────────────┘
```

---

## 目录结构

```
cicd/service-deploy/
├── README.md                          # 本文档
│
├── deploy-service.sh                  # 核心部署脚本（构建 + 部署 + 健康检查）
├── post-dev-hook.sh                   # 开发完成后自动部署钩子
├── feishu-deploy-handler.sh           # 飞书 Bot 部署命令处理器
│
├── service.yaml.example               # 服务部署描述符模板
│
├── lib/
│   └── yaml-parser.sh                 # 轻量级 YAML 解析库（纯 bash，不依赖 yq/python）
│
├── k8s/
│   └── service-template.yaml          # K8s 部署清单模板（sed 占位符替换）
│
└── ci/                                # CI/CD 工作流配置
    ├── github/
    │   └── workflows/
    │       └── service-deploy.yml     # GitHub Actions 服务部署工作流
    ├── gitee/
    │   └── workflows/
    │       └── service-deploy.yml     # Gitee Go 服务部署流水线
    └── gitlab/
        └── .gitlab-ci-service-deploy.yml  # GitLab CI 服务部署流水线
```

---

## 快速开始

### 1. 创建服务

在 `workspace/` 下创建服务目录，并添加 `service.yaml`：

```bash
# 创建服务目录
mkdir -p workspace/my-api

# 从模板创建 service.yaml
cp cicd/service-deploy/service.yaml.example workspace/my-api/service.yaml

# 编辑配置
vim workspace/my-api/service.yaml
```

### 2. 编写服务代码

```
workspace/my-api/
├── service.yaml          # 部署描述符
├── Dockerfile            # Docker 构建文件
├── index.js              # 服务代码
└── package.json
```

### 3. 部署服务

```bash
# 方式 1：直接部署
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api

# 方式 2：指定标签部署
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api --tag v1.0.0

# 方式 3：仅构建镜像
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api --build-only

# 方式 4：预览部署命令（不实际执行）
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api --dry-run

# 方式 5：列出所有可部署的服务
bash cicd/service-deploy/deploy-service.sh --list
```

---

## 服务部署描述符 (service.yaml)

每个服务在目录下放置 `service.yaml`，描述如何构建和部署。支持**极简模式**与**完整模式**两种写法。

### 极简模式

只需提供 `name` 和 `deploy.target` 两个必填字段，其余全部自动推断或使用默认值：

```yaml
# 极简模式：仅 2 个必填字段
name: my-service
deploy:
  target: docker
```

极简模式下：

- `build.type` 未指定时，根据服务目录中的文件**自动推断**（见 [构建类型自动推断](#构建类型自动推断)）
- `build.context` 默认 `.`
- `build.dockerfile` 默认 `Dockerfile`
- 端口、环境变量、数据卷等使用默认值，后续可按需补充

> 极简模式适合快速验证。绝大多数配置项都有合理默认值，无需重复书写。

### 完整模式

```yaml
# ---- 服务基本信息 ----
name: my-service                    # [必填] 服务名称
description: "示例服务"              # [可选] 服务描述

# ---- 构建配置 ----
build:
  type: dockerfile                  # [可选] dockerfile | static | nodejs | python（未填则自动推断）
  context: .                        # [可选] 构建上下文，默认 .
  dockerfile: Dockerfile            # [可选] Dockerfile 路径，默认 Dockerfile
  args:                             # [可选] Docker 构建参数
    - NODE_ENV=production

# ---- 部署配置 ----
deploy:
  target: docker                    # [必填] docker | k8s | remote

  # Docker 部署配置
  docker:
    container_name: my-service      # [可选] 容器名，默认 devpilot-<name>
    network: devpilot-network       # [可选] Docker 网络
    ports:                          # [可选] 端口映射
      - "8080:8080"
    env_file: .env                  # [可选] 环境变量文件
    env:                            # [可选] 环境变量
      - LOG_LEVEL=info
    volumes:                        # [可选] 数据卷
      - ./data:/app/data
    restart: unless-stopped         # [可选] 重启策略
    memory_limit: 512M              # [可选] 内存限制

  # K8s 部署配置
  k8s:
    namespace: devpilot-services    # [可选] 命名空间
    replicas: 2                     # [可选] 副本数
    image_pull_policy: IfNotPresent # [可选] 镜像拉取策略
    service_type: NodePort          # [可选] ClusterIP | NodePort | LoadBalancer
    node_port: 30080                # [可选] NodePort 端口
    resources:                      # [可选] 资源限制
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi

  # 远程 Docker 部署配置
  remote:
    docker_host: ssh://root@server  # [必填] 远程 Docker 地址
    network: devpilot-network       # [可选] 远程 Docker 网络
    ports:                          # [可选] 端口映射
      - "8080:8080"

# ---- 端口声明 ----
ports:
  - 8080

# ---- 健康检查 ----
healthcheck:
  type: http                        # http | tcp | command
  path: /health                     # [http 类型] 检查路径
  port: 8080                        # [http/tcp 类型] 检查端口
  interval: 10s                     # [可选] 检查间隔
  retries: 5                        # [可选] 重试次数
  start_period: 30s                 # [可选] 启动等待
```

### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `name` | string | 是 | 服务名称，用于容器名、镜像名、K8s 资源名 |
| `description` | string | 否 | 服务描述 |
| `build.type` | string | 否 | 构建类型: `dockerfile` / `static` / `nodejs` / `python`（未填则自动推断） |
| `build.context` | string | 否 | Docker 构建上下文目录，默认 `.` |
| `build.dockerfile` | string | 否 | Dockerfile 路径，默认 `Dockerfile` |
| `build.args` | list | 否 | Docker 构建参数列表 |
| `deploy.target` | string | 是 | 部署目标: `docker` / `k8s` / `remote` |
| `deploy.docker.*` | object | 否 | Docker 部署参数（target 为 docker 时生效） |
| `deploy.k8s.*` | object | 否 | K8s 部署参数（target 为 k8s 时生效） |
| `deploy.remote.*` | object | 否 | 远程 Docker 部署参数（target 为 remote 时生效） |
| `ports` | list | 否 | 服务监听端口列表 |
| `healthcheck.*` | object | 否 | 健康检查配置 |

### 构建类型自动推断

当 `build.type` 未在 `service.yaml` 中指定时，`deploy-service.sh` 会根据服务目录中的文件特征自动推断构建类型：

| 检测到的文件 | 推断的 build.type | 说明 |
|-------------|------------------|------|
| `Dockerfile` | `dockerfile` | 使用服务自带的 Dockerfile 构建 |
| `package.json` | `nodejs` | 自动生成 Node.js Dockerfile（`node:22-alpine` + `npm ci` + `node index.js`） |
| `requirements.txt` | `python` | 自动生成 Python Dockerfile（`python:3.12-slim` + `pip install` + `python app.py`） |
| 以上均无 | `static` | 自动生成 Nginx 静态文件 Dockerfile（`nginx:alpine`） |

推断按上表自上而下顺序匹配，命中即停止。推断结果会在部署日志中输出（`自动推断构建类型: <type>`），方便确认。

> 因此极简模式下，只要服务目录中存在 `Dockerfile` 或 `package.json` 等特征文件，就无需手动声明 `build.type`。

---

## 核心脚本

### deploy-service.sh

**功能**：读取 `service.yaml`，自动构建 Docker 镜像并部署到指定目标。

**用法**：

```bash
./deploy-service.sh --service-dir <dir> [选项]
./deploy-service.sh --list
./deploy-service.sh --help
```

**参数**：

| 参数 | 说明 |
|------|------|
| `--service-dir <dir>` | 服务目录路径（含 service.yaml） |
| `--tag <tag>` | 镜像标签（默认 `latest`） |
| `--build-only` | 仅构建镜像，不部署 |
| `--dry-run` | 仅打印命令，不实际执行 |
| `--cleanup` | 停止并清理服务容器/资源 |
| `--list` | 列出所有可部署的服务 |
| `--help` / `-h` | 显示帮助 |

**执行流程**：

1. 解析参数，加载 `service.yaml`
2. 校验必填字段（`name`、`deploy.target`）；`build.type` 未指定时自动推断
3. 构建 Docker 镜像（根据 build.type 选择构建策略）
4. 部署到指定目标（docker / k8s / remote）
5. 执行健康检查（等待服务就绪）
6. 输出部署结果和常用命令

**镜像命名规则**：`devpilot-<service-name>:<tag>`

> 该脚本通过 `source` 加载 `cicd/lib/common.sh` 公共函数库，复用统一的日志、错误陷阱与命令执行能力。

---

### post-dev-hook.sh

**功能**：Claude Code 开发会话结束后自动触发，检测 `workspace/` 下有变更的服务并部署。

**用法**：

```bash
./post-dev-hook.sh                    # 部署所有有变更的服务
./post-dev-hook.sh --service <name>   # 仅部署指定服务
./post-dev-hook.sh --all              # 部署所有含 service.yaml 的服务
```

**变更检测机制**：

- 每个服务目录下维护 `.devpilot-last-deploy` 时间戳文件
- 对比服务源码文件的修改时间与上次部署时间
- 有变更则重新部署，无变更则跳过

**集成方式**：

在 CC-Switch 容器的 `start.sh` 中添加（通过环境变量控制）：

```bash
# 在 start.sh 末尾添加
if [ "$DEVPILOT_AUTO_DEPLOY" = "true" ]; then
    bash /workspace/cicd/service-deploy/post-dev-hook.sh
fi
```

或在 `.env` 中设置：

```bash
DEVPILOT_AUTO_DEPLOY=true
```

---

### feishu-deploy-handler.sh

**功能**：接收飞书消息文本，解析 `/deploy` 命令并执行部署。

**支持的命令**：

| 命令 | 说明 |
|------|------|
| `/deploy <service-name>` | 部署指定服务 |
| `/deploy <service-name> --tag v1.0` | 指定标签部署 |
| `/deploy --list` | 列出所有可部署服务 |
| `/deploy --status <service-name>` | 查看服务运行状态 |
| `/deploy --cleanup <service-name>` | 清理服务 |
| `/deploy --help` | 显示帮助 |

**集成方式**：

通过 OpenClaw 的插件机制或 Webhook 回调，将 `/deploy` 命令路由到此脚本。脚本接收消息文本作为参数，输出文本格式结果（可由 OpenClaw 转换为飞书消息卡片）。

```bash
# 直接调用
echo "/deploy my-service" | bash cicd/service-deploy/feishu-deploy-handler.sh

# 或通过参数
bash cicd/service-deploy/feishu-deploy-handler.sh "/deploy my-service --tag v1.0"
```

---

## 触发方式

DevPilot 支持 4 种部署触发方式：

| 触发方式 | 脚本 | 适用场景 |
|---------|------|---------|
| **开发完成自动触发** | `post-dev-hook.sh` | Claude Code 开发完服务后自动部署（由 `DEVPILOT_AUTO_DEPLOY` 控制） |
| **飞书 Bot 命令** | `feishu-deploy-handler.sh` | 通过飞书群聊远程触发部署 |
| **Git 推送触发** | CI 工作流 | 代码推送到仓库自动部署 |
| **手动执行** | `deploy-service.sh` | 本地手动部署单个服务 |

### 触发流程对比

```
1. 开发完成触发:
   Claude Code 开发 -> post-dev-hook.sh -> deploy-service.sh -> 部署

2. 飞书命令触发:
   飞书消息 "/deploy xxx" -> feishu-deploy-handler.sh -> deploy-service.sh -> 部署

3. Git 推送触发:
   git push -> CI 工作流 -> deploy-service.sh -> 部署

4. 手动触发:
   命令行 -> deploy-service.sh -> 部署
```

---

## 部署目标

### Docker（本地容器）

部署到本机 Docker，服务加入 `devpilot-network` 网络，与其他 DevPilot 容器互通。

```yaml
deploy:
  target: docker
  docker:
    ports:
      - "8080:8080"
    restart: unless-stopped
```

**特点**：
- 最简单的部署方式，无需额外配置
- 服务与 DevPilot 平台在同一 Docker 网络
- 适合开发测试和单机部署

### Kubernetes（集群）

部署到 K8s 集群，自动生成 Deployment + Service 清单。

```yaml
deploy:
  target: k8s
  k8s:
    namespace: devpilot-services
    replicas: 2
    service_type: NodePort
    node_port: 30080
```

**特点**：
- 支持多副本和滚动更新
- 自动生成 K8s 清单（通过模板 + sed 替换）
- 支持资源限制、健康检查探针
- 需要预装 kubectl 并配置集群连接

### Remote Docker（远程服务器）

将镜像导出传输到远程 Docker 主机并启动。

```yaml
deploy:
  target: remote
  remote:
    docker_host: ssh://root@192.168.1.100
    ports:
      - "8080:8080"
```

**特点**：
- 通过 SSH 传输镜像到远程主机
- 适合将服务部署到生产服务器
- 需要配置 SSH 免密登录

---

## CI/CD 工作流

三种 CI 平台的工作流配置，用于 Git 推送时自动部署服务。

### GitHub Actions

**文件**：`ci/github/workflows/service-deploy.yml`

**触发条件**：
- 推送到 `main` / `master` 分支且 `workspace/` 或 `cicd/service-deploy/` 有变更
- 手动触发（可选择服务名、标签、部署目标）
- Repository Dispatch API（可由飞书 Bot / 其他系统调用）

**所需 Secrets**：

| Secret 名 | 说明 |
|-----------|------|
| `KUBE_CONFIG` | base64 编码的 kubeconfig（K8s 部署用） |
| `REMOTE_SSH_KEY` | SSH 私钥（远程 Docker 部署用） |
| `REMOTE_DOCKER_HOST` | 远程 Docker 地址 |

**所需 Variables**（可选）：

| Variable 名 | 说明 |
|-------------|------|
| `FEISHU_DEPLOY_WEBHOOK` | 飞书 Webhook 地址（部署通知） |

**使用方式**：

```bash
# 复制到 .github/workflows/
mkdir -p .github/workflows
cp cicd/service-deploy/ci/github/workflows/service-deploy.yml .github/workflows/service-deploy.yml
```

---

### Gitee Go

**文件**：`ci/gitee/workflows/service-deploy.yml`

**触发条件**：
- 推送到 `master` / `main` 分支且 `workspace/` 或 `cicd/service-deploy/` 有变更

**流水线阶段**：

| 阶段 | 说明 |
|------|------|
| discover-stage | 扫描 workspace/ 发现可部署服务 |
| build-stage | 构建所有服务镜像 |
| deploy-stage | 部署到 Docker / K8s |
| verify-stage | 检查服务运行状态 |

**使用方式**：

```bash
# 复制到 .workflow/
mkdir -p .workflow
cp cicd/service-deploy/ci/gitee/workflows/service-deploy.yml .workflow/devpilot-service-deploy.yml
```

---

### GitLab CI

**文件**：`ci/gitlab/.gitlab-ci-service-deploy.yml`

**触发条件**：
- 推送到 `main` / `master` 分支
- 手动触发
- `workspace/` 或 `cicd/service-deploy/` 有变更

**流水线阶段**：

| 阶段 | 任务 | 说明 |
|------|------|------|
| `discover` | `discover:services` | 发现可部署服务 |
| `build` | `build:services` | 构建所有服务镜像 |
| `deploy` | `deploy:docker` | 部署到 Docker |
| `deploy` | `deploy:k8s` | 部署到 Kubernetes |
| `deploy` | `deploy:remote` | 部署到远程 Docker |
| `verify` | `verify:services` | 验证部署结果 |

**所需 CI/CD 变量**：

| 变量名 | 说明 |
|--------|------|
| `KUBE_CONFIG` | base64 编码的 kubeconfig |
| `REMOTE_SSH_KEY` | SSH 私钥 |
| `REMOTE_DOCKER_HOST` | 远程 Docker 地址 |

**使用方式**：

```bash
# 方式 1：复制到根目录
cp cicd/service-deploy/ci/gitlab/.gitlab-ci-service-deploy.yml .gitlab-ci-service-deploy.yml

# 方式 2：在 .gitlab-ci.yml 中 include
echo "include: 'cicd/service-deploy/ci/gitlab/.gitlab-ci-service-deploy.yml'" >> .gitlab-ci.yml
```

---

## 构建类型

`service.yaml` 的 `build.type` 字段支持 4 种构建类型。未显式指定时由部署脚本自动推断（见 [构建类型自动推断](#构建类型自动推断)）：

| 构建类型 | 说明 | 需要的文件 | 自动生成 Dockerfile |
|---------|------|-----------|-------------------|
| `dockerfile` | 使用服务自带的 Dockerfile 构建 | `Dockerfile` | 否 |
| `nodejs` | 自动生成 Node.js Dockerfile 构建 | `package.json` + `index.js` | 是 |
| `python` | 自动生成 Python Dockerfile 构建 | `requirements.txt` + `app.py` | 是 |
| `static` | 自动生成 Nginx 静态文件 Dockerfile | 静态文件（HTML/CSS/JS） | 是 |

**自动生成的 Dockerfile**：

- **nodejs**: `node:22-alpine` + `npm ci` + `node index.js`
- **python**: `python:3.12-slim` + `pip install` + `python app.py`
- **static**: `nginx:alpine` + 复制文件到 `/usr/share/nginx/html`

---

## 健康检查

部署完成后自动执行健康检查，等待服务就绪。

### 检查类型

| 类型 | 说明 | 必填字段 |
|------|------|---------|
| `http` | HTTP 请求检查 | `path`、`port` |
| `tcp` | TCP 端口连通检查 | `port` |
| `command` | 容器内执行命令检查 | `command` |

### 检查流程

1. 等待 `start_period` 秒（默认 30s，让服务启动）
2. 每隔 `interval` 秒检查一次（默认 10s）
3. 最多重试 `retries` 次（默认 5 次）
4. 检查通过则输出成功，否则输出警告并建议查看日志

---

## Claude Code 供应商自动配置

CC-Switch 容器启动时会**自动配置 agnes-ai 供应商**，无需手动在 Web UI 中添加。

**自动配置逻辑**（位于 `conf/claude/start.sh`）：

1. Claude Code 启动时 `start.sh` 检查 `/home/node/.claude/settings.json` 是否存在（首启动 init 自动生成）
2. 若不存在，则从环境变量读取 `AGNES_BASE_URL`、`AGNES_API_KEY`（及 `ANTHROPIC_MODEL`，默认 `agnes-2.5-flash`），写入初始配置：
   ```json
   {
     "providers": {
       "agnes-ai": {
         "baseUrl": "<AGNES_BASE_URL>",
         "apiKey": "<AGNES_API_KEY>",
         "model": "<agnes-2.5-flash>",
         "enabled": true
       }
     },
     "activeProvider": "agnes-ai"
   }
   ```
3. 若配置文件已存在，则跳过，避免覆盖用户自定义配置

> 因此，只要 `.env` 中正确填写了 `LLM_PLATFORM` 与对应平台的 `*_API_KEY` 和 `*_BASE_URL`，Claude Code 启动后即可通过 devpilot-claude-litellm 自动配置对应供应商。无需手动操作 UI。

---

## 配置参考

### 环境变量

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `DEVPILOT_AUTO_DEPLOY` | 开发完成后自动部署 | `false` |

### 默认值

| 配置项 | 默认值 |
|--------|--------|
| 镜像标签 | `latest` |
| Docker 网络 | `devpilot-network` |
| Docker 容器名前缀 | `devpilot-` |
| K8s 命名空间 | `devpilot-services` |
| K8s 副本数 | `1` |
| K8s 镜像拉取策略 | `IfNotPresent` |
| K8s Service 类型 | `ClusterIP` |
| 健康检查重试次数 | `5` |
| 健康检查间隔 | `10s` |
| 健康检查启动等待 | `30s` |

---

## 常见问题

### Q: 如何创建一个可部署的服务

```bash
# 1. 创建服务目录
mkdir -p workspace/my-api

# 2. 创建 service.yaml（极简模式仅需 name + deploy.target）
cat > workspace/my-api/service.yaml << 'EOF'
name: my-api
deploy:
  target: docker
EOF

# 3. 编写服务代码（含 Dockerfile / package.json 等即可自动推断构建类型）

# 4. 部署
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api
```

### Q: 如何开启开发完成后自动部署

在 `.env` 中添加：

```bash
DEVPILOT_AUTO_DEPLOY=true
```

然后在 CC-Switch 容器的 `start.sh` 末尾添加：

```bash
if [ "$DEVPILOT_AUTO_DEPLOY" = "true" ]; then
    bash /workspace/cicd/service-deploy/post-dev-hook.sh
fi
```

### Q: 飞书 Bot 如何触发部署

1. 确保飞书 Bot 已通过 OpenClaw 接入
2. 在 OpenClaw 中配置 `/deploy` 命令路由到 `feishu-deploy-handler.sh`
3. 在飞书群聊中发送消息：`/deploy my-service`

### Q: 如何查看已部署的服务

```bash
# 列出所有可部署的服务
bash cicd/service-deploy/deploy-service.sh --list

# 查看 Docker 容器状态
docker ps --filter "name=devpilot-"

# 查看服务日志
docker logs -f devpilot-<service-name>

# 查看 K8s Pod 状态
kubectl get pods -n devpilot-services
```

### Q: 如何清理已部署的服务

```bash
# 清理单个服务
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api --cleanup

# 通过飞书 Bot
/deploy --cleanup my-api
```

### Q: dry-run 模式有什么用

`--dry-run` 模式会打印所有将执行的命令但不实际执行，适合预览部署流程和调试配置：

```bash
bash cicd/service-deploy/deploy-service.sh --service-dir workspace/my-api --dry-run
```

### Q: 服务部署后如何访问

- **Docker 模式**：通过 `service.yaml` 中 `deploy.docker.ports` 映射的端口访问
- **K8s NodePort 模式**：通过 `<node-ip>:<node_port>` 访问
- **K8s ClusterIP 模式**：集群内部通过 `<service-name>.devpilot-services.svc.cluster.local:<port>` 访问
- **远程 Docker 模式**：通过远程主机 IP + 端口映射访问

### Q: 不写 build.type 会怎样

`build.type` 是可选字段。未指定时，`deploy-service.sh` 会根据服务目录中的文件自动推断：存在 `Dockerfile` 则用 `dockerfile`，存在 `package.json` 则用 `nodejs`，存在 `requirements.txt` 则用 `python`，否则用 `static`。因此极简模式的 `service.yaml` 只需 `name` 和 `deploy.target` 两项。

### Q: CC-Switch 需要手动配置 agnes-ai 供应商吗

不需要。devpilot-claude-litellm 容器启动时 `start.sh` 会根据 `.env` 中的 `LLM_PLATFORM` 与对应平台凭据，将供应商配置写入 `/home/node/.claude/settings.json`。仅在配置文件已存在（用户曾自定义）时才跳过自动配置。

### Q: YAML 解析器为什么不用 yq

为了保持 DevPilot 零额外依赖的特性，`lib/yaml-parser.sh` 使用纯 bash + awk/sed 实现，不需要安装 yq 或 python。支持的语法包括简单键值对、列表和两级嵌套，覆盖 `service.yaml` 的所有字段。
