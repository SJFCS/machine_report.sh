# shellcheck shell=bash
# shellcheck disable=SC2154
#
# ── [HANDLER] CPU 与负载 ───────────────────────────────────────────────
#
# CPU 型号、核数和负载由 sources/system.sh 在 collect 阶段采集。
# 负载条依赖列宽，所以先占位，等 handler_compute_fill 再回填。
#
# 本文件绘制的行：SUM CORES、LOAD 1m/5m/15m、Socket/CPU 分组行

handler_compute() {
    local i model label value break_before

    mr_field "${cpu_summary_label:-CORES}" "$cores" 1

    mr_field 'LOAD 1m' ''
    LOAD_1M_ROW=$FIELD_INDEX
    mr_field 'LOAD 5m' ''
    LOAD_5M_ROW=$FIELD_INDEX
    mr_field 'LOAD 15m' ''
    LOAD_15M_ROW=$FIELD_INDEX

    for i in "${!cpu_models[@]}"; do
        break_before=0
        [ "$i" -eq 0 ] && break_before=1
        [ "$i" -gt 0 ] && [ -n "${cpu_models[i]}" ] && break_before=2
        if (( i < ${#cpu_labels[@]} )); then
            label=${cpu_labels[i]}
        else
            label="CPU $i"
        fi
        if [ -n "${cpu_models[i]}" ]; then
            model=$(pad_display "${cpu_models[i]}" "$cpu_model_width")
            value="$model · ${cpu_freqs[i]}"
        else
            value=${cpu_freqs[i]}
        fi
        mr_field "$label" "$value" "$break_before"
    done
}

handler_compute_fill() {
    local cell

    _load_display_into cell "$load1" "$cpu_cores"
    mr_update "$LOAD_1M_ROW" "$cell"
    _load_display_into cell "$load5" "$cpu_cores"
    mr_update "$LOAD_5M_ROW" "$cell"
    _load_display_into cell "$load15" "$cpu_cores"
    mr_update "$LOAD_15M_ROW" "$cell"
}

mr_register compute
