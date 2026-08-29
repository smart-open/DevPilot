#!/bin/bash
set -e

# ============================================================
# DevPilot 技能文件一键搭建脚本
# 功能：将 skills/<技能名>/SKILL.md 目录结构复制到
#       data/openclaw/.openclaw/skills/（OpenClaw 容器挂载点）
# 格式：OpenClaw 技能规范 = 「目录 + SKILL.md + YAML frontmatter
#       （name/description）」。平铺的 *-SKILL.md 文件 OpenClaw
#       不会发现，本脚本安装前会校验 frontmatter。
# 用法: ./setup-skills.sh
# 依赖：cicd/lib/common.sh（公共函数库）
# ============================================================

# ---- 加载公共函数库（颜色/日志等） ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cicd/lib/common.sh"

SKILLS_DIR="${SCRIPT_DIR}/skills"
# 装到容器 OpenClaw 的挂载点：宿主机 ./data/openclaw/.openclaw/skills 对应容器内
# /data/openclaw/.openclaw/skills。OPENCLAW_HOME=/data/openclaw（见 Dockerfile），
# state-dir 为 ${OPENCLAW_HOME}/.openclaw，其下 skills/ 即 OpenClaw 的
# managed skills root（官方加载优先级第 4 级）。
TARGET_DIR="${SCRIPT_DIR}/data/openclaw/.openclaw/skills"

print_header "DevPilot 技能文件搭建"

# ============================================================
# 1. 发现技能目录（skills/<name>/SKILL.md）并校验 frontmatter
# ============================================================
info "扫描技能目录 ${SKILLS_DIR} ..."
SKILL_NAMES=()
for d in "${SKILLS_DIR}"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    name="$(basename "${d}")"
    # OpenClaw 必填字段校验（缺任一技能不会出现在 Agent 上下文）
    if ! head -10 "${d}SKILL.md" | grep -q '^name:'; then
        error "技能 ${name}/SKILL.md 缺少 frontmatter name 字段（OpenClaw 必需）"
        exit 1
    fi
    if ! head -10 "${d}SKILL.md" | grep -q '^description:'; then
        error "技能 ${name}/SKILL.md 缺少 frontmatter description 字段（OpenClaw 必需）"
        exit 1
    fi
    SKILL_NAMES+=("${name}")
done

if [ ${#SKILL_NAMES[@]} -eq 0 ]; then
    error "未发现任何 <技能名>/SKILL.md 目录结构，请检查 ${SKILLS_DIR}"
    exit 1
fi
success "发现 ${#SKILL_NAMES[@]} 个技能: ${SKILL_NAMES[*]}"

# ============================================================
# 2. 安装（整目录复制，覆盖旧版）
# ============================================================
mkdir -p "${TARGET_DIR}"
info "安装到 ${TARGET_DIR} ..."
for name in "${SKILL_NAMES[@]}"; do
    rm -rf "${TARGET_DIR}/${name}"
    cp -r "${SKILLS_DIR}/${name}" "${TARGET_DIR}/${name}"
    success "已安装: ${name}/SKILL.md"
done

# ============================================================
# 2.1 安装 AGENTS.md（Agent 工作区硬路由规则）
# ============================================================
# OpenClaw 每次会话开始自动加载工作区 AGENTS.md（本部署为
# data/openclaw/.openclaw/workspace/AGENTS.md）。没有它，Agent 上下文里
# 只有技能 name+description 一行摘要，斜杠命令与开发需求会被模型自由发挥。
# 镜像内 init-openclaw.sh 仅在文件缺失时种子旧版模板；本脚本以仓库
# conf/openclaw/AGENTS.md 为准覆盖安装（git pull 后重跑即更新规则）。
AGENTS_SRC="${SCRIPT_DIR}/conf/openclaw/AGENTS.md"
AGENTS_DST="${SCRIPT_DIR}/data/openclaw/.openclaw/workspace/AGENTS.md"
if [ -f "${AGENTS_SRC}" ]; then
    mkdir -p "$(dirname "${AGENTS_DST}")"
    cp "${AGENTS_SRC}" "${AGENTS_DST}"
    success "已安装: AGENTS.md（硬路由规则 → ${AGENTS_DST}）"
else
    warn "conf/openclaw/AGENTS.md 不存在，跳过（Agent 将缺少技能路由硬约束）"
fi

# ============================================================
# 3. 打印摘要
# ============================================================
echo ""
print_separator
success "技能安装完成！共 ${#SKILL_NAMES[@]} 个"
print_separator
echo ""
echo -e "${CYAN}安装位置：${NC} ${TARGET_DIR}"
echo -e "${CYAN}Agent 规则：${NC} ${AGENTS_DST}"
echo ""
echo -e "${CYAN}已安装技能（斜杠命令 = 技能 name，命令名规范化为小写+下划线）：${NC}"
echo "  /explore    - 需求探索（G1，产品经理角色）"
echo "  /prd        - 需求分析（G2，系统架构师角色）"
echo "  /plan       - 计划拆解（G3，技术主管角色）"
echo "  /dev        - 开发执行（全栈工程师角色）"
echo "  /review     - 代码审查（质量工程师角色）"
echo "  /test       - 测试验证（G4，QA 工程师角色）"
echo "  /g5_deploy  - 提交部署（G5，DevOps 工程师角色；技能名 g5-deploy，命令名下划线规范化）"
echo "  /deploy     - 服务部署命令路由（飞书部署命令解释器）"
echo ""
echo -e "${CYAN}研发流程：${NC}"
echo "  需求探索(G1) -> 需求分析(G2) -> 计划拆解(G3) -> 开发执行 -> 代码审查 -> 测试验证(G4) -> 提交部署(G5)"
echo ""
echo -e "${CYAN}飞书部署命令：${NC}"
echo "  /deploy <服务名>|--list|--status|--logs|--restart|--cleanup|--help"
echo ""
echo -e "${YELLOW}重要：${NC}技能 / AGENTS.md 变更后必须重启 openclaw 容器才会重新加载："
echo "  docker compose restart openclaw"
echo "  验证技能已加载：docker exec devpilot-openclaw openclaw skills list"
echo "  验证规则已就位：ls data/openclaw/.openclaw/workspace/AGENTS.md"
echo ""
