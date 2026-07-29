#!/bin/bash

# ============================================================
# DevPilot - 轻量级 YAML 解析函数库
# 纯 bash 实现，不依赖 yq/python
# 支持：简单键值对、列表、两级嵌套
# ============================================================

# 读取简单键值对（顶层）
# 用法: yaml_get "key" "file"
# 返回: value（通过 stdout）
yaml_get() {
    local key="$1"
    local file="$2"
    # 匹配顶层 key: value（不含前导空格）
    sed -n "s/^${key}:[[:space:]]*//p" "$file" 2>/dev/null | head -1 | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

# 读取嵌套键值对（两级）
# 用法: yaml_get_nested "parent.child" "file"
# 示例: yaml_get_nested "deploy.target" "service.yaml"
yaml_get_nested() {
    local path="$1"
    local file="$2"
    local parent="${path%%.*}"
    local child="${path#*.}"

    # 如果没有点，退回到简单读取
    if [ "$parent" = "$child" ]; then
        yaml_get "$parent" "$file"
        return
    fi

    # 在 parent 块下查找 child
    # 匹配 parent: 后面的缩进行中的 child: value
    awk -v p="$parent" -v c="$child" '
        $0 ~ "^"p":" { in_block=1; next }
        in_block && /^[^[:space:]]/ { in_block=0 }
        in_block {
            sub(/^[[:space:]]+/, "")
            if ($0 ~ "^"c":") {
                sub("^"c":[[:space:]]*", "")
                gsub(/^"/, ""); gsub(/"$/, "")
                gsub(/^'\''/, ""); gsub(/'\''$/, "")
                print
                exit
            }
        }
    ' "$file" 2>/dev/null
}

# 读取列表值（顶层）
# 用法: yaml_get_list "key" "file"
# 输出: 每行一个列表项
yaml_get_list() {
    local key="$1"
    local file="$2"
    awk -v k="$key" '
        $0 ~ "^"k":" { in_block=1; next }
        in_block && /^[^[:space:]-]/ { in_block=0 }
        in_block && /^[[:space:]]*-/ {
            sub(/^[[:space:]]*-[[:space:]]*/, "")
            gsub(/^"/, ""); gsub(/"$/, "")
            gsub(/^'\''/, ""); gsub(/'\''$/, "")
            print
        }
    ' "$file" 2>/dev/null
}

# 读取嵌套列表值（两级）
# 用法: yaml_get_nested_list "parent.child" "file"
yaml_get_nested_list() {
    local path="$1"
    local file="$2"
    local parent="${path%%.*}"
    local child="${path#*.}"

    awk -v p="$parent" -v c="$child" '
        $0 ~ "^"p":" { in_parent=1; next }
        in_parent && /^[^[:space:]]/ { in_parent=0 }
        in_parent {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ "^"c":") { in_child=1; next }
            if (line ~ /^[^[:space:]-]/ && in_child) { in_child=0 }
            if (in_child && line ~ /^-/) {
                sub(/^[[:space:]]*-[[:space:]]*/, "", line)
                gsub(/^"/, "", line); gsub(/"$/, "", line)
                print line
            }
        }
    ' "$file" 2>/dev/null
}

# 检查键是否存在
# 用法: yaml_has_key "key" "file"
# 返回: 0=存在, 1=不存在
yaml_has_key() {
    local key="$1"
    local file="$2"
    grep -q "^${key}:" "$file" 2>/dev/null
}

# 检查嵌套键是否存在
# 用法: yaml_has_nested_key "parent.child" "file"
yaml_has_nested_key() {
    local path="$1"
    local file="$2"
    [ -n "$(yaml_get_nested "$path" "$file")" ]
}
