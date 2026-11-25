# shellcheck shell=bash
#
# ── [HANDLER] 身份与系统基本信息 ───────────────────────────────────────
#
# 数据在 main 的 collect 阶段准备好（os_name / kernel_summary / virt_type /
# locale_name / timezone_name / server_manufacturer / server_product_name /
# system_uuid / uptime / hostname），这里只负责排版成字段行。
#
# 本文件绘制的行（注释掉对应的 mr_field 就不显示）：
#   OS / KERNEL / VIRT / LOCALE / TIMEZONE / SERVER / SYSTEM UUID / UPTIME
#   HOSTNAME（另起一组）

handler_identity() {
    mr_field   'OS'          "$os_name"
    mr_field   'KERNEL'      "$kernel_summary"
    mr_field   'VIRT'        "$virt_type"
    mr_field   'LOCALE'      "$locale_name"
    mr_field   'TIMEZONE'    "$timezone_name"
    mr_field   'SERVER'      "${server_manufacturer} · ${server_product_name}"
    mr_field   'SYSTEM UUID' "$system_uuid"
    mr_field   'UPTIME'      "$uptime"
    mr_field_break 'HOSTNAME' "$hostname"
}

mr_register identity
