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

