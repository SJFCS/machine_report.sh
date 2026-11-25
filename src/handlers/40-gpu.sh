# shellcheck shell=bash
#
# ── [HANDLER] GPU ──────────────────────────────────────────────────────
#
# collect_gpu_rows 输出 TSV：NAME TOTAL_MIB USED_MIB UTIL MIN MAX METRICS。
# 每块 GPU 先加一行型号，有实时指标时再加 MEM / UTIL 两行占位。
#
# 本文件绘制的行：GPU <序号> / GPU <序号> MEM / GPU <序号> UTIL

handler_gpu() {
    local gpu_name='' gpu_total='' gpu_used='' gpu_util=''
    local gpu_min_mhz='' gpu_max_mhz='' gpu_metrics=''
    local gpu_break=0 gpu_identity='' gpu_freq='' gpu_index=0

    GPU_RECORDS=()
    GPU_MEM_ROWS=()
    GPU_UTIL_ROWS=()
    GPU_IDENTITY_LINES=()

    _profile_begin 'gpu'
    while IFS=$'\t' read -r gpu_name gpu_total gpu_used gpu_util \
        gpu_min_mhz gpu_max_mhz gpu_metrics; do
        [ -n "$gpu_name" ] || continue
        gpu_break=0
        [ "$gpu_index" -eq 0 ] && gpu_break=1
        [ "$gpu_index" -gt 0 ] && gpu_break=2
        gpu_identity=$gpu_name
        if [[ $gpu_total =~ ^[0-9]+$ ]] && (( gpu_total > 0 )); then
            gpu_identity="$gpu_identity · $(format_mib_as_gib "$gpu_total") GiB"
        fi
        gpu_freq=$(format_gpu_frequency "$gpu_min_mhz" "$gpu_max_mhz")
        [ "$gpu_freq" = '-' ] || gpu_identity="$gpu_identity · $gpu_freq"
        GPU_IDENTITY_LINES+=("$gpu_identity")
        mr_field "GPU $gpu_index" "$gpu_identity" "$gpu_break"
        if [ "$gpu_metrics" = 1 ]; then
            mr_field "GPU $gpu_index MEM" ''
            GPU_MEM_ROWS+=("$FIELD_INDEX")
            mr_field "GPU $gpu_index UTIL" ''
            GPU_UTIL_ROWS+=("$FIELD_INDEX")
            GPU_RECORDS+=(
                "$gpu_used"$'\t'"$gpu_total"$'\t'"$gpu_util"
            )
        fi
        gpu_index=$((gpu_index + 1))
    done < <(collect_gpu_rows)
    if [ "$gpu_index" -eq 0 ]; then
        mr_field_break 'GPU' '-'
    fi
    _profile_end
}

# 型号行不截断：只有 DATA_W 被上限截断时才需要额外撑宽。
handler_gpu_measure() {
    local line
    (( ${#GPU_IDENTITY_LINES[@]} > 0 )) || return 0
    (( DATA_W >= DATA_MAX )) || return 0
    for line in "${GPU_IDENTITY_LINES[@]}"; do
        ensure_data_width "$line"
    done
}

handler_gpu_fill() {
    local i gpu_used='' gpu_total='' gpu_util='' cell

    for i in "${!GPU_RECORDS[@]}"; do
        IFS=$'\t' read -r gpu_used gpu_total gpu_util <<<"${GPU_RECORDS[i]}"
        _gpu_memory_display_into cell "$gpu_used" "$gpu_total"
        mr_update "${GPU_MEM_ROWS[i]}" "$cell"
        _gpu_util_display_into cell "$gpu_util"
        mr_update "${GPU_UTIL_ROWS[i]}" "$cell"
    done
}

mr_register gpu
