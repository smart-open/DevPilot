# AGENT.md - DevPilot AI Agent 速查卡

> 写给任何接手 DevPilot 的 AI Agent：5 分钟读懂项目，10 分钟能动手改。
> 项目代码即真相（README/手册可能滞后），任何冲突以代码为准；本卡优先给出实战指针。

---

## 1. 一句话定位

**DevPilot = Docker Compose 一键部署的 AI 自主持续交付平台**——把"飞书 AI 机器人 + Claude Code 编程助手 + LiteLLM 协议翻译 + Redis 缓存"塞进 3 个容器，对外表现为"在飞书里对话即可开发并自动部署服务"。

**支持 5 个大模型平台**：agnes（默认）/ deepseek / glm（智谱）/ ark（火山方舟）/ bailian（百炼），统一走 OpenAI Chat Completion 协议，切换只需 `.env` 的 `LLM_PLATFORM`。

---

## 2. 架构一览（3 容器，bridge 网络 `devpilot-network`）

```
┌─────────────────────────────────────────────────────────────────────┐
│                       devpilot-network (bridge)                       │
│                                                                       │
│  ┌──────────────────────┐    redis:6379      ┌────────────────────┐   │
│  │ devpilot-redis       │◄────service name───│ devpilot-openclaw  │   │
│  │ redis:8.8.1-alpine   │   （不暴露宿主）   │ node + openclaw@    │   │
│  │ 内部 6379            │                    │   2026.7.1-2        │   │
│  └──────────────────────┘                    │ 18789 → 宿主       │   │
│                                              │ 飞书 WS 长连接 +   │   │
│                                              │ OpenAI 协议直连     │   │
│                                              │   上游 LLM          │   │
│                                              └─────────┬──────────┘   │
│                                                        │              │
│                              devpilot-claude-litellm:4000              │
│                                                        │              │
│  ┌─────────────────────────────────────────────────────▼──────────┐   │
│  │ devpilot-claude-litellm                                            │   │
│  │ node:24-bookworm + claude-code@2.1.241 + 内置 litellm venv        │   │
│  │ 双进程：后台 litellm (127.0.0.1:4000，容器内回环)                   │   │
│  │       + 前台 claude CLI（同容器连 litellm）                        │   │
│  │ 宿主端口：127.0.0.1:4000（仅本机回环，供宿主侧脚本验证）            │   │
│  └────────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────┘
```

### 关键事实（已实现，不要改坏）
- **3 容器**：redis + openclaw + devpilot-claude-litellm（devpilot-claude 与 litellm 已合并）。
- **bridge 网络 + 服务名**：Redis 对外发布 `${REDIS_PORT:-6379}:6379`（宿主机可直连，密码鉴权），OpenClaw 仍经 `redis:6379`；OpenClaw 经 `devpilot-claude-litellm:4000` 跨容器访问 litellm。`devpilot-network` 在 compose 中显式 `name: devpilot-network`，确保外部 compose 调用同名。
- **DEVPILOT_HOST_IP**：bridge 模式下 OpenClaw 容器内是 172.x 内网 IP，对浏览器无意义；如要局域网 `http://<LAN_IP>:18789` 访问 Control UI，必须在 `.env` 显式填写宿主机 LAN IP（脚本会写入 `gateway.controlUi.allowedOrigins`）。
- **litellm 双进程**：合并容器内由 `conf/claude/start.sh` 后台拉起 litellm（venv）+ 前台保活 Claude Code；不再有独立 litellm 容器。

### 命名约定速查（service key vs container_name vs image vs DNS）

同一个容器在 docker compose 与 docker 命令里**名字可能不同**——命令不要混淆：

| 用途 | 命令形式 | 用哪个名字 | claude-litellm 服务示例 |
|---|---|---|---|
| `docker compose <cmd> <svc>` | build / restart / logs / ps / exec | **service key**（低前缀） | `docker compose restart claude-litellm` |
| `docker <cmd> <container>` | exec / logs / stop / rm / inspect / stats | **container_name**（保留品牌） | `docker exec devpilot-claude-litellm bash` |
| docker image tag | pull / rmi / tag | **image tag**（带 devpilot- 前缀） | `devpilot-claude-litellm:latest` |
| 跨容器 DNS（URL host） | `env_file:` / URL host 部 | **container_name**（bridge 内 DNS） | `LITELLM_PROXY_URL=http://devpilot-claude-litellm:4000` |
| 数据持久化目录 | 宿主机路径 | **路径前缀**（与服务 key 对齐，2026-08-26 起；旧 `data/devpilot-claude` 不迁移，升级走 rebuild.sh 清空重建） | `data/claude-litellm/` |

最易错的两类命令：

```bash
# ❌ 错用 container_name 当 service key → no such service
docker compose build devpilot-claude-litellm
docker compose restart devpilot-claude-litellm

# ❌ 错用 service key 当 container_name → No such container
docker exec claude-litellm bash
docker logs claude-litellm

# ✅ service key 用于 docker compose 子命令
docker compose build claude-litellm
docker compose restart claude-litellm
docker compose exec claude-litellm bash

# ✅ container_name 用于 docker 子命令（与 compose cmd 等价，但必须用 container_name）
docker exec devpilot-claude-litellm bash
docker logs -f devpilot-claude-litellm
docker rm -f devpilot-claude-litellm
```

反向派生（避免又踩错）：

```bash
docker compose config --services    # 列出全部 service key
docker compose config | grep container_name    # 列出全部 container_name
```

历史原因：早期 `docker-compose.yml` 用 `devpilot-*` 作为 service key，导致 compose
自动 image tag 拼成 `devpilot-devpilot-claude-litellm`（双前缀）；commit 812c51a
+ d4fa69b + bc285b8 解耦为 service key（低前缀）+ container_name（高前缀）两类。

---

## 3. 目录与文件速查

| 关注点 | 关键路径 |
|---|---|
| 编排 | `docker-compose.yml`（**已有 3 容器 + 服务名**） |
| 版本 | `versions.env`（**单一配置源**：NODE_IMAGE_TAG / OPENCLAW / CLAUDE_CODE / LITELLM） |
| 配置向导 | `init.sh`（交互生成 `.env`） |
| 一键部署 | `deploy.sh`（首次 7 步详细日志） |
| 启停 | `service.sh`（start/stop/restart/status/health/logs） |
| 端到端验证 | `scripts/verify.sh`（8 阶段，PASS/FAIL 汇总；阶段 6 检查技能三层 + AGENTS.md + SSH 通道） |
| 全量重建 | `scripts/rebuild.sh`（清空/保留数据后自动重跑 `setup-skills.sh`，防技能静默丢失） |
| SSH 部署通道宿主机配置 | `scripts/setup-deploy-ssh.sh`（root 一键：受限用户 + forced-command 密钥 + known_hosts + 自测，幂等） |
| OpenClaw 配置生成 | `conf/openclaw/init-openclaw.sh`（容器内首启运行，含 schema 自愈与 provider 过滤；`OPENCLAW_MODEL` 覆盖 Agent 模型；种子 workspace/AGENTS.md） |
| Agent 硬路由规则 | `conf/openclaw/AGENTS.md`（OpenClaw 每次会话自动加载：`/` 命令必须命中技能、开发需求必须走 G1→G5；由 setup-skills.sh 安装到 `data/openclaw/.openclaw/workspace/`，镜像 init 种子兜底） |
| OpenClaw 模板 | `conf/openclaw/openclaw.default.json`（含 `{{...}}` 占位符） |
| Claude + litellm 启动 | `conf/claude/start.sh`（双进程：litellm 后台 + Claude 前台） |
| LiteLLM 配置生成 | `conf/litellm/gen_config.py`（读 .env → 输出 `/opt/litellm/litellm_config.yaml`） |
| 公共函数库 | `cicd/lib/common.sh`（颜色/日志/健康检查/workspace 定位 `resolve_workspace_dir()`，所有脚本 source 它） |
| CI Lint | `cicd/ci/scripts/lint.sh` |
| K8s Helm 部署 | `cicd/scripts/deploy.sh --mode k8s --helm`（K8s 唯一方式，不再有 kubectl 原生清单） |
| 服务自动部署钩子 | `cicd/service-deploy/post-dev-hook.sh`（由 `start.sh` 在 `DEVPILOT_AUTO_DEPLOY=true` 时触发） |
| 技能文件 | `skills/`（8 个技能**目录** `<name>/SKILL.md` + YAML frontmatter：`explore / prd / plan / dev / review / test / g5-deploy / deploy`）；`setup-skills.sh` 安装到 `data/openclaw/.openclaw/skills/`（OpenClaw managed skills root）并同步 AGENTS.md 到 workspace，装完必须 `docker compose restart openclaw`。斜杠命令名规范化为小写+下划线：`/g5_deploy` |
| 主力用户文档 | `用户操作手册.md`（操作）/ `运维操作手册.md`（运维）/ `产品架构技术设计说明书.md`（架构） |

> ⚠️ **不要盲信 README 表格里的容器数**——历史上从 4 容器合并到 3 容器（commit `500c286`），如果再次合并/拆分，请同步更新本卡、README、运维手册 §3、表 1。

---

## 4. 关键命令（必背）

### 服务操作（推荐 service.sh / Makefile）
```bash
sh service.sh start            # 全部启动（full 模式）
sh service.sh start bot        # 仅飞书机器人
sh service.sh start dev        # 仅开发环境（Claude + litellm）
sh service.sh stop
sh service.sh restart
sh service.sh status
sh service.sh health           # 浅健康检查
sh scripts/verify.sh           # 深端到端验证（8 阶段）
```

### Docker 直查
```bash
docker compose ps
docker compose logs -f openclaw
docker exec devpilot-openclaw cat /data/openclaw/.openclaw/openclaw.json
docker exec devpilot-openclaw curl -fsS http://127.0.0.1:18789/healthz
docker exec devpilot-claude-litellm cat /opt/litellm/litellm_config.yaml
docker exec devpilot-claude-litellm cat /home/node/.claude/settings.json
docker exec devpilot-redis sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
```

### 模型配置入口
- `conf/litellm/gen_config.py`：决定哪些平台注册为模型（仅 API Key 非占位符的平台）。改完**必须重新构建** `devpilot-claude-litellm` 镜像，否则只重启容器会沿用旧镜像。
- `docker-compose.yml` 的 env `environment` 块：决定哪些环境变量被注入 OpenClaw / Claude-litellm 容器。

---

## 5. 重要约束与红线

| 红线 | 后果 |
|---|---|
| 不要改 `versions.env` 后只重启容器 | Dockerfile ARG 默认从环境变量读取，不重新构建不会刷新版本 |
| 不要把 `devpilot-claude-litellm` 端口 `4000:4000` 改成 `0.0.0.0` | 该端口只对宿主机回环开放（`127.0.0.1:4000:4000`），跨容器走服务名 `devpilot-claude-litellm:4000` |
| 不要给 Redis 加宿主端口 | bridge 模式下保留网络隔离；要调试用 `docker exec` |
| 不要在 OpenClaw 容器内手动改 `/data/openclaw/.openclaw/openclaw.json` 顶层结构 | 2026.7.x 严格 schema 校验，非法字段 → restart-loop。改用 `openclaw config set ...` 或 `make reset-openclaw` |
| 不要给未配 key 的平台保留 provider | init-openclaw.sh §3.4.1 已过滤，但若是手动改模板/配置请保留同一逻辑 |
| 不要把 `OPENCLAW_GATEWAY_TOKEN` 留为 `change-me-to-secure-token` | init-openclaw.sh 会自动生成；占位符运行可视但安全风险大 |
| 不要给 `common.sh` 的 `_DEVPILOT_COMMON_LOADED` 加 `export` | guard 变量泄漏进子进程（如 `bash deploy-service.sh`），子脚本 source 公共库被短路 → `setup_error_trap: command not found`（2026-08-26 已修复，防回归） |
| 部署脚本不要自行拼接 `${PROJECT_ROOT}/workspace` | 统一用 `common.sh:resolve_workspace_dir()`（WORKSPACE_DIR env > 容器 `/workspace` > PROJECT_ROOT/workspace），否则容器内 `docker exec` 直调会回退到不存在的 `/opt/devpilot/workspace` |
| 不要用 `ps` 数子进程判定 OpenClaw 频道活跃度 | 频道插件（如飞书）以 WS 长连接跑在 gateway Node 进程内，无独立子进程，`ps -ef \| grep feishu` 恒为 0；用 `openclaw status --deep` 的 Channels 表（Feishu \| ON \| OK），兜底 `openclaw health --json`（2026-08-26 已修复 verify.sh，防回归） |
| 不要按固定缩进匹配 PyYAML 生成的 YAML 列表项 | `yaml.safe_dump` 的序列项顶格（列 0），`/^  - model_name:/` 类模式恒不匹配；用 `/^[[:space:]]*- /` 容忍任意缩进（2026-08-26 已修复 verify.sh，防回归） |

---

## 6. 已知遗留与待办

- **OpenClaw `gateway.controlUi.allowInsecureAuth=true` 在容器内被显式声明以绕过 HTTP 明文认证**——生产环境套反向代理 + TLS 后应设 `DEVPILLOT_INSECURE_AUTH=false`。
- **OpenClaw gateway 存在堆增长倾向（2026-08-26 实测）**：处理长 SSE 流式回复后 V8 堆可增至 ~250MB，曾撞默认堆上限崩溃（`JavaScript heap out of memory`，非 137 OOM）。已缓解：compose 配 `NODE_OPTIONS=--max-old-space-size=512` + 容器限制 1024M。若长会话下仍复现，按运维手册 §8.1.4/§13.7 同步上调堆与容器限制；根治需盯上游版本。

---

## 7. 跨文档/脚本一致性检查（提交前必做）

修改任何一处都要同步：
- `docker-compose.yml` ←→ `versions.env`（版本同步）
- `conf/openclaw/init-openclaw.sh`（新版飞书格式 + provider 过滤 + allowedOrigins）←→ `conf/openclaw/openclaw.default.json`（模板同步）
- `scripts/verify.sh` ←→ `cicd/scripts/deploy.sh`（部署/健康一致性）
- `skills/*.md`（AI 技能）←→ `setup-skills.sh`（安装路径）←→ `conf/openclaw/AGENTS.md`（硬路由规则，三者同装）
- `feishu-deploy-handler.sh`（SSH 自动转发）←→ `scripts/setup-deploy-ssh.sh`（宿主机 forced-command 配置）←→ `.env.example`（DEPLOY_SSH_* 文档）

---

## 8. 不要做的事（来自历史审查）

- ❌ 不要把 OpenClaw 改回 `network_mode: host`（已合并入 bridge，参见 commit `7638f6e` P0-7）
- ❌ 不要把 Redis 重新开放宿主端口（同样 P0-7）
- ❌ 不要拆回 4 容器（`devpilot-claude` 与 `devpilot-litellm` 已合并，commit `500c286`）
- ❌ 不要升级 LiteLLM 到 1.82.7/1.82.8（TeamPCP 供应链投毒，PyPI 已隔离；固定 `1.82.6`，要升只用 `1.83.0` 干净版）
- ❌ 不要把 `LITELLM_PROXY_URL` 改成 `litellm:4000` 之类的旧引用（合并后服务名是 `devpilot-claude-litellm`）
- ❌ 不要以平铺 `*-SKILL.md` 文件安装技能（OpenClaw 只发现「目录 + `SKILL.md` + frontmatter（name/description）」格式，平铺文件静默不加载——2026-08-26 前全部技能因此从未生效，含 `/deploy` 路由）
- ❌ 不要给技能起与命令语义冲突的重复 name（`deploy` 已被命令路由技能占用，研发流程 G5 技能叫 `g5-deploy`）
- ❌ 不要让 Agent 绕过 `feishu-deploy-handler.sh` 自行 ssh 或自创部署方案（通道判定已下沉到 handler 内部，`skills/deploy/SKILL.md` 与 AGENTS.md 双重禁止；模型临场发挥正是 2026-08-29 修复的问题）
- ❌ 不要从 `rebuild.sh` 移除 `setup-skills.sh` 自动重跑（清空 `data/` 会抹掉技能与 AGENTS.md，不重装则飞书斜杠命令全部退化为普通对话）

---

## 9. 排障快速跳转（50% 时间在这里）

| 现象 | 第一跳 |
|---|---|
| 容器起不来 | `sh service.sh status && docker compose logs --tail=100 <name>` |
| 飞书无响应 | `docker compose logs -f openclaw \| grep -iE 'feishu\|ws'` |
| 浏览器 Control UI 拒绝连接 | `grep -E 'allowInsecureAuth\|allowedOrigins' data/openclaw/.openclaw/openclaw.json`；`.env` 设 `DEVPILOT_HOST_IP=<LAN_IP>` |
| verify.sh 报告 litellm 未注册模型（实际有调用） | 看 `docker exec devpilot-claude-litellm cat /opt/litellm/litellm_config.yaml` 确认 |
| verify.sh 报告 OpenClaw gateway 异常 | 用 `docker exec devpilot-openclaw curl http://127.0.0.1:18789/healthz` 看真实 HTTP 码 |
| Claude Code 调用 4xx | 看 `docker compose logs -f claude-litellm`；以及 `/home/node/.claude/settings.json` 是否仍指向 `127.0.0.1:4000` |
| Claude Code 报 "no such model" | `/opt/litellm/litellm_config.yaml` 的 `model_name` 与 `ANTHROPIC_MODEL` 要一致 |
| OpenClaw 启动循环 / 立刻退出 | `docker exec devpilot-openclaw cat /tmp/oc_validate.log` / `oc_doctor.log`（init-openclaw.sh 自动写入） |
| openclaw 日志 `JavaScript heap out of memory`（V8 堆上限，非 137 OOM） | 已配 `NODE_OPTIONS=--max-old-space-size=512` + 容器 1024M；仍复现则按运维手册 §13.7 方法 3 同步上调堆与容器限制 |
| 飞书 `/deploy` 不识别 / Agent 乱猜命令 | `docker exec devpilot-openclaw openclaw skills list` 看技能是否加载；`ls data/openclaw/.openclaw/workspace/AGENTS.md` 看硬路由规则；确认 `./setup-skills.sh` 已跑（目录格式）+ `docker compose restart openclaw` 已重启；轻量模型档（flash/turbo）遵循度弱，`.env` 设 `OPENCLAW_MODEL=<平台>/<强模型>`；曾因平铺文件格式全部技能不加载（2026-08-26 修复） |
| `/deploy` 回贴带 `[ssh][warn] 受控通道不可达` | SSH 受控通道故障但已自动回退本地（保底可用）；重跑 `sudo bash scripts/setup-deploy-ssh.sh` + `docker compose up -d --build openclaw`，详见运维手册 §13.17 |
| `TOKEN required` | `OPENCLAW_GATEWAY_TOKEN` 不要用占位符；让 init-openclaw.sh §2.1 自动生成 |
| **详细排障手册** | `运维操作手册.md §13` |

---

## 10. 提交与文档约定（用户偏好）

- 项目默认 git workflow：**本地多 commit 领先 origin/master**，**不自动 push**。
- 文档以中文输出，与目录中 `*.md` 命名风格一致。
- 修改版本只在 `versions.env` 一处；改完跑 `make rebuild && make up`。
- 飞书机器人消息走 WebSocket 长连接（无需公网回调）。

> **本卡维护**：当代码、容器数、命令、文档结构发生变更时，同步更新本卡对应章节，避免下一位 Agent 误判。
