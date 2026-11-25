# shellcheck shell=bash
# shellcheck disable=SC2154
#
# ── [CORE] 最终渲染 ────────────────────────────────────────────────────

# [REPORT] render_report -> 渲染标题、字段行和页脚。
# 前置条件：字段已组装、measure_fields 已执行、动态值已回填。
# 用法：render_report
render_report() {
    local title='服务器运行报告'
    local subtitle='PVE Platform'
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

