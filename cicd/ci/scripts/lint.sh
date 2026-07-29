#!/bin/bash
# ============================================================
# DevPilot - 共享 CI Lint 检查脚本
# 功能：CI 流水线统一调用此脚本对项目进行代码质量与安全校验
#
# 检查项：
#   1. 所有 shell 脚本通过 bash -n 语法检查
#   2. 所有 YAML 文件格式合法（优先 python+PyYAML，回退基础结构检查）
#   3. 脚本中不存在硬编码密钥（常见密钥模式扫描）
#   4. 所有脚本具备可执行权限（检查并报告，不影响退出码）
#
# 用法：
#   bash cicd/ci/scripts/lint.sh
#   ./cicd/ci/scripts/lint.sh
#
# 退出码：
#   0 - 所有必须检查通过（语法 / YAML / 密钥）
#   1 - 任一必须检查失败
#   注：可执行权限为“报告”级别（warn），不影响退出码
# ============================================================

set -u

# ---- 加载公共函数库（info/success/warn/error 等） ----
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/common.sh"

# ---- 路径定位 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# 制表符（用于 YAML 缩进检测，跨平台兼容 busybox/gnu grep）
TAB="$(printf '\t')"

# 失败计数（仅必须检查项累计）
FAIL_COUNT=0

# ============================================================
# 检查 1：Shell 脚本语法检查（bash -n）
# ============================================================
check_shell_syntax() {
    print_header "检查 1/4: Shell 脚本语法 (bash -n)"

    local sh_files total=0 passed=0 failed=0
    sh_files="$(find "${PROJECT_ROOT}" -type f -name '*.sh' \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -not -path '*/data/*' \
        -not -path '*/logs/*' \
        | sort)"

    if [ -z "${sh_files}" ]; then
        warn "未找到任何 .sh 脚本文件"
        return 0
    fi

    while IFS= read -r file; do
        [ -z "${file}" ] && continue
        total=$((total + 1))
        if bash -n "${file}" 2>/dev/null; then
            success "语法正确: ${file#${PROJECT_ROOT}/}"
            passed=$((passed + 1))
        else
            error "语法错误: ${file#${PROJECT_ROOT}/}"
            bash -n "${file}" 2>&1 | sed 's/^/    /' >&2
            failed=$((failed + 1))
        fi
    done <<< "${sh_files}"

    info "Shell 语法检查: ${passed}/${total} 通过, ${failed} 失败"
    [ "${failed}" -eq 0 ]
}

# ============================================================
# 检查 2：YAML 文件合法性检查
# ============================================================
check_yaml_validity() {
    print_header "检查 2/4: YAML 文件合法性"

    local yaml_files total=0 passed=0 failed=0
    yaml_files="$(find "${PROJECT_ROOT}" -type f \( -name '*.yml' -o -name '*.yaml' \) \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -not -path '*/data/*' \
        -not -path '*/logs/*' \
        | sort)"

    if [ -z "${yaml_files}" ]; then
        warn "未找到任何 YAML 文件"
        return 0
    fi

    # 判断是否可用 python3 + PyYAML
    local use_python=false
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
        use_python=true
        info "使用 python3 + PyYAML 进行严格校验"
    else
        warn "未检测到 python3/PyYAML，对所有 YAML 执行基础结构检查"
    fi

    while IFS= read -r file; do
        [ -z "${file}" ] && continue
        total=$((total + 1))
        local rel="${file#${PROJECT_ROOT}/}"

        if [ "${use_python}" = "true" ]; then
            if python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "${file}" 2>/dev/null; then
                # 严格解析通过
                success "YAML 合法: ${rel}"
                passed=$((passed + 1))
            elif grep -q '{{' "${file}" 2>/dev/null; then
                # 含 {{ 占位符的模板文件（Helm / sed 模板）无法作为纯 YAML 解析，降级为基础检查
                if [ ! -s "${file}" ]; then
                    error "YAML 模板文件为空: ${rel}"
                    failed=$((failed + 1))
                elif grep -nE "^${TAB}" "${file}" >/dev/null 2>&1; then
                    error "YAML 模板使用了制表符缩进（不允许）: ${rel}"
                    grep -nE "^${TAB}" "${file}" | head -3 | sed 's/^/    /' >&2
                    failed=$((failed + 1))
                else
                    warn "模板文件（含 {{ 占位符），跳过严格校验，基础检查通过: ${rel}"
                    passed=$((passed + 1))
                fi
            else
                error "YAML 不合法: ${rel}"
                python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "${file}" 2>&1 | sed 's/^/    /' >&2
                failed=$((failed + 1))
            fi
        else
            # 无 python 环境：基础结构检查（非空 + 无制表符缩进）
            if [ ! -s "${file}" ]; then
                error "YAML 文件为空: ${rel}"
                failed=$((failed + 1))
            elif grep -nE "^${TAB}" "${file}" >/dev/null 2>&1; then
                error "YAML 使用了制表符缩进（不允许）: ${rel}"
                grep -nE "^${TAB}" "${file}" | head -3 | sed 's/^/    /' >&2
                failed=$((failed + 1))
            else
                success "YAML 基础检查通过: ${rel}"
                passed=$((passed + 1))
            fi
        fi
    done <<< "${yaml_files}"

    info "YAML 检查: ${passed}/${total} 通过, ${failed} 失败"
    [ "${failed}" -eq 0 ]
}

# ============================================================
# 检查 3：硬编码密钥扫描（仅扫描 .sh 脚本）
# ============================================================
check_hardcoded_secrets() {
    print_header "检查 3/4: 硬编码密钥扫描 (脚本)"

    local sh_files
    sh_files="$(find "${PROJECT_ROOT}" -type f -name '*.sh' \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -not -path '*/data/*' \
        -not -path '*/logs/*' \
        | sort)"

    if [ -z "${sh_files}" ]; then
        warn "未找到任何 .sh 脚本文件"
        return 0
    fi

    # 高置信度密钥模式（命中即为疑似硬编码密钥）
    local patterns=(
        '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        'AKIA[0-9A-Z]{16}'
        'gh[pousr]_[A-Za-z0-9]{36}'
        'github_pat_[A-Za-z0-9_]{82}'
        'xox[baprs]-[0-9A-Za-z-]{10,}'
        'sk_live_[0-9A-Za-z]{20,}'
        'rk_live_[0-9A-Za-z]{20,}'
        'AIza[0-9A-Za-z_-]{35}'
        'sk-[A-Za-z0-9]{20,}'
    )

    info "扫描高置信度密钥模式（AWS / GitHub / Slack / Stripe / Google / OpenAI / 私钥）..."
    local hits=0
    while IFS= read -r file; do
        [ -z "${file}" ] && continue
        local rel="${file#${PROJECT_ROOT}/}"
        local pattern match
        for pattern in "${patterns[@]}"; do
            match="$(grep -nE "${pattern}" "${file}" 2>/dev/null || true)"
            if [ -n "${match}" ]; then
                error "疑似硬编码密钥 [${rel}]"
                echo "${match}" | head -5 | sed 's/^/    /' >&2
                hits=$((hits + 1))
            fi
        done
    done <<< "${sh_files}"

    # 赋值式硬编码密钥：密钥名变量被赋予字面量值（非 ${VAR} 引用）
    # 仅匹配 base64 / 十六进制 / 字母数字类字面量，自动排除 ${VAR} 变量引用
    info "扫描赋值式硬编码密钥（密钥名变量被赋予字面量值）..."
    local assign_pattern
    assign_pattern='(password|passwd|secret|api[_-]?key|access[_-]?token|private[_-]?key|token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9+/=_.:-]{8,}["'"'"']'
    while IFS= read -r file; do
        [ -z "${file}" ] && continue
        local rel="${file#${PROJECT_ROOT}/}"
        local match
        match="$(grep -inE "${assign_pattern}" "${file}" 2>/dev/null || true)"
        if [ -n "${match}" ]; then
            error "疑似赋值式硬编码密钥 [${rel}]"
            echo "${match}" | head -5 | sed 's/^/    /' >&2
            hits=$((hits + 1))
        fi
    done <<< "${sh_files}"

    if [ "${hits}" -gt 0 ]; then
        error "发现 ${hits} 处疑似硬编码密钥，请改用环境变量或密钥管理服务"
        return 1
    fi

    success "未发现硬编码密钥"
}

# ============================================================
# 检查 4：脚本可执行权限检查（报告级别，不影响退出码）
# ============================================================
check_execute_permissions() {
    print_header "检查 4/4: 脚本可执行权限（报告）"

    local sh_files total=0 exec_ok=0 exec_missing=0
    sh_files="$(find "${PROJECT_ROOT}" -type f -name '*.sh' \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -not -path '*/data/*' \
        -not -path '*/logs/*' \
        | sort)"

    if [ -z "${sh_files}" ]; then
        warn "未找到任何 .sh 脚本文件"
        return 0
    fi

    while IFS= read -r file; do
        [ -z "${file}" ] && continue
        total=$((total + 1))
        local rel="${file#${PROJECT_ROOT}/}"
        if [ -x "${file}" ]; then
            exec_ok=$((exec_ok + 1))
        else
            warn "缺少可执行权限: ${rel}（建议: chmod +x ${rel}）"
            exec_missing=$((exec_missing + 1))
        fi
    done <<< "${sh_files}"

    info "可执行权限: ${exec_ok}/${total} 具备, ${exec_missing} 缺失（仅报告）"
    if [ "${exec_missing}" -gt 0 ]; then
        warn "存在缺少可执行权限的脚本，请按需执行 chmod +x（此项不影响 CI 结果）"
    else
        success "所有脚本均具备可执行权限"
    fi
    # 报告级别：始终返回成功
    return 0
}

# ============================================================
# 主流程
# ============================================================
main() {
    print_header "DevPilot CI Lint 检查"
    info "项目根目录: ${PROJECT_ROOT}"
    echo ""

    # 必须检查项（影响退出码）
    check_shell_syntax        || FAIL_COUNT=$((FAIL_COUNT + 1))
    check_yaml_validity       || FAIL_COUNT=$((FAIL_COUNT + 1))
    check_hardcoded_secrets   || FAIL_COUNT=$((FAIL_COUNT + 1))

    # 报告级别检查（不影响退出码）
    check_execute_permissions || true

    echo ""
    print_separator
    if [ "${FAIL_COUNT}" -eq 0 ]; then
        success "所有必须检查通过 (lint 完成)"
        exit 0
    else
        error "${FAIL_COUNT} 项必须检查失败"
        exit 1
    fi
}

main "$@"
