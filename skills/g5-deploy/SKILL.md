---
name: g5-deploy
description: "提交部署（G5，DevOps 工程师角色）：测试通过后执行构建与上线部署，输出 HITL 上线确认卡片，完成交付闭环。"
---

# 技能：提交部署（Deploy）

<!--
  ============================================================
  技能名称：提交部署
  技能角色：DevOps 工程师 / 运维工程师
  触发条件：测试验证（G4 门控）通过后自动触发
  输入：测试通过的项目代码 + PRD 部署要求
  输出：部署完成的生产环境 + HITL G5 门控卡片
  门控：G5 - 上线确认（用户确认部署结果，完成交付闭环）
  ============================================================
-->

## 一、技能概述

提交部署阶段将测试通过的项目代码构建为可部署的制品，推送到代码仓库，并部署到目标环境。支持多种部署目标（Docker、Docker Compose、Kubernetes）和多种代码托管平台（GitHub、Gitee、GitLab），覆盖从代码提交到生产上线的完整流程。

**核心原则：**
- 安全第一：部署前备份，部署后验证，随时可回滚
- 自动化优先：能自动化的步骤不手动操作
- 可追溯：每次部署有明确版本号和变更记录
- 渐进式发布：生产环境优先使用灰度/蓝绿部署

## 二、部署流程总览

```
代码提交 -> 镜像构建 -> 部署目标选择 -> 执行部署 -> 健康检查 -> 上线确认
   |          |          |              |          |          |
   v          v          v              v          v          v
 Git Push   Docker     Docker/         docker    HTTP/TCP    G5 门控
 Tag 管理   Build      K8s/Helm        compose   命令检查    卡片
```

## 三、执行步骤

### 步骤 1：代码提交与推送

#### 1.1 Git 提交规范

确保所有代码已提交，遵循约定式提交规范：

```bash
# 检查工作区状态
git status

# 暂存所有变更
git add -A

# 提交（遵循约定式提交规范）
git commit -m "feat(模块): 简要描述

- 实现了功能 A
- 修复了问题 B
- 优化了性能 C"
```

**Commit Message 规范：**

| 类型 | 说明 | 示例 |
|------|------|------|
| `feat` | 新功能 | `feat(auth): 添加 JWT 认证` |
| `fix` | 修复 Bug | `fix(api): 修复分页查询空指针` |
| `refactor` | 重构 | `refactor(db): 抽离数据库连接池` |
| `perf` | 性能优化 | `perf(query): 添加索引优化查询` |
| `style` | 代码格式 | `style(eslint): 修复代码格式` |
| `docs` | 文档更新 | `docs(readme): 更新部署说明` |
| `test` | 测试相关 | `test(unit): 补充用户模块单元测试` |
| `chore` | 构建/工具 | `chore(docker): 更新 Dockerfile` |
| `ci` | CI/CD 配置 | `ci(github): 添加自动部署工作流` |

#### 1.2 推送到 GitHub

```bash
# 添加远程仓库（首次）
git remote add origin https://github.com/<用户名>/<项目名>.git

# 推送到 GitHub
git push -u origin main

# 推送标签
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

**GitHub 认证方式：**

```bash
# 方式 1：Personal Access Token（推荐）
git remote set-url origin https://<token>@github.com/<用户名>/<项目名>.git

# 方式 2：SSH Key
git remote set-url origin git@github.com:<用户名>/<项目名>.git

# 方式 3：使用 gh CLI 认证
gh auth login
```

#### 1.3 推送到 Gitee

```bash
# 添加 Gitee 远程仓库
git remote add gitee https://gitee.com/<用户名>/<项目名>.git

# 推送到 Gitee
git push -u gitee main

# 同时推送到 GitHub 和 Gitee（多远程推送）
git remote set-url --add --push origin https://github.com/<用户名>/<项目名>.git
git remote set-url --add --push origin https://gitee.com/<用户名>/<项目名>.git
git push origin main
```

#### 1.4 推送到 GitLab（自建）

```bash
# 添加 GitLab 远程仓库
git remote add gitlab https://gitlab.example.com/<组>/<项目名>.git

# 推送到 GitLab
git push -u gitlab main
```

#### 1.5 版本标签管理

```bash
# 语义化版本号：MAJOR.MINOR.PATCH
# MAJOR: 不兼容的 API 修改
# MINOR: 向下兼容的功能新增
# PATCH: 向下兼容的问题修复

# 创建标签
git tag -a v1.0.0 -m "首个正式版本"

# 查看标签
git tag -l

# 推送所有标签
git push origin --tags

# 删除远程标签
git push origin --delete v1.0.0
```

### 步骤 2：构建 Docker 镜像

#### 2.1 编写 Dockerfile

**多阶段构建（推荐，Node.js 示例）：**

```dockerfile
# ---- 构建阶段 ----
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- 运行阶段（最小化镜像） ----
FROM node:22-alpine AS runner
WORKDIR /app
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nextjs -u 1001
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json .
USER nextjs
EXPOSE 3000
CMD ["node", "dist/server.js"]
```

**Python 项目 Dockerfile：**

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /root/.local /root/.local
COPY . .
ENV PATH=/root/.local/bin:$PATH
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Go 项目 Dockerfile：**

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o server .

FROM alpine:3.20
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/server .
EXPOSE 8080
CMD ["./server"]
```

**Java 项目 Dockerfile：**

```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src ./src
RUN mvn package -DskipTests

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar
EXPOSE 8080
CMD ["java", "-jar", "app.jar"]
```

#### 2.2 构建镜像

```bash
# 构建镜像
docker build -t <项目名>:latest .

# 带版本标签构建（推荐）
docker build -t <项目名>:latest -t <项目名>:v1.0.0 .

# 多架构构建（AMD64 + ARM64）
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <项目名>:latest \
  --push .
```

#### 2.3 推送镜像到 Registry

```bash
# Docker Hub
docker tag <项目名>:latest <用户名>/<项目名>:latest
docker push <用户名>/<项目名>:latest

# GitHub Container Registry (GHCR)
echo $GITHUB_TOKEN | docker login ghcr.io -u <用户名> --password-stdin
docker tag <项目名>:latest ghcr.io/<用户名>/<项目名>:latest
docker push ghcr.io/<用户名>/<项目名>:latest

# 阿里云 ACR
docker login --username=<用户名> registry.cn-hangzhou.aliyuncs.com
docker tag <项目名>:latest registry.cn-hangzhou.aliyuncs.com/<命名空间>/<项目名>:latest
docker push registry.cn-hangzhou.aliyuncs.com/<命名空间>/<项目名>:latest

# Harbor（私有仓库）
docker login harbor.example.com
docker tag <项目名>:latest harbor.example.com/<项目名>/<项目名>:latest
docker push harbor.example.com/<项目名>/<项目名>:latest
```

### 步骤 3：选择部署目标

根据项目需求和基础设施条件，选择合适的部署方式。

#### 3.1 Docker 本地部署（docker run）

适用于单机部署、开发测试环境。

```bash
# 创建 Docker 网络（如不存在）
docker network create app-network 2>/dev/null || true

# 运行容器
docker run -d \
  --name <项目名> \
  --restart unless-stopped \
  --network app-network \
  -p 8080:8080 \
  -e NODE_ENV=production \
  -e DATABASE_URL=postgresql://user:pass@db:5432/mydb \
  -v $(pwd)/data:/app/data \
  <项目名>:latest

# 查看容器状态
docker ps --filter "name=<项目名>"

# 查看日志
docker logs -f <项目名>
```

#### 3.2 Docker Compose 部署

适用于多容器编排、单机生产环境。

**docker-compose.yml 示例：**

```yaml
version: '3.8'

services:
  app:
    image: <项目名>:latest
    container_name: <项目名>
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      - NODE_ENV=production
      - DATABASE_URL=postgresql://user:pass@postgres:5432/mydb
      - REDIS_URL=redis://redis:6379
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    volumes:
      - ./data/app:/app/data
    networks:
      - app-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 512M

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=user
      - POSTGRES_PASSWORD=pass
      - POSTGRES_DB=mydb
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - app-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U user"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD:-redis123}
    volumes:
      - ./data/redis:/data
    networks:
      - app-network

networks:
  app-network:
    driver: bridge
```

**部署命令：**

```bash
# 启动所有服务
docker compose up -d

# 重新构建并启动
docker compose up -d --build

# 查看状态
docker compose ps

# 查看日志
docker compose logs -f

# 停止服务（保留数据）
docker compose down

# 停止并删除数据卷（危险！）
docker compose down -v
```

#### 3.3 Docker 远程部署（Docker API / SSH）

适用于部署到远程服务器。

**方式 1：通过 DOCKER_HOST 连接远程 Docker**

```bash
# 设置远程 Docker 主机（SSH 方式）
export DOCKER_HOST=ssh://root@192.168.1.100

# 在远程主机上构建和运行
docker build -t <项目名>:latest .
docker run -d --name <项目名> -p 8080:8080 <项目名>:latest

# 恢复本地 Docker
unset DOCKER_HOST
```

**方式 2：通过 Docker API（TCP）**

```bash
# 远程 Docker 开启 API（在远程服务器上配置）
# /etc/docker/daemon.json:
# {"hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2375"]}

# 设置 DOCKER_HOST 指向远程 Docker
export DOCKER_HOST=tcp://192.168.1.100:2375

# 执行远程 Docker 命令
docker info
docker run -d --name <项目名> -p 8080:8080 <项目名>:latest
```

**方式 3：导出镜像传输（无 Registry 场景）**

```bash
# 导出镜像为文件
docker save <项目名>:latest | gzip > <项目名>.tar.gz

# 传输到远程服务器
scp <项目名>.tar.gz root@192.168.1.100:/tmp/

# 在远程服务器上加载并运行
ssh root@192.168.1.100 "docker load < /tmp/<项目名>.tar.gz"
ssh root@192.168.1.100 "docker run -d --name <项目名> -p 8080:8080 <项目名>:latest"
```

**方式 4：通过 Docker Compose 远程部署**

```bash
# 传输 docker-compose.yml 到远程服务器
scp docker-compose.yml root@192.168.1.100:/opt/<项目名>/

# 远程执行 docker compose
ssh root@192.168.1.100 "cd /opt/<项目名> && docker compose up -d"
```

#### 3.4 Kubernetes 部署（kubectl）

适用于集群部署、高可用生产环境。

**方式 1：使用 kubectl 原生清单**

```bash
# 应用部署清单
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml

# 查看部署状态
kubectl get pods -n <命名空间>
kubectl get svc -n <命名空间>
kubectl get ingress -n <命名空间>

# 查看 Pod 日志
kubectl logs -f deployment/<项目名> -n <命名空间>

# 进入 Pod 调试
kubectl exec -it <pod-name> -n <命名空间> -- /bin/sh
```

**K8s 部署清单示例（deployment.yaml）：**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <项目名>
  namespace: <命名空间>
  labels:
    app: <项目名>
spec:
  replicas: 3
  selector:
    matchLabels:
      app: <项目名>
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: <项目名>
    spec:
      containers:
      - name: app
        image: <镜像地址>:<标签>
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: <项目名>-config
        - secretRef:
            name: <项目名>-secret
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: <项目名>
  namespace: <命名空间>
spec:
  type: NodePort
  selector:
    app: <项目名>
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
```

**方式 2：使用 Helm Chart 部署（推荐）**

```bash
# 创建 Helm Chart
helm create <项目名>

# 修改 values.yaml 配置
vim <项目名>/values.yaml

# 安装 Chart（首次部署）
helm install <项目名> ./<项目名> -n <命名空间>

# 升级 Chart（更新部署）
helm upgrade <项目名> ./<项目名> -n <命名空间>

# 查看 release 状态
helm ls -n <命名空间>

# 查看 release 历史（用于回滚）
helm history <项目名> -n <命名空间>

# 回滚到上一版本
helm rollback <项目名> -n <命名空间>

# 卸载 Chart
helm uninstall <项目名> -n <命名空间>
```

**Helm values.yaml 示例：**

```yaml
# 副本数
replicaCount: 3

# 镜像配置
image:
  repository: <镜像地址>
  tag: latest
  pullPolicy: IfNotPresent

# Service 配置
service:
  type: ClusterIP
  port: 80

# Ingress 配置
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: app.example.com
      paths:
        - path: /
          pathType: Prefix

# 资源限制
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# 自动扩缩容
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

# 环境变量
env:
  - name: NODE_ENV
    value: production
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: url
```

### 步骤 4：CI/CD 流水线集成

#### 4.1 GitHub Actions 工作流

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy

on:
  push:
    branches: [main]
    tags: ['v*']

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=sha
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build-and-push
    runs-on: ubuntu-latest
    if: startsWith(github.ref, 'refs/tags/v')
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-kubectl@v4
      - name: 配置 kubectl
        run: |
          echo "${{ secrets.KUBE_CONFIG }}" | base64 -d > kubeconfig
      - name: 部署到 K8s
        run: |
          kubectl set image deployment/<项目名> app=ghcr.io/${{ env.IMAGE_NAME }}:${{ github.ref_name }} -n production
          kubectl rollout status deployment/<项目名> -n production
```

#### 4.2 Gitee Go 工作流

```yaml
# .workflow/deploy.yml
name: Build and Deploy
displayName: 构建并部署
triggers:
  push:
    branches:
      include:
        - main

stages:
  - name: build
    displayName: 构建镜像
    tasks:
      - task: docker@1.0.0
        displayName: 构建并推送
        inputs:
          dockerfile: Dockerfile
          imageName: <镜像地址>:$(git rev-parse --short HEAD)
          push: true
          registry: <registry-url>
          username: $(REGISTRY_USER)
          password: $(REGISTRY_PASS)

  - name: deploy
    displayName: 部署
    dependsOn: build
    tasks:
      - task: shell@1.0.0
        displayName: 部署到 Docker
        inputs:
          script: |
            ssh root@<server> "docker pull <镜像地址>:latest && docker compose up -d"
```

#### 4.3 GitLab CI/CD

```yaml
# .gitlab-ci.yml
stages:
  - build
  - test
  - deploy

variables:
  IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA

build:
  stage: build
  image: docker:24
  services:
    - docker:24-dind
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build -t $IMAGE_TAG .
    - docker push $IMAGE_TAG

deploy:production:
  stage: deploy
  image: bitnami/kubectl:latest
  environment:
    name: production
  rules:
    - if: $CI_COMMIT_TAG
  script:
    - kubectl set image deployment/<项目名> app=$IMAGE_TAG -n production
    - kubectl rollout status deployment/<项目名> -n production
```

### 步骤 5：健康检查

部署完成后，执行健康检查确保服务正常运行。

```bash
# HTTP 健康检查
curl -sf http://localhost:8080/health | jq .

# TCP 端口连通检查
nc -zv localhost 8080

# Docker 容器健康状态
docker inspect --format='{{.State.Health.Status}}' <容器名>

# K8s Pod 健康状态
kubectl get pods -n <命名空间> -l app=<项目名>
kubectl describe pod <pod-name> -n <命名空间>

# 持续等待服务就绪（30 秒内每 2 秒检查一次）
for i in $(seq 1 15); do
  if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
    echo "[$i/15] 服务健康"
    break
  fi
  echo "[$i/15] 等待服务就绪..."
  sleep 2
done
```

### 步骤 6：回滚策略

当部署出现问题时，快速回滚到上一个稳定版本。

#### Docker 回滚

```bash
# 停止当前版本容器
docker stop <容器名> && docker rm <容器名>

# 使用上一个版本重新启动
docker run -d --name <容器名> -p 8080:8080 <项目名>:v1.0.0
```

#### Docker Compose 回滚

```bash
# 修改 docker-compose.yml 中的镜像标签为上一版本
# image: <项目名>:v1.0.0

# 重新部署
docker compose up -d
```

#### Kubernetes 回滚

```bash
# 查看部署历史
kubectl rollout history deployment/<项目名> -n <命名空间>

# 回滚到上一版本
kubectl rollout undo deployment/<项目名> -n <命名空间>

# 回滚到指定版本
kubectl rollout undo deployment/<项目名> --to-revision=2 -n <命名空间>

# 查看回滚状态
kubectl rollout status deployment/<项目名> -n <命名空间>
```

#### Helm 回滚

```bash
# 查看 release 历史
helm history <项目名> -n <命名空间>

# 回滚到上一版本
helm rollback <项目名> 1 -n <命名空间>
```

### 步骤 7：高级部署策略

#### 蓝绿部署（Blue-Green Deployment）

```bash
# 1. 部署新版本（green 环境），与旧版本（blue）并行
kubectl apply -f k8s/deployment-green.yaml -n <命名空间>

# 2. 等待 green 环境就绪
kubectl rollout status deployment/<项目名>-green -n <命名空间>

# 3. 切换 Service 流量到 green 环境
kubectl patch service <项目名> -n <命名空间> \
  -p '{"spec":{"selector":{"version":"green"}}}'

# 4. 验证无误后，删除 blue 环境
kubectl delete deployment <项目名>-blue -n <命名空间>
```

#### 金丝雀发布（Canary Release）

```yaml
# K8s 金丝雀部署（少量副本先行验证）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <项目名>-canary
  namespace: <命名空间>
spec:
  replicas: 1  # 先部署 1 个副本进行灰度
  selector:
    matchLabels:
      app: <项目名>
      track: canary
  template:
    metadata:
      labels:
        app: <项目名>
        track: canary
    spec:
      containers:
      - name: app
        image: <镜像地址>:new-version
        ports:
        - containerPort: 8080
```

```bash
# 逐步增加金丝雀副本数
kubectl scale deployment/<项目名>-canary --replicas=2 -n <命名空间>

# 使用 Istio/Envoy 进行精细化流量控制（高级）
# 流量比例：10% -> 30% -> 50% -> 100%
```

## 四、输出格式

### 部署报告模板

```markdown
# 部署报告

## 项目信息
- 项目名称：[名称]
- 部署版本：[v1.0.0]
- 部署时间：[YYYY-MM-DD HH:MM]
- 部署环境：[Docker / K8s / 远程服务器]

## 代码提交
- 仓库地址：[GitHub/Gitee/GitLab URL]
- 提交哈希：[commit-hash]
- 标签：[v1.0.0]

## 镜像信息
- 镜像地址：[registry/repo:tag]
- 镜像大小：[XX MB]
- 构建时间：[XX 秒]

## 部署详情
- 部署目标：[Docker / Docker Compose / K8s]
- 容器/Pod 数量：[N]
- 资源限制：[CPU/Memory]
- 端口映射：[宿主机端口 -> 容器端口]

## 健康检查
| 检查项 | 结果 | 响应时间 |
|--------|------|---------|
| HTTP /health | PASS | 50ms |
| TCP 端口 | PASS | 1ms |
| 数据库连接 | PASS | 10ms |

## 访问地址
- 内部地址：http://<容器名>:8080
- 外部地址：http://<域名或IP>:8080
- K8s Service：<项目名>.<命名空间>.svc.cluster.local

## 回滚方案
- 回滚命令：[具体命令]
- 上一版本：[v0.9.0]
- 回滚预计时间：[XX 秒]
```

### HITL G5 门控卡片

```
[G5] 上线确认 - [项目名称]

部署已完成！

部署信息：
- 版本：v1.0.0
- 环境：[Docker / K8s]
- 镜像：[镜像地址]
- 实例数：[N] 个

健康检查：
- HTTP 检查：通过（50ms）
- TCP 检查：通过
- 数据库连接：通过

访问地址：http://[域名或IP]:8080

回滚方案：已准备（上一版本 v0.9.0）

[确认上线] [需要回滚]
```

## 五、输出标准

- 代码已推送到指定仓库（GitHub / Gitee / GitLab）
- Docker 镜像已构建并推送到 Registry
- 部署清单 / Helm Chart 已保存到项目中
- 健康检查全部通过
- 部署报告保存为 `workspace/[项目名]/docs/DEPLOY_REPORT.md`
- 回滚方案已准备就绪
- G5 门控卡片包含访问地址和回滚方案

## 六、部署检查清单

| 检查项 | 说明 | 状态 |
|--------|------|------|
| 代码已提交 | 所有变更已 commit 并 push | ☐ |
| 版本标签 | 已创建语义化版本标签 | ☐ |
| Dockerfile | 使用多阶段构建，镜像最小化 | ☐ |
| 镜像已推送 | 推送到 Registry 并验证可拉取 | ☐ |
| 环境变量 | 敏感信息通过 Secret / 环境变量注入 | ☐ |
| 健康检查 | 配置 liveness / readiness 探针 | ☐ |
| 资源限制 | 配置 CPU / Memory 限制 | ☐ |
| 日志收集 | 日志可查询和持久化 | ☐ |
| 回滚方案 | 已验证回滚命令可用 | ☐ |
| HTTPS / 域名 | 生产环境配置 TLS 证书 | ☐ |

## 七、门控流转

| 用户操作 | 流转方向 |
|---------|---------|
| 点击「确认上线」 | 部署完成，项目交付闭环 |
| 点击「需要回滚」 | 执行回滚流程，回滚后返回 Test 阶段排查问题 |
| 超时未响应（48h） | 发送提醒，72h 未响应则保持当前版本运行 |

**重要：** G5 门控通过后，整个研发流程闭环完成。建议在上线后 24 小时内持续监控服务状态，关注日志异常和性能指标。
