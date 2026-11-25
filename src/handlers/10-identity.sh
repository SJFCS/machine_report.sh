# shellcheck shell=bash
# shellcheck disable=SC2154
#
# ── [HANDLER] 身份与系统基本信息 ───────────────────────────────────────
#
# 数据在 main 的 collect 阶段准备好（os_name / kernel_summary / virt_type /
# locale_name / timezone_name / server_manufacturer / server_product_name /
# system_uuid / uptime / hostname），这里只负责排版成字段行。
#
# 本文件绘制的行（注释掉对应的 mr_field 就不显示）：
#   OS / KERNEL / VIRT / LOCALE / TIMEZONE / NTP / SERVER / SYSTEM UUID / UPTIME
#   HOSTNAME（另起一组）

ntp_status_display() {
    case ${1-} in
        SYNCED)   printf '%s● SYNCED%s' "$C_OK" "$C_RESET" ;;
        UNSYNCED) printf '%s● UNSYNCED%s' "$C_CRIT" "$C_RESET" ;;
        DISABLED) printf '%s● DISABLED%s' "$C_WARN" "$C_RESET" ;;
        *)        printf '%s● UNKNOWN%s' "$C_MUTED" "$C_RESET" ;;
    esac
}

handler_identity() {
    mr_field        'SERVER'      "${server_manufacturer} · ${server_product_name}"
    mr_field        'SYSTEM UUID' "$system_uuid"    
    mr_field        'ARCH'        "${server_arch}"    
    mr_field        'VIRT'        "$virt_type"
    mr_field_break  'OS'          "$os_name"
    mr_field        'KERNEL'      "$kernel_summary"    
    mr_field        'LOCALE'      "$locale_name"
    mr_field        'TIMEZONE'    "$timezone_name"
    mr_field        'UPTIME'      "$uptime"
    mr_field_break  'NTP STATUS'  "$(ntp_status_display "$ntp_status")"
    mr_field        'NTP SERVER'  "${ntp_server:--}"
    mr_field        'NTP OFFSET'  "${ntp_offset:--}"
}

mr_register identity
