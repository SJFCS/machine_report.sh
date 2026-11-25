# shellcheck shell=bash
# shellcheck disable=SC2154
#
# ── [HANDLER] 内存 ─────────────────────────────────────────────────────
#
# mem_total/mem_used/mem_cache/mem_free/mem_shared/mem_available 由
# sources/system.sh 采集（单位 GiB）。这里负责百分比、展示值和占用条。
#
# 本文件绘制的行：MEM TOTAL / MEM USAGE / MEM USED / BUFF/CACHE /
#   MEM FREE / MEM SHARED / MEM AVAILABLE

# “是否正常”看 available，而不是看 used：used 高不代表新进程没有内存
# 可用，因为 buff/cache 中可以回收一部分。阈值可按业务调整；这里采用
# 常见默认值：available >= 20% 正常，10%~20% 偏紧，< 10% 危险。
MEM_OK_PERCENT=20
MEM_WARN_PERCENT=10

# [FORMAT] memory_status_text PCT OK WARN -> 彩色状态。
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
        ok)   printf '%s ● MEM NORMAL%s' "$C_OK" "$C_RESET" ;;
        warn) printf '%s ● MEM WARNING%s' "$C_WARN" "$C_RESET" ;;
        *)    printf '%s ● MEM CRITICAL%s' "$C_CRIT" "$C_RESET" ;;
    esac
}

# [FORMAT] format_mem_quantity QTY COLOR -> 带 GiB 且单位纵向对齐。
format_mem_quantity() {
    format_quantity "$1" 'GiB' "$2" "$MEM_QTY_W"
}

# [FORMAT] align_mem_percent LABEL PCT COLOR -> 左数量、右百分比的整行值。
_align_mem_percent_into() {
    local __var=$1 metric=$2 percent=$3 color=$4 __mem_pct_text
    _format_percent_text_into __mem_pct_text "$percent"
    _align_row_ends_into "$__var" "$metric" \
        "${color}${__mem_pct_text}${C_RESET}"
}

handler_memory() {
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

    total_display=$(format_mem_quantity "$mem_total_qty" "$C_MEM_TOTAL")
    used_display=$(format_mem_quantity "$mem_used_qty" "$C_BAR_USED")
    free_display=$(format_mem_quantity "$mem_free_qty" "$C_BAR_FREE")
    shared_display=$(format_mem_quantity "$mem_shared_qty" "$C_MEM_SHARED")
    cache_display=$(format_mem_quantity "$mem_cache_qty" "$C_BAR_CACHE")
    available_display=$(format_mem_quantity \
        "$mem_available_qty" "$C_BAR_AVAILABLE")

    mr_field_break 'MEM TOTAL' "$total_display"
    MEM_TOTAL_ROW=$FIELD_INDEX
    mr_field 'MEM USAGE' ''
    MEM_BAR_ROW=$FIELD_INDEX
    mr_field 'MEM USED'      "$used_display"
    MEM_USED_ROW=$FIELD_INDEX
    mr_field 'BUFF/CACHE'    "$cache_display"
    MEM_CACHE_ROW=$FIELD_INDEX
    mr_field 'MEM FREE'      "$free_display"
    MEM_FREE_ROW=$FIELD_INDEX
    mr_field 'MEM SHARED'    "$shared_display"
    MEM_SHARED_ROW=$FIELD_INDEX
    mr_field 'MEM AVAILABLE' "$available_display"
    MEM_AVAILABLE_ROW=$FIELD_INDEX
}

handler_memory_fill() {
    local cell

    _align_mem_percent_into cell \
        "$used_display" "$mem_used_percent" "$C_BAR_USED"
    mr_update "$MEM_USED_ROW" "$cell"
    _align_mem_percent_into cell \
        "$cache_display" "$mem_cache_percent" "$C_BAR_CACHE"
    mr_update "$MEM_CACHE_ROW" "$cell"
    _align_mem_percent_into cell \
        "$free_display" "$mem_free_percent" "$C_BAR_FREE"
    mr_update "$MEM_FREE_ROW" "$cell"
    _align_mem_percent_into cell \
        "$shared_display" "$mem_shared_percent" "$C_MEM_SHARED"
    mr_update "$MEM_SHARED_ROW" "$cell"
    _align_mem_percent_into cell \
        "$available_display" "$mem_available_percent" "$C_BAR_AVAILABLE"
    mr_update "$MEM_AVAILABLE_ROW" "$cell"

    _format_percent_suffix_into MEM_PERCENT_SUFFIX "$mem_used_percent"
    MEM_BAR_WIDTH=$((DATA_W - ${#MEM_PERCENT_SUFFIX}))
    (( MEM_BAR_WIDTH > 0 )) || MEM_BAR_WIDTH=1
    local bar_cell
    _stacked_bar_into bar_cell "$mem_total" "$MEM_BAR_WIDTH" \
        "$mem_used"  '█' "$C_BAR_USED" \
        "$mem_cache" '▓' "$C_BAR_CACHE" \
        "$mem_free"  '░' "$C_BAR_FREE"
    mr_update "$MEM_BAR_ROW" "$bar_cell$MEM_PERCENT_SUFFIX"

    _align_row_ends_into cell "$total_display" "$mem_status"
    mr_update "$MEM_TOTAL_ROW" "$cell"
}

mr_register memory
