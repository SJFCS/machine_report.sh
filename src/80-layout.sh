# shellcheck shell=bash
# ── [TABLE] 布局测量 ───────────────────────────────────────────────────

# [TABLE] measure_fields -> 根据 FIELD_LABELS/FIELD_VALUES 计算 NAME_W/DATA_W。
# 需在静态字段全部 add_field 之后、条形图回填之前调用。
# 用法：measure_fields
# 注意：此时条形图值还是空串；条形图会主动使用 DATA_W，因此不会反过来
# 把数据列撑宽。
measure_fields() {
    NAME_W=$(max_display_width "${FIELD_LABELS[@]}")
    (( NAME_W < NAME_MIN )) && NAME_W=$NAME_MIN
    (( NAME_W > NAME_MAX )) && NAME_W=$NAME_MAX

    DATA_W=$(max_display_width "${FIELD_VALUES[@]}")
    (( DATA_W < DATA_MIN )) && DATA_W=$DATA_MIN
    (( DATA_W > DATA_MAX )) && DATA_W=$DATA_MAX
}

# [TABLE] ensure_centered_width TEXT -> 扩展 DATA_W 以完整容纳跨列文本。
# 两侧至少预留一个空格，避免文字贴住左右边框。
# 用法：ensure_centered_width "$server_display"
ensure_centered_width() {
    local text=$1 inner text_width required
    inner=$((NAME_W + DATA_W + 5))
    text_width=$(display_width "$text")
    required=$((text_width + 2))
    if (( required > inner )); then
        DATA_W=$((DATA_W + required - inner))
    fi
}

# [TABLE] ensure_data_width TEXT -> 保证指定值至少占 DATA_W 宽。
# 用于 GPU 型号/显存/频率等不允许截断的关键行。
# 用法：ensure_data_width "$gpu_identity"
ensure_data_width() {
    local text=$1 text_width
    text_width=$(display_width "$text")
    (( text_width > DATA_W )) && DATA_W=$text_width
}

# ── 表格绘制 ───────────────────────────────────────────────────────────

# [TABLE] print_divider LEFT MIDDLE RIGHT [CHAR] -> 两列之间的横线。
# 名字列和数据列各加一格内边距，宽度与 print_row 一致。
# 用法：print_divider "$MID_LEFT" "$MID_MID" "$MID_RIGHT"
print_divider() {
    local left=$1 middle=$2 right=$3
    local line_char=${4:-$HORIZONTAL}
    printf '%s%s%s%s%s\n' \
        "$left" \
        "$(repeat_char "$line_char" "$((NAME_W + 2))")" \
        "$middle" \
        "$(repeat_char "$line_char" "$((DATA_W + 2))")" \
        "$right"
}

# [TABLE] print_dashed_divider -> 两列之间的虚线分隔，用于磁盘之间。
# 用法：print_dashed_divider
print_dashed_divider() {
    print_divider \
        "$MID_LEFT" "$MID_MID" "$MID_RIGHT" "$DASHED_HORIZONTAL"
}

# [TABLE] print_header -> 输出无内部竖线的表格顶边。
# 用法：print_header
print_header() {
    print_merged_divider "$TOP_LEFT" "$TOP_RIGHT"
}

# [TABLE] print_merged_divider LEFT RIGHT -> 跨两列的连续横线。
# 用于标题区或页脚的合并行，不在中间插入 ┬/┴。
# 用法：print_merged_divider "$TOP_LEFT" "$TOP_RIGHT"
print_merged_divider() {
    local left=$1 right=$2
    printf '%s%s%s\n' \
        "$left" \
        "$(repeat_char "$HORIZONTAL" "$((NAME_W + DATA_W + 5))")" \
        "$right"
}

# [TABLE] print_centered TEXT -> 跨两列居中输出一行。
# TEXT 可以含 ANSI；宽度计算会忽略控制码。
# 用法：print_centered "${C_TITLE}${title}${C_RESET}"
print_centered() {
    local text fitted inner width left right
    inner=$((NAME_W + DATA_W + 5))  # 左右边框之间的显示列数
    fitted=$(fit_display "$1" "$inner")
    width=$(display_width "$fitted")
    left=$(((inner - width) / 2))
    right=$((inner - width - left))
    printf '│%*s%s%*s│\n' "$left" '' "$fitted" "$right" ''
}

# [TABLE] print_row LABEL VALUE -> 输出一条完整的两列表格行。
#   * 名字和值都先按显示宽度截断，保证永远不会顶破右边界；
#   * 再按显示宽度补空格，因此中文、ANSI 颜色、图标混排都能对齐；
#   * 原始 FIELD_VALUES 不会被修改，截断只影响这一行的显示内容。
# 用法：print_row 'OS' 'Ubuntu 24.04'
print_row() {
    local name data
    name=$(fit_display "$1" "$NAME_W")
    data=$(fit_display "$2" "$DATA_W")
    printf '│ %s │ %s │\n' \
        "$(pad_display "$name" "$NAME_W")" \
        "$(pad_display "$data" "$DATA_W")"
}

# [TABLE] bar USED TOTAL [WIDTH] -> 无颜色横向百分比条。
# 条形字符本身都是单列字符，所以这里可以直接用 repeat_char()；
# 百分比和块数交给 awk 计算，避免 Bash 只支持整数算术造成精度问题。
# 省略 WIDTH 时使用 DATA_W。
# 用法：graph=$(bar 42.5 100 20)
bar() {
    local used=${1-0} total=${2-0} width=${3:-${DATA_W:-0}}
    local percent blocks

    is_number "$used" || used=0
    is_number "$total" || total=0
    [[ $width =~ ^[0-9]+$ ]] || width=0

    percent=$(awk -v u="$used" -v t="$total" 'BEGIN {
        if (t <= 0) { print "0"; exit }
        printf "%.2f", (u / t) * 100
    }')

    blocks=$(awk -v p="$percent" -v w="$width" 'BEGIN {
        n = int((p / 100) * w)
        if (n < 0) n = 0
        if (n > w) n = w
        print n
    }')

    printf '%s%s' \
        "$(repeat_char '█' "$blocks")" \
        "$(repeat_char '░' "$((width - blocks))")"
}

# [TABLE] percent_bar_display VALUE TOTAL PERCENT -> 条形图 + 百分比文本。
# 用法：cell=$(percent_bar_display 42.5 100 42.5)
percent_bar_display() {
    local value=$1 total=$2 percent=$3 suffix graph_width
    suffix=$(format_percent_suffix "$percent")
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    printf '%s%s' "$(bar "$value" "$total" "$graph_width")" "$suffix"
}

# [FORMAT] disk_usage_display PERCENT -> 磁盘使用率条形图值列。
# 用法：cell=$(disk_usage_display 42.5)
disk_usage_display() {
    local percent=$1
    percent_bar_display "$percent" 100 "$percent"
}

# [FORMAT] gpu_memory_display USED_MIB TOTAL_MIB -> 显存条形图和 GiB 文本。
# 用法：cell=$(gpu_memory_display 64000 81920)
gpu_memory_display() {
    local used_mib=$1 total_mib=$2
    local percent used_gib total_gib suffix graph_width
    percent=$(percent_of "$used_mib" "$total_mib")
    used_gib=$(format_mib_as_gib "$used_mib")
    total_gib=$(format_mib_as_gib "$total_mib")
    printf -v suffix ' %s/%s GiB %s' \
        "$used_gib" "$total_gib" "$(format_percent_text "$percent")"
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    printf '%s%s' \
        "$(bar "$used_mib" "$total_mib" "$graph_width")" "$suffix"
}

# [FORMAT] gpu_util_display PERCENT -> GPU 利用率条形图值列。
# 用法：cell=$(gpu_util_display 91)
gpu_util_display() {
    local percent=$1
    percent_bar_display "$percent" 100 "$percent"
}

# [FORMAT] load_display LOAD CPU_COUNT -> 负载条、负载/核数和百分比。
# 用法：cell=$(load_display 25.60 128)
load_display() {
    local load=$1 cores=$2
    local percent load_text percent_text suffix
    local graph_width

    percent=$(percent_of "$load" "$cores")
    if is_number "$load"; then
        printf -v load_text '%5.2f' "$load"
    else
        load_text='    -'
    fi
    percent_text=$(format_percent_text "$percent")
    # 先拼出完整的右侧文字，再按实际长度扣减条形宽度，避免每加一个
    # 分隔符就要同步修改一个魔法数字。
    printf -v suffix ' %s/%s %s' "$load_text" "$cores" "$percent_text"
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    printf '%s%s' "$(bar "$load" "$cores" "$graph_width")" "$suffix"
}

# [TABLE] stacked_bar TOTAL WIDTH VALUE CHAR COLOR ... -> 彩色分段堆叠条。
#
# 用法：
#   stacked_bar TOTAL WIDTH VALUE CHAR COLOR [VALUE CHAR COLOR ...]
#
# 例如内存条：
#   stacked_bar 16 32 3.2 '█' "$C_BAR_USED" \
#                      9.6 '▓' "$C_BAR_CACHE" \
#                      3.2 '░' "$C_BAR_FREE"
#
# 每个三元组是一段：数值、绘制字符、ANSI 颜色。各段按 VALUE / TOTAL
# 的比例分配列宽；不足 TOTAL 的空隙用暗色 ░ 补齐。块数用“最大余数法”
# 分配，保证所有段加背景严格等于 WIDTH，不会多一列或少一列。
#
# 字符用 █ / ▓ / ░ 区分，即使 NO_COLOR=1 或输出到日志文件，也能看出
# 三段结构；终端里则由颜色进一步区分 used、buff/cache 和 free。
stacked_bar() {
    local total=${1-0} width=${2-0}
    shift 2

    is_number "$total" || total=0
    [[ $width =~ ^[0-9]+$ ]] || width=0

    if (( $# % 3 != 0 )); then
        printf 'stacked_bar: 段参数必须按 VALUE CHAR COLOR 三元组传入\n' >&2
        return 2
    fi

    local -a values=()
    local -a chars=()
    local -a colors=()
    while (( $# >= 3 )); do
        values+=("$1")
        chars+=("$2")
        colors+=("$3")
        shift 3
    done

    if (( ${#values[@]} == 0 || width <= 0 )); then
        return 0
    fi

    # 先算每段占多少个字符格。这里按 total 而不是 sum 归一化：
    # 当 used + cache + free 小于 total 时，剩余部分会作为背景空格显示。
    local -a counts=()
    local count
    while IFS= read -r count; do
        counts+=("$count")
    done < <(
        printf '%s\n' "${values[@]}" |
            awk -v total="$total" -v width="$width" '
                {
                    value = $1 + 0
                    if (value < 0) value = 0
                    vals[++n] = value
                    sum += value
                }
                END {
                    if (width <= 0) exit
                    if (n == 0 || total <= 0 || sum <= 0) {
                        for (i = 1; i <= n; i++) print 0
                        exit
                    }

                    stack = int(width * sum / total + 0.5)
                    if (stack < 0) stack = 0
                    if (stack > width) stack = width

                    used = 0
                    for (i = 1; i <= n; i++) {
                        exact = stack * vals[i] / sum
                        blocks[i] = int(exact)
                        remain[i] = exact - blocks[i]
                        used += blocks[i]
                    }

                    # 把四舍五入留下的零散格子给余数最大的段。
                    left = stack - used
                    while (left > 0) {
                        best = 0
                        best_remain = -1
                        for (i = 1; i <= n; i++) {
                            if (remain[i] > best_remain) {
                                best = i
                                best_remain = remain[i]
                            }
                        }
                        blocks[best]++
                        remain[best] = -1
                        left--
                    }

                    for (i = 1; i <= n; i++) print blocks[i]
                }
            '
    )

    local i blocks_used=0
    for i in "${!values[@]}"; do
        count=${counts[i]:-0}
        if (( count > 0 )); then
            printf '%s%s%s' \
                "${colors[i]}" \
                "$(repeat_char "${chars[i]}" "$count")" \
                "$C_RESET"
            blocks_used=$((blocks_used + count))
        fi
    done

    # total 大于各段之和时，剩余部分用中性背景补齐，仍保持 WIDTH 列。
    if (( blocks_used < width )); then
        printf '%s%s%s' \
            "$C_BAR_EMPTY" \
            "$(repeat_char '░' "$((width - blocks_used))")" \
            "$C_RESET"
    fi
}

