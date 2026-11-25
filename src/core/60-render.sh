# shellcheck shell=bash
# shellcheck disable=SC2154
#
# ── [CORE] 最终渲染 ────────────────────────────────────────────────────

# [REPORT] render_report -> 渲染封面、字段行和页脚。
# 封面来自 MR_COVER_LINES，页脚来自 MR_FOOTER_LINES（见 handlers/00-cover.sh
# 和 20-network.sh）；数组里没有内容时对应位置不会输出。
# 前置条件：字段已组装、measure_fields 已执行、动态值已回填。
# 用法：render_report
render_report() {
    local line i cover_count footer_count dummy=0
    local -a centered_lines=()
    local -a field_lines=()
    local -a centered_texts=()

    cover_count=${#MR_COVER_LINES[@]}
    footer_count=${#MR_FOOTER_LINES[@]}
    if (( cover_count > 0 )); then
        centered_texts+=("${MR_COVER_LINES[@]}")
    fi
    if (( footer_count > 0 )); then
        centered_texts+=("${MR_FOOTER_LINES[@]}")
    fi
    # 一行居中文字都没有时给 Perl 一个占位符，输出阶段会跳过它。
    if (( ${#centered_texts[@]} == 0 )); then
        centered_texts=('')
        dummy=1
    fi

    # 封面、页脚和所有字段行合并到一个 Perl 进程。
    while IFS= read -r -d '' line; do
        case ${line:0:1} in
            C) centered_lines+=("${line:1}") ;;
            R) field_lines+=("${line:1}") ;;
        esac
    done < <(_format_report_lines "${centered_texts[@]}")
    (( dummy == 0 )) || centered_lines=()

    print_header
    for ((i = 0; i < cover_count; i++)); do
        [ -n "${MR_COVER_LINES[i]}" ] || continue
        printf '%s\n' "${centered_lines[i]}"
    done
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
    for ((i = 0; i < footer_count; i++)); do
        [ -n "${MR_FOOTER_LINES[i]}" ] || continue
        printf '%s\n' "${centered_lines[cover_count + i]}"
    done
    print_merged_divider "$BOTTOM_LEFT" "$BOTTOM_RIGHT"
}

