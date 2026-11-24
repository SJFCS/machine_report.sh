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
server_display="${C_K}SERVER${C_RESET} ${C_V}${login_user}@${hostname}·${primary_ip}${C_RESET}"
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
while IFS=$'\t' read -r gpu_name gpu_total gpu_used gpu_util \
    gpu_min_mhz gpu_max_mhz; do
    [ -n "$gpu_name" ] || continue
    gpu_break=0
    [ "$gpu_index" -eq 0 ] && gpu_break=1
    gpu_total_gib=$(format_mib_as_gib "$gpu_total")
    gpu_freq=$(format_gpu_frequency "$gpu_min_mhz" "$gpu_max_mhz")
    gpu_identity="${gpu_name} · ${gpu_total_gib} GiB · ${gpu_freq}"
    GPU_IDENTITY_LINES+=("$gpu_identity")
    add_field "GPU $gpu_index" "$gpu_identity" "$gpu_break"
    add_field "GPU $gpu_index MEM" ''
    GPU_MEM_ROWS+=("$FIELD_INDEX")
    add_field "GPU $gpu_index UTIL" ''
    GPU_UTIL_ROWS+=("$FIELD_INDEX")
    GPU_RECORDS+=(
        "$gpu_used"$'\t'"$gpu_total"$'\t'"$gpu_util"
    )
    gpu_index=$((gpu_index + 1))
done < <(collect_gpu_rows)
if [ "${#GPU_RECORDS[@]}" -eq 0 ]; then
    add_field 'GPU' '-' 1
fi

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
while IFS=$'\t' read -r disk_name disk_size disk_media disk_mounts \
    disk_pct disk_used disk_avail disk_format; do
    [ -n "$disk_name" ] || continue
    DISK_DEVICE_ROWS+=(
        "DISK $disk_name"$'\t'"TYPE $disk_media"$'\t'"FORMAT ${disk_format//,/, }"
    )
    DISK_SPACE_ROWS+=(
        "TOTAL $disk_size"$'\t'"USED $disk_used"$'\t'"AVAIL $disk_avail"
    )
    DISK_MOUNTS+=("${disk_mounts//,/, }")
    DISK_BAR_PCTS+=("$disk_pct")
done < <(physical_disk_rows)

# [TABLE] format_disk_columns C1 C2 C3 -> 使用 DISK_COL*_W 补齐后拼接。
# 用法：line=$(format_disk_columns "DISK $name" "TYPE $media" "FORMAT $fmt")
format_disk_columns() {
    printf '%s · %s · %s' \
        "$(pad_display "$1" "$DISK_COL1_W")" \
        "$(pad_display "$2" "$DISK_COL2_W")" \
        "$(pad_display "$3" "$DISK_COL3_W")"
}

# 三列宽度由 DEVICE 和 SPACE 两类记录共同决定，保证上下两行用同一组
# 分隔符位置。记录内部使用 TAB，因此挂载点或型号中的空格不会干扰分列。
if [ "${#DISK_DEVICE_ROWS[@]}" -gt 0 ]; then
    DISK_COL1_W=$(max_tsv_column_width 0 \
        "${DISK_DEVICE_ROWS[@]}" "${DISK_SPACE_ROWS[@]}")
    DISK_COL2_W=$(max_tsv_column_width 1 \
        "${DISK_DEVICE_ROWS[@]}" "${DISK_SPACE_ROWS[@]}")
    DISK_COL3_W=$(max_tsv_column_width 2 \
        "${DISK_DEVICE_ROWS[@]}" "${DISK_SPACE_ROWS[@]}")

    for i in "${!DISK_DEVICE_ROWS[@]}"; do
        IFS=$'\t' read -r dev_a dev_b dev_c <<<"${DISK_DEVICE_ROWS[i]}"
        IFS=$'\t' read -r sp_a sp_b sp_c <<<"${DISK_SPACE_ROWS[i]}"
        dev_line=$(format_disk_columns "$dev_a" "$dev_b" "$dev_c")
        space_line=$(format_disk_columns "$sp_a" "$sp_b" "$sp_c")
        disk_break=1
        [ "$i" -gt 0 ] && disk_break=2
        add_field 'DEVICE' \
            "$(color_kv_segments "$dev_line")" "$disk_break"
        add_field 'SPACE' \
            "$(color_kv_segments "$space_line")"
        if is_number "${DISK_BAR_PCTS[i]}"; then
            add_field 'DISK USAGE' ''
            DISK_BAR_ROWS+=("$FIELD_INDEX")
        else
            add_field 'DISK USAGE' '-'
        fi
        add_field 'MOUNTS' "${DISK_MOUNTS[i]}"
    done
else
    add_field 'DEVICE' \
        "$(color_kv_segments 'DISK - · TYPE - · FORMAT -')" 1
    add_field 'SPACE' \
        "$(color_kv_segments 'TOTAL - · USED - · AVAIL -')"
    add_field 'MOUNTS' '-'
fi

