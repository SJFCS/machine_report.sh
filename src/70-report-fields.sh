# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
#
# ── [REPORT] 静态字段组装 ──────────────────────────────────────────────

# 按最终显示顺序组装字段。LOAD、GPU 和内存条形图先留空，测量列宽后再填。
add_field 'OS'          "$os_name"
add_field 'KERNEL'      "$kernel_summary"
add_field 'VIRT'        "$virt_type"
add_field 'LOCALE'      "$locale_name"
add_field 'TIMEZONE'    "$timezone_name"
add_field 'SERVER'      "${server_manufacturer} · ${server_product_name}"
add_field 'SYSTEM UUID' "$system_uuid"
add_field 'UPTIME'      "$uptime"
add_field 'HOSTNAME'    "$hostname"     1
_profile_begin 'network'
dns_servers=$(collect_dns_servers)
add_field 'DNS' "${dns_servers:--}"
primary_ip=''
while IFS=$'\t' read -r nic_name nic_ip; do
    [ -n "$nic_name" ] || continue
    [ -n "$primary_ip" ] || primary_ip=$nic_ip
    add_field "NIC $nic_name" "$nic_ip"
done < <(collect_network_interfaces)
if [ -z "$primary_ip" ]; then
    add_field 'NIC' '-'
    primary_ip='UNKNOWN'
fi
_profile_end
server_display="${C_K}SERVER${C_RESET} ${C_V}${login_user}@${hostname} ${primary_ip}${C_RESET}"
client_display="${C_MUTED}CLIENT ${login_client}${C_RESET}"
for i in "${!cpu_models[@]}"; do
    break_before=0
    [ "$i" -eq 0 ] && break_before=1
    model=$(pad_display "${cpu_models[i]}" "$cpu_model_width")
    add_field "CPU $i" "$model · ${cpu_freqs[i]}" "$break_before"
done
add_field 'CORES'       "$cores"
add_field 'LOAD 1m'     ''              # 条形图在下面计算后填入
LOAD_1M_ROW=$FIELD_INDEX
add_field 'LOAD 5m'     ''
LOAD_5M_ROW=$FIELD_INDEX
add_field 'LOAD 15m'    ''
LOAD_15M_ROW=$FIELD_INDEX

# GPU 按实际数量逐块展开；MEM、UTIL 条形图留到列宽确定后再填充。
GPU_RECORDS=()
GPU_MEM_ROWS=()
GPU_UTIL_ROWS=()
GPU_IDENTITY_LINES=()
gpu_index=0
_profile_begin 'gpu'
while IFS=$'\t' read -r gpu_name gpu_total gpu_used gpu_util \
    gpu_min_mhz gpu_max_mhz gpu_metrics; do
    [ -n "$gpu_name" ] || continue
    gpu_break=0
    [ "$gpu_index" -eq 0 ] && gpu_break=1
    gpu_identity=$gpu_name
    if [[ $gpu_total =~ ^[0-9]+$ ]] && (( gpu_total > 0 )); then
        gpu_identity="$gpu_identity · $(format_mib_as_gib "$gpu_total") GiB"
    fi
    gpu_freq=$(format_gpu_frequency "$gpu_min_mhz" "$gpu_max_mhz")
    [ "$gpu_freq" = '-' ] || gpu_identity="$gpu_identity · $gpu_freq"
    GPU_IDENTITY_LINES+=("$gpu_identity")
    add_field "GPU $gpu_index" "$gpu_identity" "$gpu_break"
    if [ "$gpu_metrics" = 1 ]; then
        add_field "GPU $gpu_index MEM" ''
        GPU_MEM_ROWS+=("$FIELD_INDEX")
        add_field "GPU $gpu_index UTIL" ''
        GPU_UTIL_ROWS+=("$FIELD_INDEX")
        GPU_RECORDS+=(
            "$gpu_used"$'\t'"$gpu_total"$'\t'"$gpu_util"
        )
    fi
    gpu_index=$((gpu_index + 1))
done < <(collect_gpu_rows)
if [ "$gpu_index" -eq 0 ]; then
    add_field 'GPU' '-' 1
fi
_profile_end

# 内存区：TOTAL 带健康状态，其余行在第二轮补百分比。
add_field 'MEM TOTAL'   "$total_display" 1
MEM_TOTAL_ROW=$FIELD_INDEX
add_field 'MEM USAGE'   ''              # 分段堆叠条在下面计算后填入
MEM_BAR_ROW=$FIELD_INDEX
add_field 'MEM USED'    "$used_display"
MEM_USED_ROW=$FIELD_INDEX
add_field 'BUFF/CACHE'  "$cache_display"
MEM_CACHE_ROW=$FIELD_INDEX
add_field 'MEM FREE'    "$free_display"
MEM_FREE_ROW=$FIELD_INDEX
add_field 'MEM SHARED'  "$shared_display"
MEM_SHARED_ROW=$FIELD_INDEX
add_field 'MEM AVAILABLE' "$available_display"
MEM_AVAILABLE_ROW=$FIELD_INDEX

# 磁盘区先收集原始记录，再统一计算三列宽度，避免每块磁盘各算一次。
DISK_BAR_ROWS=()
DISK_BAR_PCTS=()
DISK_DEVICE_ROWS=()
DISK_SPACE_ROWS=()
DISK_MOUNTS=()
DISK_PCTS=()
DISK_HEALTH=()
DISK_WEAR=()
DISK_ERR_LABELS=()
DISK_ERR_COUNTS=()
DISK_CELL_WIDTHS=()
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

# [TABLE] format_disk_columns C1 C2 C3 -> 使用 DISK_COL*_W 补齐后拼接。
# 用法：line=$(format_disk_columns "DISK $name" "TYPE $media" "FORMAT $fmt")
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
# 一次批量测量所有单元格，行循环里直接复用宽度，避免每个单元格起 Perl。
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
        add_field 'DEVICE' "$colored_dev" "$disk_break"
        _color_kv_segments_into colored_space "$space_line"
        add_field 'SPACE' "$colored_space"
        if is_number "${DISK_PCTS[i]}"; then
            add_field 'DISK USAGE' ''
            DISK_BAR_ROWS+=("$FIELD_INDEX")
            DISK_BAR_PCTS+=("${DISK_PCTS[i]}")
        else
            add_field 'DISK USAGE' '-'
        fi
        add_field 'MOUNTS' "${DISK_MOUNTS[i]}"
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
        add_field 'SMART' "$colored_smart"
    done
else
    _color_kv_segments_into colored_empty 'DISK - · TYPE - · FORMAT -'
    add_field 'DEVICE' "$colored_empty" 1
    _color_kv_segments_into colored_empty 'TOTAL - · USED - · AVAIL -'
    add_field 'SPACE' "$colored_empty"
    add_field 'MOUNTS' '-'
    _color_kv_segments_into colored_empty 'HEALTH N/A · WEAR - · INTEG -'
    add_field 'SMART' "$colored_empty"
fi
_profile_end

