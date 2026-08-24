# ============================================================
# DevPilot Makefile
# 常用操作快捷命令
# 用法: make <target>
# ============================================================

.DEFAULT_GOAL := help

# ---- 变量 ----
COMPOSE := docker compose
DC_ENV  := --env-file .env

# ---- 颜色 ----
BLUE   := \033[34m
GREEN  := \033[32m
YELLOW := \033[33m
RED    := \033[31m
RESET  := \033[0m

##@ 通用

.PHONY: help
help: ## 显示所有可用命令
	@printf "$(BLUE)DevPilot 常用命令$(RESET)\n\n"
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\n"} \
	  /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: init
init: ## 交互式配置向导（生成 .env）
	@bash ./init.sh

##@ 启动与停止

.PHONY: up
up: ## 构建并启动所有服务（后台）
	$(COMPOSE) up -d --build
	@printf "$(GREEN)启动完成，运行 make ps 查看状态$(RESET)\n"

.PHONY: up-bot
up-bot: ## 仅启动飞书机器人（Redis + OpenClaw）
	$(COMPOSE) --profile bot up -d --build
	@printf "$(GREEN)飞书机器人已启动$(RESET)\n"

.PHONY: up-dev
up-dev: ## 仅启动开发环境（CC-Switch + Claude Code）
	$(COMPOSE) --profile dev up -d --build
	@printf "$(GREEN)开发环境已启动$(RESET)\n"

.PHONY: down
down: ## 停止所有服务（保留数据）
	$(COMPOSE) down

.PHONY: restart
restart: ## 重启所有服务
	$(COMPOSE) restart

.PHONY: restart-openclaw
restart-openclaw: ## 仅重启 OpenClaw
	$(COMPOSE) restart openclaw

.PHONY: restart-claude
restart-claude: ## 仅重启 Claude Code
	$(COMPOSE) restart devpilot-claude

.PHONY: restart-redis
restart-redis: ## 仅重启 Redis
	$(COMPOSE) restart redis

##@ 日志

.PHONY: logs
logs: ## 查看所有服务日志（实时）
	$(COMPOSE) logs -f

.PHONY: logs-openclaw
logs-openclaw: ## 查看 OpenClaw 日志
	$(COMPOSE) logs -f openclaw

.PHONY: logs-claude
logs-claude: ## 查看 Claude Code 日志
	$(COMPOSE) logs -f devpilot-claude

.PHONY: logs-redis
logs-redis: ## 查看 Redis 日志
	$(COMPOSE) logs -f redis

##@ 状态与健康检查

.PHONY: ps
ps: ## 查看容器状态
	$(COMPOSE) ps

.PHONY: health
health: ## 健康检查所有服务
	@printf "$(BLUE)=== 健康检查 ===$(RESET)\n"
	@printf "Redis:     "
	@$(COMPOSE) exec -T redis redis-cli -a "$$(grep REDIS_PASSWORD .env | cut -d= -f2)" ping 2>/dev/null && printf "$(GREEN)OK$(RESET)\n" || printf "$(RED)FAIL$(RESET)\n"
	@printf "OpenClaw:  "
	@curl -sf http://localhost:$$(grep OPENCLAW_GATEWAY_PORT .env | cut -d= -f2)/healthz >/dev/null 2>&1 && printf "$(GREEN)OK$(RESET)\n" || printf "$(RED)FAIL$(RESET)\n"
	@printf "CC-Switch: "
	@curl -s http://localhost:$$(grep CC_SWITCH_WEB_PORT .env | cut -d= -f2) >/dev/null 2>&1 && printf "$(GREEN)OK$(RESET)\n" || printf "$(RED)FAIL$(RESET)\n"
	@printf "Claude:    "
	@$(COMPOSE) exec -T devpilot-claude claude --version 2>/dev/null && printf "$(GREEN)OK$(RESET)\n" || printf "$(RED)FAIL$(RESET)\n"

##@ 容器交互

.PHONY: shell
shell: ## 进入 CC-Switch+Claude 容器 bash
	$(COMPOSE) exec devpilot-claude bash

.PHONY: claude
claude: ## 启动 Claude Code 交互式会话
	$(COMPOSE) exec devpilot-claude claude

.PHONY: redis-cli
redis-cli: ## 进入 Redis CLI
	$(COMPOSE) exec redis redis-cli -a "$$(grep REDIS_PASSWORD .env | cut -d= -f2)"

.PHONY: openclaw-shell
openclaw-shell: ## 进入 OpenClaw 容器 bash
	$(COMPOSE) exec openclaw bash

##@ 构建与更新

.PHONY: build
build: ## 构建所有镜像（不启动）
	$(COMPOSE) build

.PHONY: rebuild
rebuild: ## 强制重新构建镜像（--no-cache）
	$(COMPOSE) build --no-cache
	@printf "$(GREEN)镜像已重新构建，运行 make up 启动$(RESET)\n"

.PHONY: update
update: ## 修改版本号后重新构建并启动
	$(COMPOSE) up -d --build
	@printf "$(GREEN)更新完成$(RESET)\n"

##@ 数据管理

.PHONY: backup
backup: ## 备份 Redis 数据和 OpenClaw 配置
	@printf "$(BLUE)备份数据...$(RESET)\n"
	@$(COMPOSE) exec -T redis redis-cli -a "$$(grep REDIS_PASSWORD .env | cut -d= -f2)" BGSAVE >/dev/null 2>&1
	@mkdir -p backups
	@cp -r data/redis/dump.rdb "backups/dump-$$(date +%Y%m%d%H%M%S).rdb" 2>/dev/null || printf "$(YELLOW)Redis RDB 文件不存在，跳过$(RESET)\n"
	@cp data/openclaw/.openclaw/openclaw.json "backups/openclaw-$$(date +%Y%m%d%H%M%S).json" 2>/dev/null || printf "$(YELLOW)OpenClaw 配置不存在，跳过$(RESET)\n"
	@printf "$(GREEN)备份完成，文件在 backups/ 目录$(RESET)\n"

.PHONY: clean
clean: ## 停止并删除所有容器、数据、日志（危险！）
	@printf "$(RED)警告：将删除所有数据和日志！$(RESET)\n"
	@printf "确认？(y/N) " && read confirm && [ "$$confirm" = "y" ] || exit 1
	$(COMPOSE) down -v
	rm -rf data/* logs/*
	@printf "$(GREEN)已清理$(RESET)\n"

.PHONY: clean-images
clean-images: ## 清理未使用的 Docker 镜像
	docker image prune -f
	@printf "$(GREEN)清理完成$(RESET)\n"

##@ 配置

.PHONY: config
config: ## 查看当前 docker compose 配置
	$(COMPOSE) config

.PHONY: env
env: ## 查看当前环境变量
	@cat .env

.PHONY: reset-openclaw
reset-openclaw: ## 重置 OpenClaw 配置（重新生成）
	rm -f data/openclaw/.openclaw/openclaw.json
	$(COMPOSE) restart openclaw
	@printf "$(GREEN)OpenClaw 配置已重置$(RESET)\n"

##@ 技能管理

.PHONY: setup-skills
setup-skills: ## 安装技能文件到 ~/.openclaw/skills/
	@bash ./setup-skills.sh

##@ 服务管理（service.sh）

.PHONY: start
start: ## 一键启动服务（默认 full 模式，可选: make start bot）
	@bash ./service.sh start $(filter-out $@,$(MAKECMDGOALS))

.PHONY: stop
stop: ## 停止所有服务（保留数据）
	@bash ./service.sh stop

.PHONY: svc-status
svc-status: ## 查看容器状态和资源使用
	@bash ./service.sh status

.PHONY: svc
svc: ## 服务管理帮助
	@bash ./service.sh help

# 防止 make 将 profile 参数当作 target
%:
	@:
