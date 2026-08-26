# 技能：/deploy 部署命令路由（Deploy Command Router）

<!--
  ============================================================
  技能名称：/deploy 部署命令路由
  技能角色：部署命令解释器 / 命令路由器
  触发条件：用户消息以 "/deploy" 开头（飞书单聊或 @机器人 群聊）
  输入：以 /deploy 开头的命令文本
  输出：命令执行结果（原样回贴）或执行通道不可用时的标准指引
  门控：--cleanup / --restart 等变更类命令执行前需用户确认
  ============================================================
-->

## 一、技能概述

本技能定义飞书 `/deploy` 命令的**确定性路由规则**：消息以 `/deploy` 开头时不走
LLM 意图推断，按固定规则把参数透传给 `cicd/service-deploy/feishu-deploy-handler.sh`
执行，并把输出原样回贴给用户。

**为什么需要本技能**：OpenClaw 2026.7.x 没有 `/deploy` 硬路由，历史上
`/deploy` 被当作普通 prompt 交给大模型，Agent 常猜成不存在的
`openclaw deploy` 子命令。本技能通过规则注入纠正该行为。

> 区分：`deploy-SKILL.md` 是研发流程 G5「提交部署」阶段技能（DevOps 角色），
> 面向代码交付流程；本技能只做**命令路由**，两者互补、不冲突。

## 二、硬性路由规则（必须遵守）

1. **前缀识别**：用户消息（去除 @机器人 等前导噪声后）以 `/deploy` 开头即命中本技能。
2. **参数透传**：`/deploy` 之后的参数**原样**传给命令处理器，禁止改写、
   补全、翻译或猜测"用户可能想要的命令"。
3. **禁止自由发挥**：不要调用 `openclaw deploy`（**不存在的子命令**，OpenClaw CLI
   仅有 `gateway / channels / plugins / config / doctor / security`）。
4. **输出原样回贴**：命令的 stdout/stderr 即回复内容，不要摘要、不要改写、
   不要追加自己的分析（可在末尾附一行简短说明，如需要）。
5. **非 /deploy 开头**的消息不适用本技能，正常对话处理。

## 三、命令白名单

| 命令 | 功能 | 变更类（需确认） |
|------|------|----------------|
| `/deploy <服务名>` | 部署指定服务 | 是 |
| `/deploy <服务名> --tag <标签>` | 指定镜像标签部署 | 是 |
| `/deploy --list` | 列出所有可部署服务 | 否 |
| `/deploy --status <服务名>` | 查看服务运行状态 | 否 |
| `/deploy --logs <服务名>` | 查看服务最近 50 行日志 | 否 |
| `/deploy --restart <服务名>` | 重启服务 | 是 |
| `/deploy --cleanup <服务名>` | 停止并清理服务（删容器/镜像） | 是 |
| `/deploy --help` | 显示帮助 | 否 |

变更类命令执行前必须先回复用户确认（复述命令与影响面），得到肯定答复后才执行。

## 四、执行通道判定

按以下顺序判定用哪条通道执行（通道是否配置以环境变量 `DEPLOY_CHANNEL` /
`DEPLOY_SSH_HOST` 是否存在为准）：

### 通道 A：SSH 受控通道（长期方案 Phase 2，推荐）

```
ssh -o BatchMode=yes devpilot-deploy@${DEPLOY_SSH_HOST} "/deploy --list"
```

- 宿主机侧用 SSH forced command 把该密钥锁定为只能执行
  `feishu-deploy-handler.sh "$SSH_ORIGINAL_COMMAND"`（见用户操作手册 4.7 Phase 2）。
- 超时建议 120s（构建/部署类命令耗时较长）。

### 通道 B：通道未配置时的标准回复（当前默认）

不要尝试在 OpenClaw 容器内直接执行部署脚本（本容器无 docker CLI、未挂载
`cicd/`，必然失败）。回复用户以下指引：

```
/deploy 命令的执行通道尚未配置。当前可用方式（任选其一）：

1. 宿主机 shell 直接执行：
   bash cicd/service-deploy/feishu-deploy-handler.sh "/deploy --list"

2. 查询类命令可进 devpilot-claude-litellm 容器执行：
   docker exec devpilot-claude-litellm bash /opt/devpilot/cicd/service-deploy/deploy-service.sh --list

   注意：容器内无 docker CLI，仅 --list / --status 等查询可用；
   构建与部署请在宿主机执行。

配置自动执行通道的方法见《用户操作手册》4.7 节"长期方案 Phase 2"。
```

### 通道 C：用户直接给出完整命令（过渡用法）

用户消息中若**明确给出了完整命令**（如"请帮我跑这条命令并把输出原样回贴：
docker exec ..."），按用户给出的命令执行并原样回贴输出。此为 Phase 2 落地前的
推荐过渡用法。

## 五、错误处理

| 场景 | 处理 |
|------|------|
| 命令不在白名单（如 `/deploy --foo`） | 回贴处理器输出的错误信息，附 `/deploy --help` 提示 |
| 服务不存在 | 原样回贴处理器输出（含 service.yaml 模板提示） |
| SSH 通道超时/失败 | 回贴错误，并给出通道 B 的手动执行指引 |
| 输出过长（>200 行） | 回贴前 100 行 + 末尾 50 行，中间标注省略 |

## 六、验收标准

- 飞书发 `/deploy --list` → 机器人回贴可部署服务列表（或通道未配置的标准指引），不出现 `openclaw deploy` 猜测。
- `/deploy <服务名>` 等变更类命令 → 先确认后执行，输出原样回贴。
- 非 `/deploy` 开头的消息不受本技能影响。
