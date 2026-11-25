# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
#
# [FORMAT] align_row_ends LEFT RIGHT [WIDTH] -> 两端对齐到一行。
# 两侧都可以带 ANSI；省略 WIDTH 时使用当前 DATA_W。
# 用法：line=$(align_row_ends "$left" "$right")

_align_row_ends_into() {
    local __var=$1 left=$2 right=$3 width=${4:-$DATA_W}
    local gap left_width right_width
    _display_width_into left_width "$left"
    _display_width_into right_width "$right"
    gap=$((width - left_width - right_width))
    (( gap >= 1 )) || gap=1
    printf -v "$__var" '%s%*s%s' "$left" "$gap" '' "$right"
}

align_row_ends() {
    local out
    _align_row_ends_into out "$@"
    printf '%s' "$out"
}

# [FORMAT] format_quantity QTY UNIT COLOR WIDTH -> 左对齐数量 + 固定单位。
# 用法：cell=$(format_quantity 13.2 GiB "$C_V" 5)
format_quantity() {
    local quantity=${1-} unit=${2-} color=${3-} width=${4:-0}
    [[ $width =~ ^[0-9]+$ ]] || width=0
    printf '%s%-*s %s%s' "$color" "$width" "$quantity" "$unit" "$C_RESET"
}

# [FORMAT] format_mem_quantity QTY COLOR -> 带 GiB 且单位纵向对齐。
# 用法：cell=$(format_mem_quantity 13.2 "$C_BAR_USED")
format_mem_quantity() {
    format_quantity "$1" 'GiB' "$2" "$MEM_QTY_W"
}

# [FORMAT] align_mem_percent LABEL PCT COLOR -> 左数量、右百分比的整行值。
# 用法：row=$(align_mem_percent "$display" 82.5 "$C_BAR_USED")
_align_mem_percent_into() {
    local __var=$1 metric=$2 percent=$3 color=$4 __mem_pct_text
    _format_percent_text_into __mem_pct_text "$percent"
    _align_row_ends_into "$__var" "$metric" \
        "${color}${__mem_pct_text}${C_RESET}"
}

align_mem_percent() {
    local out
    _align_mem_percent_into out "$@"
    printf '%s' "$out"
}

# “是否正常”看 available，而不是看 used：used 高不代表新进程没有内存
# 可用，因为 buff/cache 中可以回收一部分。阈值可按业务调整；这里采用
# 常见默认值：available >= 20% 正常，10%~20% 偏紧，< 10% 危险。
MEM_OK_PERCENT=20
MEM_WARN_PERCENT=10

# [FORMAT] memory_status_text PCT OK_THRESHOLD WARN_THRESHOLD -> 彩色状态。
# 状态只依据 available 百分比，不依据 used。
# 用法：status=$(memory_status_text 8.8 20 10)
memory_status_text() {
    local percent=$1 ok=$2 warn=$3 state='crit'
    local scaled_percent
    if _number_to_scaled_into scaled_percent "$percent" 1; then
        if (( scaled_percent >= ok * 10 )); then
            state='ok'
        elif (( scaled_percent >= warn * 10 )); then
            state='warn'
        fi
    fi
    case "$state" in
        ok)   printf '%s●可用内存正常%s' "$C_OK" "$C_RESET" ;;
        warn) printf '%s●可用内存偏紧%s' "$C_WARN" "$C_RESET" ;;
        *)    printf '%s●可用内存危险%s' "$C_CRIT" "$C_RESET" ;;
    esac
}

mem_used_percent=$(percent_of "$mem_used" "$mem_total")
mem_free_percent=$(percent_of "$mem_free" "$mem_total")
mem_shared_percent=$(percent_of "$mem_shared" "$mem_total")
mem_cache_percent=$(percent_of "$mem_cache" "$mem_total")
mem_available_percent=$(percent_of "$mem_available" "$mem_total")

# 统一格式化为一位小数，避免 16 和 3.2 的小数点无法纵向对齐。
printf -v mem_total_qty     '%.1f' "$mem_total"
printf -v mem_used_qty      '%.1f' "$mem_used"
printf -v mem_free_qty      '%.1f' "$mem_free"
printf -v mem_shared_qty    '%.1f' "$mem_shared"
printf -v mem_cache_qty     '%.1f' "$mem_cache"
printf -v mem_available_qty '%.1f' "$mem_available"

MEM_QTY_W=$(max_display_width \
    "$mem_total_qty" "$mem_used_qty" "$mem_free_qty" \
    "$mem_shared_qty" "$mem_cache_qty" "$mem_available_qty")

mem_status=$(memory_status_text \
    "$mem_available_percent" "$MEM_OK_PERCENT" "$MEM_WARN_PERCENT")

# TOTAL 只显示容量；健康状态放在该行末尾，并明确标明它评估的是可用内存。
total_display=$(format_mem_quantity "$mem_total_qty" "$C_MEM_TOTAL")
used_display=$(format_mem_quantity "$mem_used_qty" "$C_BAR_USED")
free_display=$(format_mem_quantity "$mem_free_qty" "$C_BAR_FREE")
shared_display=$(format_mem_quantity "$mem_shared_qty" "$C_MEM_SHARED")
cache_display=$(format_mem_quantity "$mem_cache_qty" "$C_BAR_CACHE")
available_display=$(format_mem_quantity \
    "$mem_available_qty" "$C_BAR_AVAILABLE")

FIELD_LABELS=()
FIELD_VALUES=()
FIELD_BREAK_BEFORE=()

# ── [TABLE] 字段注册与值对齐 ───────────────────────────────────────────

# [TABLE] add_field LABEL VALUE [BREAK] -> 追加一行字段。
# BREAK：0 不画线，1 实线，2 虚线；FIELD_INDEX 保存刚追加的行号。
# 用法：add_field 'UPTIME' '2h 10m' 1；row=$FIELD_INDEX
add_field() {
    FIELD_LABELS+=("$1")
    FIELD_VALUES+=("${2-}")
    FIELD_BREAK_BEFORE+=("${3:-0}")
    FIELD_INDEX=$((${#FIELD_LABELS[@]} - 1))
}

# [FORMAT] color_kv_segment "KEY VALUE" -> 青色键、黄色值。
# 没有空格的段落整段按值着色，适合 '-' 等占位符。
# 用法：colored=$(color_kv_segment 'TYPE SSD')
_color_kv_segment_into() {
    local __var=$1 part=$2 key value
    if [[ "$part" == *" "* ]]; then
        key=${part%% *}
        value=${part#* }
        printf -v "$__var" '%s%s%s %s%s%s' \
            "$C_K" "$key" "$C_RESET" \
            "$C_V" "$value" "$C_RESET"
    else
        printf -v "$__var" '%s%s%s' "$C_V" "$part" "$C_RESET"
    fi
}

color_kv_segment() {
    local out
    _color_kv_segment_into out "${1-}"
    printf '%s' "$out"
}

# [FORMAT] color_kv_segments TEXT -> 统一着色以 " · " 分隔的 KV 段落。
# 只处理颜色和分隔符，不补齐宽度；应先用 pad_display 对齐各列。
# 用法：colored=$(color_kv_segments 'DISK sda · TYPE SSD')
_color_kv_segments_into() {
    local __var=$1 rest=${2-} part __kv_part_out __kv_out=''
    while [[ "$rest" == *" · "* ]]; do
        part=${rest%% · *}
        _color_kv_segment_into __kv_part_out "$part"
        __kv_out+="${__kv_part_out} · "
        rest=${rest#* · }
    done
    _color_kv_segment_into __kv_part_out "$rest"
    __kv_out+=$__kv_part_out
    printf -v "$__var" '%s' "$__kv_out"
}

color_kv_segments() {
    local out
    _color_kv_segments_into out "${1-}"
    printf '%s' "$out"
}

