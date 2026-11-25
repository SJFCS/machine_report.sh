# shellcheck shell=bash
#
# ── handler 公开 API ───────────────────────────────────────────────────
#
# 这里之前的所有文件都是“框架内部”：它们只负责测量、对齐、画线。
# handler 只需要下面这些 mr_ 开头的函数，不用关心内部实现。
#
# handler 契约（每个 handler 一个文件，放在 src/handlers/）：
#
#   handler_xxx()          必需。采集数据并调用 mr_field 追加行。
#                          字段顺序就是文件里调用的顺序。
#   handler_xxx_measure()  可选。列宽测量后、回填前调用，
#                          用来把 DATA_W 撑到关键文本的宽度。
#   handler_xxx_fill()     可选。DATA_W 确定后调用，
#                          用来回填条形图、百分比这类依赖宽度的值。
#
# 写完在文件末尾调用一次 mr_register xxx 即可，注册顺序就是渲染顺序。
#
# 可读取的全局量：
#   DATA_W     值列可用宽度（measure 之后有效）
#   NAME_W     字段名列宽
#   FIELD_INDEX 最近一次 mr_field 的行号（用于 _fill 里回填）
#
# 示例：
#   handler_uptime() {
#       mr_field_break 'UPTIME' "$(uptime_text)"
#   }
#   mr_register uptime
#
# 需要宽度相关的行：
#   handler_load() {
#       mr_field 'LOAD 1m' ''          # 先占位
#       LOAD_ROW=$FIELD_INDEX
#   }
#   handler_load_fill() {
#       mr_update "$LOAD_ROW" "$(mr_bar "$load1" "$cpu_cores")"
#   }

# 已注册的 handler 名称，顺序即渲染顺序。
MR_HANDLERS=()

# mr_register NAME -> 追加一个 handler。
mr_register() {
    MR_HANDLERS+=("${1-}")
}

# mr_field LABEL VALUE [BREAK] -> 追加一行字段（BREAK: 0 无 | 1 实线 | 2 虚线）。
mr_field() {
    add_field "${1-}" "${2-}" "${3:-0}"
}

# mr_field_break LABEL VALUE -> 追加一行，并在上方画实线分组。
mr_field_break() {
    add_field "${1-}" "${2-}" 1
}

# mr_field_dashed LABEL VALUE -> 追加一行，并在上方画虚线（同组多条目用）。
mr_field_dashed() {
    add_field "${1-}" "${2-}" 2
}

# mr_update INDEX VALUE -> 回填指定行的值。
mr_update() {
    FIELD_VALUES[${1:-0}]=${2-}
}

# mr_width TEXT -> 终端显示列数（中文/ANSI 安全）。
mr_width() {
    display_width "${1-}"
}

# mr_pad TEXT WIDTH -> 右补空格到指定显示宽度。
mr_pad() {
    pad_display "${1-}" "${2:-0}"
}

# mr_fit TEXT WIDTH -> 超宽时截断并以 … 结尾。
mr_fit() {
    fit_display "${1-}" "${2:-0}"
}

# mr_bar VALUE TOTAL [WIDTH] -> 无颜色百分比条；WIDTH 省略时用 DATA_W。
mr_bar() {
    bar "${1-}" "${2-}" "${3:-${DATA_W:-0}}"
}

# mr_percent_bar VALUE TOTAL PERCENT -> 百分比条 + 右侧百分比文本。
mr_percent_bar() {
    percent_bar_display "${1-}" "${2-}" "${3-}"
}

