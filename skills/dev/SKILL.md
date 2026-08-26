---
name: dev
description: "开发执行（全栈工程师角色）：按已审查的实施计划全自动编码实现，完成后自动进入代码审查阶段。"
---

# 技能：开发执行（Dev）

<!--
  ============================================================
  技能名称：开发执行
  技能角色：全栈开发工程师
  触发条件：计划审查（G3 门控）通过后自动触发
  输入：开发计划（PLAN.md）+ PRD 文档
  输出：完整项目代码 + 进度通知
  门控：无（本阶段全自动，完成后进入 Review 阶段）
  ============================================================
-->

## 一、技能概述

开发执行阶段按照开发计划逐个任务执行编码。AI 全自动完成所有开发工作，用户无需干预。每完成一个任务提交一次代码，并输出进度通知。

**核心原则：**
- 按计划执行：严格按照 PLAN.md 中的任务顺序执行
- 持续提交：每完成一个任务立即 git commit
- 代码规范：遵循项目技术栈的最佳实践
- 遇阻通知：遇到无法自行解决的问题时主动通知用户

## 二、执行步骤

### 步骤 1：初始化项目

根据技术选型初始化项目脚手架。

#### Node.js 项目（React / Vue / Express / NestJS）

```bash
# React + Vite
npm create vite@latest [项目名] -- --template react-ts
cd [项目名] && npm install

# Vue + Vite
npm create vite@latest [项目名] -- --template vue-ts
cd [项目名] && npm install

# Express API
mkdir [项目名] && cd [项目名]
npm init -y
npm install express cors helmet morgan dotenv

# NestJS API
npx @nestjs/cli new [项目名]
```

#### Python 项目（FastAPI / Django / 脚本）

```bash
# FastAPI
mkdir [项目名] && cd [项目名]
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install fastapi uvicorn sqlalchemy pydantic
pip freeze > requirements.txt

# Python 脚本
mkdir [项目名] && cd [项目名]
python -m venv venv
source venv/bin/activate
pip install requests pandas openpyxl
pip freeze > requirements.txt
```

#### Go 项目（Gin / 原生）

```bash
mkdir [项目名] && cd [项目名]
go mod init github.com/[user]/[项目名]
go get github.com/gin-gonic/gin
```

#### Java 项目（Spring Boot）

```bash
# 使用 Spring Initializr
curl https://start.spring.io/starter.zip \
  -d type=maven-project \
  -d language=java \
  -d dependencies=web,jpa,postgresql \
  -o [项目名].zip
unzip [项目名].zip -d [项目名]
```

#### Rust 项目（Axum / Actix）

```bash
# Rust Web 服务
cargo new <项目名>
cd <项目名>
cargo add axum tokio tower tower-http serde serde_json
cargo add sqlx --features postgres
cargo add tracing tracing-subscriber
```

#### .NET 项目（ASP.NET Core）

```bash
# ASP.NET Core Web API
dotnet new webapi -n <项目名>
cd <项目名>
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL
dotnet add package StackExchange.Redis
dotnet add package Serilog.AspNetCore
```

#### PHP 项目（Laravel）

```bash
# Laravel API
composer create-project laravel/laravel <项目名>
cd <项目名>
composer require laravel/sanctum
php artisan install:api
```

### 步骤 2：建立目录结构

按技术栈最佳实践建立标准目录结构：

**前端项目（React/Vue）：**
```
src/
  components/       # 通用组件
  pages/            # 页面组件
  hooks/            # 自定义 Hooks
  utils/            # 工具函数
  services/         # API 调用
  styles/           # 全局样式
  types/            # TypeScript 类型定义
  App.tsx           # 根组件
  main.tsx          # 入口文件
```

**后端项目（Node.js/Python）：**
```
src/
  controllers/      # 控制器（处理请求/响应）
  services/         # 业务逻辑
  models/           # 数据模型
  routes/           # 路由定义
  middlewares/      # 中间件
  utils/            # 工具函数
  config/           # 配置
  types/            # 类型定义
  app.ts            # 应用入口
```

**Rust 项目：**
```
src/
  main.rs           # 入口文件
  config/           # 配置模块
  handlers/         # 请求处理器
  models/           # 数据模型
  services/         # 业务逻辑
  middleware/       # 中间件
  utils/            # 工具函数
  errors.rs         # 错误定义
Cargo.toml          # 依赖管理
```

**.NET 项目：**
```
src/
  Controllers/      # 控制器
  Services/         # 业务逻辑
  Models/           # 数据模型
  DTOs/             # 数据传输对象
  Middleware/       # 中间件
  Extensions/       # 扩展方法
  Configuration/    # 配置
  Program.cs        # 入口文件
*.csproj            # 项目文件
```

### 步骤 3：按计划逐个任务执行

每个任务的执行流程：

1. **理解任务**：阅读任务描述，明确要做什么
2. **查看依赖**：确认前置任务已完成
3. **编写代码**：按编码规范实现功能
4. **本地验证**：确保代码能编译/运行
5. **提交代码**：git add + commit

#### 编码规范

**通用规范：**
- 文件命名：kebab-case（如 `user-service.ts`）
- 变量/函数命名：camelCase（如 `getUserById`）
- 类命名：PascalCase（如 `UserController`）
- 常量命名：UPPER_SNAKE_CASE（如 `MAX_RETRY`）
- 缩进：2 空格（前端）/ 4 空格（Python）
- 每个函数不超过 50 行
- 每个文件不超过 300 行
- 添加必要的中文注释，解释「为什么」而非「做什么」

**前端规范：**
- 组件使用函数式组件 + Hooks
- 状态管理优先使用内置 Hooks，复杂场景用 Zustand/Redux
- 样式优先使用 TailwindCSS 或 CSS Modules
- API 调用统一放在 services/ 目录
- 所有用户输入必须做前端校验

**后端规范：**
- API 遵循 RESTful 设计规范
- 所有 API 必须有错误处理和统一响应格式
- 敏感配置通过环境变量读取，不硬编码
- 数据库操作使用 ORM，不直接写 SQL
- 日志记录关键操作和错误信息

**安全编码规范：**
- 所有用户输入必须做服务端校验（不可信任前端校验）
- SQL 查询必须使用参数化查询或 ORM，禁止字符串拼接
- 密码必须使用 bcrypt / argon2 哈希存储，禁止明文或 MD5
- 敏感数据（API Key、密码、Token）通过环境变量读取，禁止硬编码
- 文件上传必须校验文件类型、大小、内容
- HTTP 响应头配置安全头（CSP、X-Frame-Options、X-Content-Type-Options）
- CORS 配置最小化授权，禁止 `*` 通配符用于生产环境

**统一 API 响应格式：**
```json
{
  "code": 0,
  "message": "success",
  "data": {}
}
```

### 步骤 4：每完成一个任务提交代码

```bash
git add -A
git commit -m "feat(模块): 完成xxx功能

- 实现了xxx
- 添加了xxx
- 修复了xxx"
```

**Commit Message 规范：**
- `feat`: 新功能
- `fix`: 修复 Bug
- `style`: 代码格式调整
- `refactor`: 代码重构
- `docs`: 文档更新
- `test`: 测试相关
- `chore`: 构建/工具相关

### 步骤 5：输出进度通知

每完成一个任务，输出进度通知：

```
[进度] 开发进度：[X]/[Y] 任务完成

已完成：
- [任务1描述]
- [任务2描述]

进行中：
- [当前任务]（[模型名]，预计还需 [N] 分钟）

剩余 [M] 个任务，预计 [N] 分钟内完成。
```

### 步骤 6：处理阻塞问题

遇到以下情况时，暂停开发并通知用户：

- 依赖的外部 API 返回异常且无法绕过
- 技术选型存在根本性冲突
- 需求理解有歧义，无法自行判断
- 预估时间超出计划 50% 以上

通知格式：
```
[阻塞] 开发遇到问题

任务：[任务描述]
问题：[问题描述]
已尝试：[已尝试的解决方案]
建议：[建议的处理方式]

请确认如何继续。
```

### 步骤 7：转入代码审查

所有开发任务完成后，自动进入代码审查阶段（review 技能）。代码审查使用 `alibaba/open-code-review`（TRAE-code-review）技能对全部代码变更进行智能审查，覆盖正确性、安全性、性能、可维护性和最佳实践五个维度。审查通过后自动进入测试验证阶段（test 技能），审查不通过则返回本阶段修复问题。

## 三、输出标准

- 代码遵循 PLAN.md 中确定的技术选型和编码规范
- 每次提交有清晰的 commit message（遵循约定式提交规范）
- 项目能成功编译/启动运行
- 关键逻辑有中文注释
- 遇到阻塞问题主动通知用户，不盲目继续
- 所有任务完成后自动进入代码审查阶段（review 技能）

## 四、多技术栈支持

本技能支持以下技术栈的开发：

| 技术栈 | 前端 | 后端 | 数据库 |
|-------|------|------|-------|
| JavaScript/TypeScript | React, Vue, Next.js | Express, NestJS, Fastify | PostgreSQL, MySQL, MongoDB |
| Python | - | FastAPI, Django, Flask | PostgreSQL, MySQL, SQLite |
| Go | - | Gin, Echo, Fiber | PostgreSQL, MySQL, Redis |
| Java | - | Spring Boot | PostgreSQL, MySQL |
| Rust | - | Axum, Actix, Warp | PostgreSQL, MySQL, Redis |
| .NET | Blazor | ASP.NET Core, Minimal APIs | SQL Server, PostgreSQL |
| PHP | - | Laravel, Symfony | MySQL, PostgreSQL |
| 静态网站 | HTML/CSS/JS, TailwindCSS | - | - |

## 五、阶段流转

| 条件 | 流转方向 |
|------|---------|
| 所有任务完成 | 进入代码审查阶段（review 技能） |
| 遇到阻塞问题 | 暂停开发，通知用户处理 |
| 用户中途叫停 | 保存当前进度，等待用户指示 |