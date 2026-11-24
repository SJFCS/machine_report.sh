# shellcheck shell=bash
# shellcheck disable=SC2154
#
# ── [REPORT] 动态值回填 ────────────────────────────────────────────────

# 先测量纯数据，再生成与 DATA_W 等宽的条形图，填入对应的值槽位。
# 用 add_field 时记录下来的下标定位，不写死 6/8/10，后续增删字段更安全。
_profile_begin 'layout measure'
measure_fields
for gpu_identity in "${GPU_IDENTITY_LINES[@]}"; do
    ensure_data_width "$gpu_identity"
done
ensure_centered_width "$server_display"
ensure_centered_width "$client_display"
_profile_end
_profile_begin 'format values'
FIELD_VALUES[MEM_USED_ROW]=$(align_mem_percent \
    "$used_display" "$mem_used_percent" "$C_BAR_USED")
FIELD_VALUES[MEM_CACHE_ROW]=$(align_mem_percent \
    "$cache_display" "$mem_cache_percent" "$C_BAR_CACHE")
FIELD_VALUES[MEM_FREE_ROW]=$(align_mem_percent \
    "$free_display" "$mem_free_percent" "$C_BAR_FREE")
FIELD_VALUES[MEM_SHARED_ROW]=$(align_mem_percent \
    "$shared_display" "$mem_shared_percent" "$C_MEM_SHARED")
FIELD_VALUES[MEM_AVAILABLE_ROW]=$(align_mem_percent \
    "$available_display" "$mem_available_percent" "$C_BAR_AVAILABLE")
FIELD_VALUES[LOAD_1M_ROW]=$(load_display "$load1" "$cpu_cores")
FIELD_VALUES[LOAD_5M_ROW]=$(load_display "$load5" "$cpu_cores")
FIELD_VALUES[LOAD_15M_ROW]=$(load_display "$load15" "$cpu_cores")
for i in "${!GPU_RECORDS[@]}"; do
    IFS=$'\t' read -r gpu_used gpu_total gpu_util <<<"${GPU_RECORDS[i]}"
    FIELD_VALUES[GPU_MEM_ROWS[i]]=$(gpu_memory_display \
        "$gpu_used" "$gpu_total")
    FIELD_VALUES[GPU_UTIL_ROWS[i]]=$(gpu_util_display "$gpu_util")
done
for i in "${!DISK_BAR_ROWS[@]}"; do
    FIELD_VALUES[DISK_BAR_ROWS[i]]=$(disk_usage_display "${DISK_BAR_PCTS[i]}")
done
MEM_PERCENT_SUFFIX=$(format_percent_suffix "$mem_used_percent")
MEM_BAR_WIDTH=$((DATA_W - ${#MEM_PERCENT_SUFFIX}))
(( MEM_BAR_WIDTH > 0 )) || MEM_BAR_WIDTH=1
FIELD_VALUES[MEM_BAR_ROW]=$(
    stacked_bar "$mem_total" "$MEM_BAR_WIDTH" \
        "$mem_used"  '█' "$C_BAR_USED" \
        "$mem_cache" '▓' "$C_BAR_CACHE" \
        "$mem_free"  '░' "$C_BAR_FREE"
)
FIELD_VALUES[MEM_BAR_ROW]+=$MEM_PERCENT_SUFFIX

FIELD_VALUES[MEM_TOTAL_ROW]=$(align_row_ends "$total_display" "$mem_status")
_profile_end

# ── [REPORT] 最终渲染 ──────────────────────────────────────────────────

# [REPORT] render_report -> 渲染标题、字段行和页脚。
# 前置条件：字段已组装、measure_fields 已执行、动态值已回填。
# 用法：render_report
render_report() {
    local title='服务器运行报告'
    local subtitle='效能组·Devops Platform Service'
    local environment='PRODUCTION'
    local line
    local -a centered_lines=()
    local -a field_lines=()
    local -a centered_texts=()

    centered_texts=(
        "${C_TITLE}${title}${C_RESET}"
        "${C_ACCENT}${subtitle}${C_RESET}"
        "${C_ENV}ENVIRONMENT · ${environment}${C_RESET}"
        "$server_display"
        "$client_display"
    )

    # 标题、页脚和所有字段行合并到一个 Perl 进程。
    while IFS= read -r -d '' line; do
        case ${line:0:1} in
            C) centered_lines+=("${line:1}") ;;
            R) field_lines+=("${line:1}") ;;
        esac
    done < <(_format_report_lines "${centered_texts[@]}")

    print_header
    printf '%s\n' "${centered_lines[0]}" "${centered_lines[1]}"
    print_divider "$MID_LEFT" "$TOP_MID" "$MID_RIGHT"

    for i in "${!FIELD_LABELS[@]}"; do
        if (( i > 0 )); then
            case ${FIELD_BREAK_BEFORE[i]} in
                1) print_divider "$MID_LEFT" "$MID_MID" "$MID_RIGHT" ;;
                2) print_dashed_divider ;;
            esac
        fi
        printf '%s\n' "${field_lines[i]}"
    done

    # 页脚跨两列：上方竖线用 ┴ 结束，底边使用连续横线。
    print_divider "$MID_LEFT" "$BOTTOM_MID" "$MID_RIGHT"
    printf '%s\n' \
        "${centered_lines[2]}" \
        "${centered_lines[3]}" \
        "${centered_lines[4]}"
    print_merged_divider "$BOTTOM_LEFT" "$BOTTOM_RIGHT"
}

_profile_begin 'render'
render_report
_profile_end
_profile_total
