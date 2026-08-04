#!/bin/bash
set -e

# ============================================================
# DevPilot 技能文件一键搭建脚本
# 功能：将 skills/ 目录下的技能文件复制到 ~/.openclaw/skills/
# 用法: ./setup-skills.sh
# 依赖：cicd/lib/common.sh（公共函数库）
# ============================================================

# ---- 加载公共函数库（颜色/日志等） ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cicd/lib/common.sh"

SKILLS_DIR="${SCRIPT_DIR}/skills"
TARGET_DIR="${HOME}/.openclaw/skills"

print_header "DevPilot 技能文件搭建"

# ============================================================
# 1. 检查源目录
# ============================================================
info "检查技能文件目录..."
if [ ! -d "${SKILLS_DIR}" ]; then
    error "技能文件目录不存在: ${SKILLS_DIR}"
    exit 1
fi

# 自动发现 skills/ 目录下的所有 *-SKILL.md 文件
REQUIRED_SKILLS=()
for f in "${SKILLS_DIR}"/*-SKILL.md; do
    [ -f "$f" ] && REQUIRED_SKILLS+=("$(basename "$f")")
done

if [ ${#REQUIRED_SKILLS[@]} -eq 0 ]; then
    error "未找到技能文件（*-SKILL.md），请检查 ${SKILLS_DIR} 目录"
    exit 1
fi

MISSING=0
for skill in "${REQUIRED_SKILLS[@]}"; do
    if [ ! -f "${SKILLS_DIR}/${skill}" ]; then
        error "缺少技能文件: ${skill}"
        MISSING=$((MISSING + 1))
    fi
done

if [ ${MISSING} -gt 0 ]; then
    error "有 ${MISSING} 个技能文件缺失，请检查 skills/ 目录"
    exit 1
fi

success "所有 ${#REQUIRED_SKILLS[@]} 个技能文件就绪"

# ============================================================
# 2. 创建目标目录
# ============================================================
info "创建目标目录: ${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"
success "目录已创建"

# ============================================================
# 3. 复制技能文件
# ============================================================
info "复制技能文件..."

for skill in "${REQUIRED_SKILLS[@]}"; do
    cp "${SKILLS_DIR}/${skill}" "${TARGET_DIR}/${skill}"
    success "已复制: ${skill}"
done

# ============================================================
# 4. 验证安装
# ============================================================
echo ""
info "验证安装..."
INSTALLED=0
for skill in "${REQUIRED_SKILLS[@]}"; do
    if [ -f "${TARGET_DIR}/${skill}" ]; then
        INSTALLED=$((INSTALLED + 1))
    fi
done

if [ ${INSTALLED} -eq ${#REQUIRED_SKILLS[@]} ]; then
    success "全部 ${INSTALLED} 个技能文件已安装"
else
    error "仅安装了 ${INSTALLED}/${#REQUIRED_SKILLS[@]} 个技能文件"
    exit 1
fi

# ============================================================
# 5. 打印摘要
# ============================================================
echo ""
print_separator
success "技能文件搭建完成！"
print_separator
echo ""
echo -e "${CYAN}安装位置：${NC} ${TARGET_DIR}"
echo ""
echo -e "${CYAN}已安装技能：${NC}"
echo "  explore-SKILL.md  - 需求探索（产品经理角色）"
echo "  prd-SKILL.md      - 需求分析（系统架构师角色）"
echo "  plan-SKILL.md     - 计划拆解（技术主管角色）"
echo "  dev-SKILL.md      - 开发执行（全栈工程师角色）"
echo "  review-SKILL.md   - 代码审查（质量工程师角色）"
echo "  test-SKILL.md     - 测试验证（QA 工程师角色）"
echo "  deploy-SKILL.md   - 提交部署（DevOps 工程师角色）"
echo ""
echo -e "${CYAN}研发流程：${NC}"
echo "  需求探索(G1) -> 需求分析(G2) -> 计划拆解(G3) -> 开发执行 -> 代码审查 -> 测试验证(G4) -> 提交部署(G5)"
echo ""
echo -e "${YELLOW}提示：${NC}修改 skills/ 目录下的文件后，重新运行此脚本即可更新。"
echo ""
