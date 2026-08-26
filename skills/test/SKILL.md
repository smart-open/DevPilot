---
name: test
description: "测试验证（G4，QA 工程师角色）：对项目做功能与验收测试，输出 HITL 部署验收卡片，通过后进入提交部署。"
---

# 技能：测试验证（Test）

<!--
  ============================================================
  技能名称：测试验证
  技能角色：测试工程师 / QA
  触发条件：代码审查（Review）通过后自动触发
  输入：审查通过的项目代码 + PRD 验收标准 + 代码审查报告
  输出：测试报告 + HITL G4 门控卡片
  门控：G4 - 部署验收（用户审核通过后进入 Deploy 阶段）
  ============================================================
-->

## 一、技能概述

测试验证阶段对开发完成的项目进行全面测试，确保代码质量和功能完整性。测试覆盖编译运行、单元测试、功能测试、集成测试、性能测试、安全测试六个层级，逐层递进，任何一层失败都会阻断后续测试。

**核心原则：**
- 分层测试：编译 -> 单元 -> 功能 -> 集成 -> 性能 -> 安全，逐层递进
- 快速失败：发现问题立即报告，不继续后续测试
- 覆盖率优先：核心逻辑测试覆盖率不低于 80%
- 可复现：测试用例可独立重复运行

## 二、测试层级

```
编译运行 -> 单元测试 -> 功能测试 -> 集成测试 -> 性能测试 -> 安全测试 -> 测试报告
   |          |          |          |          |          |
   v          v          v          v          v          v
 失败则     失败则     失败则     失败则     失败则     失败则
  停止       停止       停止       停止       停止       停止
```

### 第一层：编译运行（Build & Run）

**目标：** 确保项目能成功编译和启动运行。

#### Node.js 项目

```bash
# TypeScript 编译检查
npx tsc --noEmit

# 构建
npm run build

# 启动开发服务器验证（后台运行 5 秒后检查）
timeout 5 npm run dev || true
curl -sf http://localhost:5173 > /dev/null && echo "前端服务正常" || echo "前端服务异常"
```

#### Python 项目

```bash
# 语法检查
python -m py_compile src/*.py

# 依赖检查
pip install -r requirements.txt

# 启动服务验证
timeout 5 uvicorn src.app:app --host 0.0.0.0 --port 8000 || true
curl -sf http://localhost:8000/docs > /dev/null && echo "API 服务正常" || echo "API 服务异常"
```

#### Go 项目

```bash
# 编译
go build -o bin/app ./...

# 启动验证
timeout 5 ./bin/app || true
```

#### Java 项目

```bash
# Maven 编译
./mvnw clean compile

# 打包
./mvnw package -DskipTests

# 启动验证
timeout 10 java -jar target/*.jar || true
```

#### 静态网站项目

```bash
# 检查 HTML 语法
npx htmlhint src/*.html || true

# 检查 CSS 语法
npx stylelint src/*.css || true

# 本地预览验证
npx serve dist -l 3000 &
sleep 2
curl -sf http://localhost:3000 > /dev/null && echo "静态站点正常" || echo "静态站点异常"
kill %1 2>/dev/null || true
```

**通过标准：** 编译无错误，服务能启动，基础 HTTP 请求有响应。

---

### 第二层：单元测试（Unit Test）

**目标：** 验证单个函数/模块/组件的逻辑正确性。

#### Node.js 项目（使用 Vitest / Jest）

```bash
# 安装测试框架
npm install -D vitest @testing-library/react @testing-library/jest-dom

# 编写测试（示例：src/utils/__tests__/format.test.ts）
```

测试文件示例：
```typescript
// src/utils/__tests__/format.test.ts
import { describe, it, expect } from 'vitest'
import { formatDate, formatCurrency } from '../format'

describe('formatDate', () => {
  it('应正确格式化日期', () => {
    expect(formatDate('2024-01-15')).toBe('2024年1月15日')
  })
  it('应处理无效输入', () => {
    expect(formatDate('')).toBe('')
  })
})

describe('formatCurrency', () => {
  it('应正确格式化金额', () => {
    expect(formatCurrency(9999)).toBe('9,999.00')
  })
})
```

```bash
# 运行测试
npx vitest run --coverage
```

#### Python 项目（使用 pytest）

```bash
# 安装
pip install pytest pytest-cov

# 编写测试（示例：tests/test_utils.py）
```

测试文件示例：
```python
# tests/test_utils.py
import pytest
from src.utils import format_date, calculate_total

class TestFormatDate:
    def test_normal_date(self):
        assert format_date('2024-01-15') == '2024年1月15日'

    def test_empty_input(self):
        assert format_date('') == ''

class TestCalculateTotal:
    def test_normal_calc(self):
        assert calculate_total([100, 200, 300]) == 600

    def test_empty_list(self):
        assert calculate_total([]) == 0
```

```bash
# 运行测试
pytest tests/ --cov=src --cov-report=term-missing
```

#### Go 项目（内置 testing）

```go
// utils/format_test.go
package utils

import "testing"

func TestFormatDate(t *testing.T) {
    got := FormatDate("2024-01-15")
    want := "2024年1月15日"
    if got != want {
        t.Errorf("FormatDate() = %v, want %v", got, want)
    }
}
```

```bash
go test ./... -cover -v
```

#### Java 项目（使用 JUnit 5）

```bash
# 运行测试
./mvnw test
```

#### Rust 项目（内置 testing）

```rust
// src/utils/format.rs
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_date() {
        assert_eq!(format_date("2024-01-15"), "2024年1月15日");
    }

    #[test]
    fn test_format_date_empty() {
        assert_eq!(format_date(""), "");
    }
}
```

```bash
# 运行测试并生成覆盖率报告
cargo test
cargo install cargo-tarpaulin
cargo tarpaulin --out Html
```

#### .NET 项目（使用 xUnit）

```csharp
// tests/UtilsTests/FormatTests.cs
using Xunit;

public class FormatTests
{
    [Fact]
    public void TestFormatDate()
    {
        Assert.Equal("2024年1月15日", FormatUtil.FormatDate("2024-01-15"));
    }

    [Theory]
    [InlineData("")]
    public void TestFormatDate_EmptyInput_ReturnsEmpty(string input)
    {
        Assert.Equal("", FormatUtil.FormatDate(input));
    }
}
```

```bash
# 运行测试并收集覆盖率
dotnet test --collect:"XPlat Code Coverage"
# 生成 HTML 覆盖率报告
dotnet tool install -g dotnet-reportgenerator-globaltool
reportgenerator -reports:"**/coverage.cobertura.xml" -targetdir:"coverage-report"
```

#### PHP 项目（使用 PHPUnit）

```bash
# 安装
composer require --dev phpunit/phpunit

# 编写测试
```

```php
// tests/FormatTest.php
use PHPUnit\Framework\TestCase;

class FormatTest extends TestCase
{
    public function testFormatDate()
    {
        $this->assertEquals('2024年1月15日', formatDate('2024-01-15'));
    }

    public function testFormatDateEmpty()
    {
        $this->assertEquals('', formatDate(''));
    }
}
```

```bash
# 运行测试
./vendor/bin/phpunit --coverage-html coverage
```

**通过标准：**
- 所有测试用例通过
- 核心逻辑测试覆盖率不低于 80%
- 无 skip 的测试用例（除非有明确原因）

---

### 第三层：功能测试（Functional Test）

**目标：** 验证功能的端到端行为是否符合需求。

#### Web 前端功能测试（使用 Playwright）

```bash
# 安装 Playwright
npm install -D @playwright/test
npx playwright install --with-deps chromium
```

测试文件示例：
```typescript
// tests/e2e/homepage.spec.ts
import { test, expect } from '@playwright/test'

test.describe('首页功能', () => {
  test('页面正常加载', async ({ page }) => {
    await page.goto('http://localhost:5173')
    await expect(page).toHaveTitle(/.+/)
  })

  test('导航栏正常显示', async ({ page }) => {
    await page.goto('http://localhost:5173')
    await expect(page.locator('nav')).toBeVisible()
  })

  test('点击导航跳转正确', async ({ page }) => {
    await page.goto('http://localhost:5173')
    await page.click('text=关于我们')
    await expect(page).toHaveURL(/about/)
  })

  test('联系表单提交', async ({ page }) => {
    await page.goto('http://localhost:5173/contact')
    await page.fill('[name=name]', '测试用户')
    await page.fill('[name=email]', 'test@example.com')
    await page.fill('[name=message]', '测试消息')
    await page.click('button[type=submit]')
    await expect(page.locator('.success-message')).toBeVisible()
  })
})
```

```bash
# 运行功能测试
npx playwright test --reporter=html
```

#### API 功能测试（使用 curl / httpie / Newman）

```bash
# tests/functional/api_test.sh

API_BASE="http://localhost:8000/api"

echo "=== API 功能测试 ==="

# 测试：获取列表
echo -n "GET /items ... "
RESP=$(curl -sf "${API_BASE}/items?page=1&size=10")
if echo "$RESP" | grep -q '"code":0'; then
  echo "PASS"
else
  echo "FAIL: $RESP"
  exit 1
fi

# 测试：创建资源
echo -n "POST /items ... "
RESP=$(curl -sf -X POST "${API_BASE}/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"测试项目","description":"测试描述"}')
if echo "$RESP" | grep -q '"code":0'; then
  ITEM_ID=$(echo "$RESP" | grep -o '"id":[0-9]*' | cut -d: -f2)
  echo "PASS (id=$ITEM_ID)"
else
  echo "FAIL: $RESP"
  exit 1
fi

# 测试：获取详情
echo -n "GET /items/$ITEM_ID ... "
RESP=$(curl -sf "${API_BASE}/items/${ITEM_ID}")
if echo "$RESP" | grep -q '"name":"测试项目"'; then
  echo "PASS"
else
  echo "FAIL: $RESP"
  exit 1
fi

# 测试：更新资源
echo -n "PUT /items/$ITEM_ID ... "
RESP=$(curl -sf -X PUT "${API_BASE}/items/${ITEM_ID}" \
  -H "Content-Type: application/json" \
  -d '{"name":"更新后的项目"}')
if echo "$RESP" | grep -q '"name":"更新后的项目"'; then
  echo "PASS"
else
  echo "FAIL: $RESP"
  exit 1
fi

# 测试：删除资源
echo -n "DELETE /items/$ITEM_ID ... "
RESP=$(curl -sf -X DELETE "${API_BASE}/items/${ITEM_ID}")
if echo "$RESP" | grep -q '"code":0'; then
  echo "PASS"
else
  echo "FAIL: $RESP"
  exit 1
fi

echo "=== 全部通过 ==="
```

#### 代码规范检查（Lint）

```bash
# Node.js
npx eslint src/ --ext .ts,.tsx
npx prettier --check src/

# Python
flake8 src/ --max-line-length=120
black --check src/
isort --check-only src/

# Go
gofmt -l .
golangci-lint run

# Java
./mvnw checkstyle:check
```

**通过标准：**
- 所有功能测试用例通过
- 代码规范检查无 error 级别问题
- 页面/接口行为符合 PRD 验收标准

---

### 第四层：集成测试（Integration Test）

**目标：** 验证多个模块/服务之间的协作是否正常。

#### 前后端集成测试

```bash
# 1. 启动后端服务
cd backend && npm run start:dev &
BACKEND_PID=$!
sleep 3

# 2. 启动前端服务
cd frontend && npm run dev &
FRONTEND_PID=$!
sleep 3

# 3. 运行集成测试（Playwright 连接真实前后端）
npx playwright test tests/integration/

# 4. 清理
kill $BACKEND_PID $FRONTEND_PID 2>/dev/null || true
```

集成测试示例：
```typescript
// tests/integration/full-flow.spec.ts
import { test, expect } from '@playwright/test'

test.describe('完整业务流程', () => {
  test('用户注册到下单完整流程', async ({ page }) => {
    // 1. 访问首页
    await page.goto('http://localhost:5173')
    await expect(page.locator('h1')).toBeVisible()

    // 2. 注册账号
    await page.click('text=注册')
    await page.fill('[name=username]', 'testuser')
    await page.fill('[name=password]', 'Test1234!')
    await page.click('button:has-text("注册")')
    await expect(page.locator('.welcome')).toBeVisible()

    // 3. 浏览商品
    await page.click('text=商品列表')
    await expect(page.locator('.product-card')).toHaveCount(6)

    // 4. 加入购物车
    await page.click('.product-card:first-child .add-to-cart')
    await expect(page.locator('.cart-count')).toHaveText('1')

    // 5. 下单
    await page.click('text=购物车')
    await page.click('button:has-text("结算")')
    await expect(page.locator('.order-success')).toBeVisible()
  })
})
```

#### 数据库集成测试

```bash
# 使用 Testcontainers 启动临时数据库进行测试
# Python 示例
pip install testcontainers pytest

# tests/integration/test_db.py
```

```python
# tests/integration/test_db.py
import pytest
from testcontainers.postgres import PostgresContainer
from src.db import get_session, init_db

@pytest.fixture(scope="module")
def postgres():
    with PostgresContainer("postgres:16-alpine") as pg:
        yield pg

def test_database_crud(postgres):
    # 使用真实数据库测试 CRUD
    init_db(postgres.get_connection_url())
    session = get_session()

    # 创建
    item = Item(name="集成测试", description="数据库集成测试")
    session.add(item)
    session.commit()

    # 查询
    found = session.query(Item).filter_by(name="集成测试").first()
    assert found is not None
    assert found.description == "数据库集成测试"
```

#### Docker 容器化集成测试

```bash
# 构建并启动完整服务栈
docker compose -f docker-compose.test.yml up -d --build
sleep 10

# 运行集成测试
npx playwright test tests/integration/ --config=playwright.docker.config.ts

# 清理
docker compose -f docker-compose.test.yml down -v
```

**通过标准：**
- 所有集成测试通过
- 前后端数据流通畅
- 数据库操作正确
- 容器化环境运行正常

---

### 第五层：性能测试（Performance Test）

**目标：** 验证系统在预期负载下的响应时间和吞吐量。

#### 负载测试（使用 k6 / Apache Bench / wrk）

```bash
# 使用 Apache Bench 进行简单负载测试
ab -n 1000 -c 100 http://localhost:8080/api/items

# 使用 k6 进行复杂负载测试
```

k6 脚本示例：
```javascript
// tests/performance/load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  stages: [
    { duration: '30s', target: 20 },   // 30 秒内逐步增加到 20 个并发
    { duration: '1m', target: 20 },     // 维持 20 个并发 1 分钟
    { duration: '30s', target: 0 },     // 30 秒内逐步降到 0
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],  // 95% 的请求响应时间 < 500ms
    http_req_failed: ['rate<0.01'],     // 错误率 < 1%
  },
};

export default function () {
  let res = http.get('http://localhost:8080/api/items');
  check(res, {
    'status is 200': (r) => r.status === 200,
  });
  sleep(1);
}
```

```bash
# 运行 k6 性能测试
k6 run tests/performance/load-test.js
```

#### 压力测试（逐步加压直到系统崩溃）

```bash
# 使用 wrk 进行压力测试
wrk -t12 -c400 -d30s http://localhost:8080/api/items

# 输出示例：
# 12 threads and 400 connections
#   Thread Stats   Avg      Stdev     Max   +/- Stdev
#     Latency     50.23ms   15.32ms 200.45ms  68.50%
#     Req/Sec     0.65k     0.12k    1.20k    70.83%
#   234567 requests in 30.00s
# Requests/sec:   7818.90
```

**通过标准：**
- P95 响应时间 < 500ms（或按 PRD 要求）
- 错误率 < 1%
- 系统吞吐量满足 PRD 要求
- 无内存泄漏（持续负载下内存稳定）

---

### 第六层：安全测试（Security Test）

**目标：** 发现潜在安全漏洞，确保系统满足安全合规要求。

#### 静态代码分析（SAST）

```bash
# Node.js - ESLint Security 插件
npm install -D eslint-plugin-security
npx eslint src/ --ext .ts,.tsx --plugin security

# Python - Bandit
pip install bandit
bandit -r src/ -f json -o security-report.json

# Go - Gosec
go install github.com/securego/gosec/cmd/gosec@latest
gosec ./...

# Java - SpotBugs + Find Sec Bugs
./mvnw com.github.spotbugs:spotbugs-maven-plugin:check

# 通用 - Semgrep（多语言支持）
pip install semgrep
semgrep --config=p/default src/
```

#### 依赖漏洞扫描

```bash
# Node.js - npm audit
npm audit --audit-level=high

# Python - pip-audit / safety
pip install pip-audit
pip-audit -r requirements.txt

# Go - govulncheck
go install golang.org/x/vuln/cmd/govulncheck@latest
govulncheck ./...

# Java - OWASP Dependency Check
./mvnw org.owasp:dependency-check-maven:check

# 通用 - Trivy（扫描镜像和文件系统）
trivy fs .
trivy image <项目名>:latest
```

#### 动态安全测试（DAST）

```bash
# 使用 OWASP ZAP 进行动态扫描
docker run -t owasp/zap2docker-stable zap-baseline.py \
  -t http://localhost:8080

# 全面扫描（包括爬虫和主动扫描）
docker run -t owasp/zap2docker-stable zap-full-scan.py \
  -t http://localhost:8080 \
  -J zap-report.json
```

#### 敏感信息泄露检查

```bash
# 检查代码中是否有硬编码的密钥、密码、Token
# 使用 TruffleHog
docker run -v $(pwd):/repo trufflesecurity/trufflehog filesystem /repo

# 使用 GitLeaks
gitleaks detect --source . --report-path leaks-report.json
```

**通过标准：**
- SAST 扫描无 Critical / High 级别漏洞
- 依赖扫描无已知高危漏洞
- DAST 扫描无 High 级别告警
- 无硬编码的敏感信息

---

## 三、测试报告

所有测试完成后，生成测试报告：

```markdown
# 测试报告

## 项目信息
- 项目名称：[名称]
- 测试时间：[YYYY-MM-DD HH:MM]
- 测试环境：[Node.js x.x / Python x.x / Go x.x]

## 测试结果汇总

| 测试层级 | 用例数 | 通过 | 失败 | 跳过 | 耗时 |
|---------|-------|------|------|------|------|
| 编译运行 | - | PASS | - | - | 5s |
| 单元测试 | 24 | 24 | 0 | 0 | 8s |
| 功能测试 | 12 | 12 | 0 | 0 | 15s |
| 集成测试 | 6 | 6 | 0 | 0 | 22s |
| 性能测试 | - | PASS | - | - | 15s |
| 安全测试 | - | PASS | - | - | 30s |
| **合计** | **42** | **42** | **0** | **0** | **95s** |

## 代码覆盖率
| 模块 | 行覆盖率 | 分支覆盖率 |
|------|---------|-----------|
| src/utils/ | 95% | 88% |
| src/services/ | 82% | 75% |
| src/controllers/ | 78% | 70% |
| **平均** | **85%** | **78%** |

## 代码规范检查
- ESLint: 0 errors, 2 warnings
- Prettier: 全部通过
- 类型检查: 0 errors

## 失败项详情（如有）
[列出失败的测试用例及修复建议]

## 结论
[全部通过 / 部分失败 - 需修复后重新测试]
```

## 四、HITL G4 门控卡片

```
[G4] 部署验收 - [项目名称]

开发已完成，测试全部通过！

测试报告：
- 编译运行：通过
- 单元测试：24/24 通过（覆盖率 85%）
- 功能测试：12/12 通过
- 集成测试：6/6 通过
- 性能测试：P95 < 500ms，吞吐量 7800 req/s
- 安全测试：0 高危漏洞
- 代码规范：0 errors

预览地址：[预览URL]
（预览地址将在 24 小时后失效）

[确认部署] [需要修改]
```

## 五、输出标准

- 六层测试全部通过后方可发送 G4 门控
- 测试报告包含覆盖率数据
- 失败项必须给出修复建议
- 测试报告保存为 `workspace/[项目名]/docs/TEST_REPORT.md`
- G4 门控卡片包含预览地址和测试摘要

## 六、门控流转

| 用户操作 | 流转方向 |
|---------|---------|
| 点击「确认部署」 | 进入提交部署阶段（g5-deploy 技能） |
| 点击「需要修改」 | 返回 Dev 阶段修复问题，修复后经 Review 审查再重新测试 |
| 超时未响应（48h） | 发送提醒，72h 未响应则暂停任务 |