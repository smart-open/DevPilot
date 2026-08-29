---
name: deploy
description: "DevPilot 服务部署命令路由：处理 /deploy 命令（--list / --status / --logs / 服务名 / --restart / --cleanup），参数原样透传给部署处理器并把输出原样回贴。"
---

# /deploy 部署命令路由

用户发 `/deploy ...` 时按本技能路由：把参数**原样**交给部署处理器执行，输出**原样**回贴。

## 硬性规则

1. 消息以 `/deploy` 开头（或明确要求部署某服务）即按本技能处理；其余消息不适用。
2. **参数原样透传**：禁止改写、补全、翻译或猜测"用户可能想要的命令"。
3. **禁止**调用 `openclaw deploy`（不存在的子命令，OpenClaw CLI 只有 gateway / channels / plugins / config / doctor / security）。
4. **输出原样回贴**：命令的 stdout/stderr 即回复内容，不摘要、不改写（末尾可附一行简短说明）。
5. 变更类命令执行前必须先复述命令与影响面，得到用户确认后才执行。

## 命令白名单

| 命令 | 功能 | 变更类 |
|------|------|--------|
| `/deploy --list` | 列出所有可部署服务 | 否 |
| `/deploy --status <服务名>` | 查看服务运行状态 | 否 |
| `/deploy --logs <服务名>` | 查看服务最近 50 行日志 | 否 |
| `/deploy <服务名> [--tag <标签>]` | 构建并部署指定服务 | 是 |
| `/deploy --restart <服务名>` | 重启服务 | 是 |
| `/deploy --cleanup <服务名>` | 停止并清理服务（删容器/镜像） | 是 |
| `/deploy --help` | 显示帮助 | 否 |

## 执行通道

### 唯一通道：本容器 exec 调用部署处理器

用 exec 工具执行（`<完整命令>` 为用户 `/deploy` 之后的原始参数，含 `/deploy` 前缀整体传入）：

```bash
bash /opt/devpilot/cicd/service-deploy/feishu-deploy-handler.sh "<完整命令>"
```

处理器内部自动判定执行位置，**无需也不允许**自行选择通道或直接执行 ssh：

- **宿主机 SSH 受控通道已配置**（`DEPLOY_SSH_HOST` 已设置且 `data/deploy-keys/` 有密钥）：处理器检测到本容器无 docker CLI 时，自动把命令经 SSH 转发宿主机执行（输出带 `[ssh]` 转发标记），构建/部署/清理/日志/状态全部返回**真实结果**，原样回贴。
- **未配置 SSH 通道**：处理器本地执行——查询类（`--list` / `--help`）返回真实结果；构建/部署/清理类被脚本前置检查拦截并提示"请在宿主机执行"，**原样回贴该提示**，不要尝试绕过。

通用规则：
- 输出超过 200 行时：回贴前 100 行 + 末尾 50 行，中间标注"……（省略 N 行）"。
- 超时建议 120s（SSH 转发的构建命令耗时较长）。
- 通道配置方法见《用户操作手册》4.7.3 Phase 2（`scripts/setup-deploy-ssh.sh` 一键配置），用户询问"如何让 /deploy 直接部署"时指引该脚本。

## 错误处理

| 场景 | 处理 |
|------|------|
| 命令不在白名单（如 `/deploy --foo`） | 回贴处理器输出，附 `/deploy --help` 提示 |
| 服务不存在 | 原样回贴处理器输出（含 service.yaml 模板提示） |
| 通道执行失败 | 回贴错误 + 宿主机手动执行指引：`bash cicd/service-deploy/feishu-deploy-handler.sh "/deploy --list"` |
| `/opt/devpilot/cicd/...` 路径不存在 | 说明部署脚本未挂载进容器，回贴宿主机手动执行指引 |

## 区分

`g5-deploy` 技能是研发流程 G5「提交部署」阶段（DevOps 角色，面向代码交付闭环）；本技能只做飞书 `/deploy` 命令路由，两者互补。
