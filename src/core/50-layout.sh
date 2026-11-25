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
# 用法：ensure_centered_width "$text"（一般由 measure_cover_lines 统一调用）
ensure_centered_width() {
    local text=$1 inner text_width required
    inner=$((NAME_W + DATA_W + 5))
    text_width=$(display_width "$text")
    required=$((text_width + 2))
    if (( required > inner )); then
        DATA_W=$((DATA_W + required - inner))
    fi
}

# [TABLE] measure_cover_lines -> 保证封面/页脚文字不会被表格宽度截断。
# 文字来自 mr_cover_line / mr_footer_line，数量不限。
# 先用“每个字符最多占 2 列”做上界：常见的一两行标题明显放得下，
# 就不用为中文标题启动 Perl；只有可能超宽的行才批量精确测量一次。
measure_cover_lines() {
    local i text inner max_width=0 width required
    local -a texts=()
    local -a too_wide=()

    for i in "${!MR_COVER_LINES[@]}"; do
        texts+=("${MR_COVER_LINES[i]}")
    done
    for i in "${!MR_FOOTER_LINES[@]}"; do
        texts+=("${MR_FOOTER_LINES[i]}")
    done
    (( ${#texts[@]} > 0 )) || return 0

    inner=$((NAME_W + DATA_W + 5))
    for text in "${texts[@]}"; do
        (( ${#text} * 2 + 2 > inner )) || continue
        too_wide+=("$text")
    done
    (( ${#too_wide[@]} > 0 )) || return 0

    while IFS= read -r -d '' width; do
        [[ $width =~ ^[0-9]+$ ]] || width=0
        (( width > max_width )) && max_width=$width
    done < <(_display_widths_batch "${too_wide[@]}")

    required=$((max_width + 2))
    (( required > inner )) && DATA_W=$((DATA_W + required - inner))
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
# 名字列和数据列各加一格内边距，宽度与字段行一致。
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

# [TABLE] _format_report_lines TEXT... -> 一次 Perl 输出全部渲染行。
# 记录以 NUL 分隔，开头 C 表示居中行、R 表示字段行。这样标题区和表格
# 共用一次 Perl 启动，同时分隔线仍由 Bash 控制。
_format_report_lines() {
    local inner=$((NAME_W + DATA_W + 5))
    local center_count=$#
    local row_count=${#FIELD_LABELS[@]}

    printf '%s\0' "$@" "${FIELD_LABELS[@]}" "${FIELD_VALUES[@]}" |
        TABLE_MODE=render-report \
            TABLE_INNER="$inner" \
            TABLE_CENTER_COUNT="$center_count" \
            TABLE_ROWS="$row_count" \
            TABLE_NAME_W="$NAME_W" \
            TABLE_DATA_W="$DATA_W" \
            perl -CS -e "$DISPLAY_WIDTH_PERL"
}

# [TABLE] bar USED TOTAL [WIDTH] -> 无颜色横向百分比条。
# 条形字符本身都是单列字符，所以这里可以直接用 repeat_char()；
# 普通十进制先转成定点整数计算块数；异常输入才回退 awk。
# 省略 WIDTH 时使用 DATA_W。
# 用法：graph=$(bar 42.5 100 20)
_bar_into() {
    local __var=$1 used=${2-0} total=${3-0} width=${4:-${DATA_W:-0}}
    local blocks scaled_used scaled_total filled empty

    is_number "$used" || used=0
    is_number "$total" || total=0
    [[ $width =~ ^[0-9]+$ ]] || width=0

    if _number_to_scaled_into scaled_used "$used" 6 &&
        _number_to_scaled_into scaled_total "$total" 6; then
        if (( scaled_total <= 0 || width <= 0 || scaled_used <= 0 )); then
            blocks=0
        else
            blocks=$(((scaled_used * width) / scaled_total))
            (( blocks > width )) && blocks=$width
        fi
    else
        blocks=$(awk -v u="$used" -v t="$total" -v w="$width" 'BEGIN {
            if (t <= 0 || w <= 0) { print 0; exit }
            n = int(((u / t) * 100 / 100) * w)
            if (n < 0) n = 0
            if (n > w) n = w
            print n
        }')
    fi

    _repeat_char_into filled '█' "$blocks"
    _repeat_char_into empty '░' "$((width - blocks))"
    printf -v "$__var" '%s%s' "$filled" "$empty"
}

bar() {
    local out
    _bar_into out "$@"
    printf '%s' "$out"
}

# [TABLE] percent_bar_display VALUE TOTAL PERCENT -> 条形图 + 百分比文本。
# 用法：cell=$(percent_bar_display 42.5 100 42.5)
_percent_bar_display_into() {
    local __var=$1 value=$2 total=$3 percent=$4
    local suffix graph_width graph
    _format_percent_suffix_into suffix "$percent"
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    _bar_into graph "$value" "$total" "$graph_width"
    printf -v "$__var" '%s%s' "$graph" "$suffix"
}

percent_bar_display() {
    local out
    _percent_bar_display_into out "$@"
    printf '%s' "$out"
}

# [FORMAT] disk_usage_display PERCENT -> 磁盘使用率条形图值列。
# 用法：cell=$(disk_usage_display 42.5)
_disk_usage_display_into() {
    local __var=$1 percent=${2-}
    _percent_bar_display_into "$__var" "$percent" 100 "$percent"
}

disk_usage_display() {
    local out
    _disk_usage_display_into out "${1-}"
    printf '%s' "$out"
}

# [FORMAT] gpu_memory_display USED_MIB TOTAL_MIB -> 显存条形图和 GiB 文本。
# 用法：cell=$(gpu_memory_display 64000 81920)
_gpu_memory_display_into() {
    local __var=$1 used_mib=$2 total_mib=$3
    local percent used_gib total_gib suffix percent_text
    local graph_width graph
    percent=$(percent_of "$used_mib" "$total_mib")
    used_gib=$(format_mib_as_gib "$used_mib")
    total_gib=$(format_mib_as_gib "$total_mib")
    _format_percent_text_into percent_text "$percent"
    suffix=" ${used_gib}/${total_gib} GiB ${percent_text}"
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    _bar_into graph "$used_mib" "$total_mib" "$graph_width"
    printf -v "$__var" '%s%s' "$graph" "$suffix"
}

gpu_memory_display() {
    local out
    _gpu_memory_display_into out "$@"
    printf '%s' "$out"
}

# [FORMAT] gpu_util_display PERCENT -> GPU 利用率条形图值列。
# 用法：cell=$(gpu_util_display 91)
_gpu_util_display_into() {
    local __var=$1 percent=${2-}
    _percent_bar_display_into "$__var" "$percent" 100 "$percent"
}

gpu_util_display() {
    local out
    _gpu_util_display_into out "${1-}"
    printf '%s' "$out"
}

# [FORMAT] load_display LOAD CPU_COUNT -> 负载条、负载/核数和百分比。
# 用法：cell=$(load_display 25.60 128)
_load_display_into() {
    local __var=$1 load=$2 cores=$3
    local percent load_text percent_text suffix
    local graph_width graph

    percent=$(percent_of "$load" "$cores")
    if is_number "$load"; then
        printf -v load_text '%5.2f' "$load"
    else
        load_text='    -'
    fi
    _format_percent_text_into percent_text "$percent"
    # 先拼出完整的右侧文字，再按实际长度扣减条形宽度，避免每加一个
    # 分隔符就要同步修改一个魔法数字。
    printf -v suffix ' %s/%s %s' "$load_text" "$cores" "$percent_text"
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    _bar_into graph "$load" "$cores" "$graph_width"
    printf -v "$__var" '%s%s' "$graph" "$suffix"
}

load_display() {
    local out
    _load_display_into out "$@"
    printf '%s' "$out"
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
_stacked_bar_into() {
    local __var=$1 total=${2-0} width=${3-0}
    shift 3

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
        printf -v "$__var" '%s' ''
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

    local i blocks_used=0 __bar_out='' __segment
    for i in "${!values[@]}"; do
        count=${counts[i]:-0}
        if (( count > 0 )); then
            _repeat_char_into __segment "${chars[i]}" "$count"
            __bar_out+="${colors[i]}${__segment}${C_RESET}"
            blocks_used=$((blocks_used + count))
        fi
    done

    # total 大于各段之和时，剩余部分用中性背景补齐，仍保持 WIDTH 列。
    if (( blocks_used < width )); then
        _repeat_char_into __segment '░' "$((width - blocks_used))"
        __bar_out+="${C_BAR_EMPTY}${__segment}${C_RESET}"
    fi

    printf -v "$__var" '%s' "$__bar_out"
}

stacked_bar() {
    local out rc
    _stacked_bar_into out "$@"
    rc=$?
    if (( rc == 0 )); then
        printf '%s' "$out"
    fi
    return "$rc"
}

