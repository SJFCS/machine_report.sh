# shellcheck shell=bash
#
# 本文件绘制的行：EXAMPLE / EXAMPLE BAR

handler_mything() {
    mr_field_break 'EXAMPLE' 'hello'   # 实线：从这里开始新的一组

    # 同一组的后续条目：虚线分隔
    mr_field_dashed 'EXAMPLE 2' "$(date '+%Y-%m-%d %H:%M:%S')"

    mr_field 'EXAMPLE BAR' ''
    MY_BAR_ROW=$FIELD_INDEX            # 先占位，等列宽确定
    
    mr_field_break 'EXAMPLE' 'hello2'   # 实线：从这里开始新的一组

}

handler_mything_fill() {
    mr_update "$MY_BAR_ROW" "$(mr_bar 42 100)"
}

mr_register mything



handler_backup() {
    mr_field_break 'BACKUP' 'rsync · nightly'
    mr_field 'LAST RUN' '2026-11-25 03:00'
}

mr_register backup

handler_misc() {
    mr_field 'SHELL' "${SHELL##*/}"
    mr_field 'TERM' "${TERM:-unknown}"
}

mr_register misc

handler_ports() {
    local line first=1
    while IFS=$'\t' read -r name state; do
        if (( first )); then
            mr_field_break "PORT $name" "$state"
            first=0
        else
            mr_field_dashed "PORT $name" "$state"
        fi
    done < <(printf '22\tlisten\n80\tlisten\n443\tlisten\n')
}

mr_register ports

handler_diskfree() {
    mr_field_break 'DISK FREE' ''
    DISK_FREE_ROW=$FIELD_INDEX
}

handler_diskfree_fill() {
    local free=58 total=100
    mr_update "$DISK_FREE_ROW" "$(mr_bar "$free" "$total")"          # 占满 DATA_W
    # mr_update "$DISK_FREE_ROW" "$(mr_percent_bar 58 100 58.0)"
    # 也可以固定宽度：mr_bar "$free" "$total" 20
}

mr_register diskfree

handler_extras() {
    local uptime_text
    uptime_text=$(uptime 2>/dev/null)

    mr_field_break 'UPTIME RAW' "$(mr_fit "$uptime_text" 40)"
    mr_field 'STATUS' "${C_OK}OK${C_RESET}"
    mr_field 'WIDTH' "1 个中文 = $(mr_width 中) 列"
}

mr_register extras