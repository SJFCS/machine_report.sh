# shellcheck shell=bash
#
# ── [HANDLER] CPU 与负载 ───────────────────────────────────────────────
#
# CPU 型号、核数和负载由 sources/system.sh 在 collect 阶段采集。
# 负载条依赖列宽，所以先占位，等 handler_compute_fill 再回填。

handler_compute() {
    local i model break_before

    for i in "${!cpu_models[@]}"; do
        break_before=0
        [ "$i" -eq 0 ] && break_before=1
        model=$(pad_display "${cpu_models[i]}" "$cpu_model_width")
        mr_field "CPU $i" "$model · ${cpu_freqs[i]}" "$break_before"
    done
    mr_field 'CORES' "$cores"

    mr_field 'LOAD 1m' ''
    LOAD_1M_ROW=$FIELD_INDEX
    mr_field 'LOAD 5m' ''
    LOAD_5M_ROW=$FIELD_INDEX
    mr_field 'LOAD 15m' ''
    LOAD_15M_ROW=$FIELD_INDEX
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
