# shellcheck shell=bash
#
# ── [HANDLER] 磁盘 ─────────────────────────────────────────────────────
#
# physical_disk_rows 输出 TSV：
#   NAME SIZE MEDIA MOUNTS PCT USED AVAIL FORMAT HEALTH WEAR ERR_LABEL ERR
# 这里把每块盘拆成 DEVICE / SPACE / DISK USAGE / MOUNTS / SMART 五行，
# 三列文本按最宽单元格对齐；使用率条形图等列宽确定后再回填。

DISK_BAR_ROWS=()
DISK_BAR_PCTS=()

# [TABLE] format_disk_columns C1 C2 C3 [W1 W2 W3] -> 三列拼接。
_format_disk_columns_into() {
    local __var=$1 c1=$2 c2=$3 c3=$4
    local w1=${5-} w2=${6-} w3=${7-}
    local p1 p2 p3
    _pad_display_into p1 "$c1" "$DISK_COL1_W" ${w1:+"$w1"}
    _pad_display_into p2 "$c2" "$DISK_COL2_W" ${w2:+"$w2"}
    _pad_display_into p3 "$c3" "$DISK_COL3_W" ${w3:+"$w3"}
    printf -v "$__var" '%s · %s · %s' "$p1" "$p2" "$p3"
}

format_disk_columns() {
    local line
    _format_disk_columns_into line "$@"
    printf '%s' "$line"
}

# 三列宽度由 DEVICE 和 SPACE 两类记录共同决定，保证上下两行用同一组
# 分隔符位置。记录内部使用 TAB，因此挂载点或型号中的空格不会干扰分列。
measure_disk_cell_widths() {
    local i width
    local -a cells=()
    local -a all_cells=()

    DISK_CELL_WIDTHS=()
    for i in "${!DISK_DEVICE_ROWS[@]}"; do
        IFS=$'\t' read -r -a cells <<<"${DISK_DEVICE_ROWS[i]}"
        all_cells+=("${cells[@]}")
        IFS=$'\t' read -r -a cells <<<"${DISK_SPACE_ROWS[i]}"
        all_cells+=("${cells[@]}")
    done
    while IFS= read -r -d '' width; do
        DISK_CELL_WIDTHS+=("$width")
    done < <(_display_widths_batch "${all_cells[@]}")

    DISK_COL1_W=0
    DISK_COL2_W=0
    DISK_COL3_W=0
    for ((i = 0; i + 5 < ${#DISK_CELL_WIDTHS[@]}; i += 6)); do
        width=${DISK_CELL_WIDTHS[i]}
        [[ $width =~ ^[0-9]+$ ]] || width=0
        if (( width > DISK_COL1_W )); then DISK_COL1_W=$width; fi
        width=${DISK_CELL_WIDTHS[i + 1]}
        [[ $width =~ ^[0-9]+$ ]] || width=0
        if (( width > DISK_COL2_W )); then DISK_COL2_W=$width; fi
        width=${DISK_CELL_WIDTHS[i + 2]}
        [[ $width =~ ^[0-9]+$ ]] || width=0
        if (( width > DISK_COL3_W )); then DISK_COL3_W=$width; fi
        width=${DISK_CELL_WIDTHS[i + 3]}
        [[ $width =~ ^[0-9]+$ ]] || width=0
        if (( width > DISK_COL1_W )); then DISK_COL1_W=$width; fi
        width=${DISK_CELL_WIDTHS[i + 4]}
        [[ $width =~ ^[0-9]+$ ]] || width=0
        if (( width > DISK_COL2_W )); then DISK_COL2_W=$width; fi
        width=${DISK_CELL_WIDTHS[i + 5]}
        [[ $width =~ ^[0-9]+$ ]] || width=0
        if (( width > DISK_COL3_W )); then DISK_COL3_W=$width; fi
    done
}

handler_disk() {
    local disk_name='' disk_size='' disk_media='' disk_mounts='' disk_pct=''
    local disk_used='' disk_avail='' disk_format='' disk_health='' disk_wear=''
    local disk_err_label='' disk_err_count=''
    local i base dev_a dev_b dev_c sp_a sp_b sp_c dev_line space_line
    local disk_break colored_dev colored_space colored_smart colored_empty
    local smart_wear smart_err_label smart_err_count

    DISK_DEVICE_ROWS=()
    DISK_SPACE_ROWS=()
    DISK_MOUNTS=()
    DISK_PCTS=()
    DISK_HEALTH=()
    DISK_WEAR=()
    DISK_ERR_LABELS=()
    DISK_ERR_COUNTS=()
    DISK_CELL_WIDTHS=()
    DISK_BAR_ROWS=()
    DISK_BAR_PCTS=()

    _profile_begin 'disk collect'
    while IFS=$'\t' read -r disk_name disk_size disk_media disk_mounts \
        disk_pct disk_used disk_avail disk_format disk_health disk_wear \
        disk_err_label disk_err_count; do
        [ -n "$disk_name" ] || continue
        DISK_DEVICE_ROWS+=(
            "DISK $disk_name"$'\t'"TYPE $disk_media"$'\t'"FORMAT ${disk_format//,/, }"
        )
        DISK_SPACE_ROWS+=(
            "TOTAL $disk_size"$'\t'"USED $disk_used"$'\t'"AVAIL $disk_avail"
        )
        DISK_MOUNTS+=("${disk_mounts//,/, }")
        DISK_PCTS+=("$disk_pct")
        DISK_HEALTH+=("${disk_health:-N/A}")
        DISK_WEAR+=("${disk_wear:--}")
        DISK_ERR_LABELS+=("${disk_err_label:-INTEG}")
        DISK_ERR_COUNTS+=("${disk_err_count:--}")
    done < <(physical_disk_rows)
    _profile_end

    _profile_begin 'disk layout'
    if [ "${#DISK_DEVICE_ROWS[@]}" -gt 0 ]; then
        measure_disk_cell_widths

        for i in "${!DISK_DEVICE_ROWS[@]}"; do
            IFS=$'\t' read -r dev_a dev_b dev_c <<<"${DISK_DEVICE_ROWS[i]}"
            IFS=$'\t' read -r sp_a sp_b sp_c <<<"${DISK_SPACE_ROWS[i]}"
            base=$((i * 6))
            _format_disk_columns_into dev_line "$dev_a" "$dev_b" "$dev_c" \
                "${DISK_CELL_WIDTHS[base]}" \
                "${DISK_CELL_WIDTHS[base + 1]}" \
                "${DISK_CELL_WIDTHS[base + 2]}"
            _format_disk_columns_into space_line "$sp_a" "$sp_b" "$sp_c" \
                "${DISK_CELL_WIDTHS[base + 3]}" \
                "${DISK_CELL_WIDTHS[base + 4]}" \
                "${DISK_CELL_WIDTHS[base + 5]}"
            disk_break=1
            [ "$i" -gt 0 ] && disk_break=2
            _color_kv_segments_into colored_dev "$dev_line"
            mr_field 'DEVICE' "$colored_dev" "$disk_break"
            _color_kv_segments_into colored_space "$space_line"
            mr_field 'SPACE' "$colored_space"
            if is_number "${DISK_PCTS[i]}"; then
                mr_field 'DISK USAGE' ''
                DISK_BAR_ROWS+=("$FIELD_INDEX")
                DISK_BAR_PCTS+=("${DISK_PCTS[i]}")
            else
                mr_field 'DISK USAGE' '-'
            fi
            mr_field 'MOUNTS' "${DISK_MOUNTS[i]}"
            smart_wear=${DISK_WEAR[i]:--}
            case $smart_wear in
                ''|-) smart_wear='-' ;;
                *[!0-9]*) ;;
                *) smart_wear="${smart_wear}%" ;;
            esac
            smart_err_label=${DISK_ERR_LABELS[i]:-INTEG}
            smart_err_count=${DISK_ERR_COUNTS[i]:--}
            printf -v smart_line 'HEALTH %s · WEAR %s · %s %s' \
                "${DISK_HEALTH[i]:-N/A}" "$smart_wear" \
                "$smart_err_label" "$smart_err_count"
            _color_kv_segments_into colored_smart "$smart_line"
            mr_field 'SMART' "$colored_smart"
        done
    else
        _color_kv_segments_into colored_empty 'DISK - · TYPE - · FORMAT -'
        mr_field_break 'DEVICE' "$colored_empty"
        _color_kv_segments_into colored_empty 'TOTAL - · USED - · AVAIL -'
        mr_field 'SPACE' "$colored_empty"
        mr_field 'MOUNTS' '-'
        _color_kv_segments_into colored_empty 'HEALTH N/A · WEAR - · INTEG -'
        mr_field 'SMART' "$colored_empty"
    fi
    _profile_end
}

handler_disk_fill() {
    local i cell
    for i in "${!DISK_BAR_ROWS[@]}"; do
        _disk_usage_display_into cell "${DISK_BAR_PCTS[i]}"
        mr_update "${DISK_BAR_ROWS[i]}" "$cell"
    done
}

mr_register disk
