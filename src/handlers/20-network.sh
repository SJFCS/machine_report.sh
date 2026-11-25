# shellcheck shell=bash
# shellcheck disable=SC2154
#
# ── [HANDLER] DNS 与网卡 ───────────────────────────────────────────────
#
# 采集和展示放在一起：这个 handler 自己调用 collect_dns_servers /
# collect_network_interfaces，再把结果交给 mr_field。
# 页脚的 SERVER/CLIENT 行也在这里生成，因为它们依赖主 IP 和登录信息。
#
# 本文件绘制的行：HOSTNAME / FULL HOSTNAME / DNS /
# 每个网卡一行 NIC <名字> / 页脚 SERVER、CLIENT

handler_network() {
    mr_field_break 'HOSTNAME' "$hostname"
    mr_field 'FULL HOSTNAME' "$full_hostname"

    local nic_name='' nic_ip='' primary_ip=''

    _profile_begin 'network'
    dns_servers=$(collect_dns_servers)
    mr_field 'DNS' "${dns_servers:--}"
    while IFS=$'\t' read -r nic_name nic_ip; do
        [ -n "$nic_name" ] || continue
        [ -n "$primary_ip" ] || primary_ip=$nic_ip
        mr_field "NIC $nic_name" "$nic_ip"
    done < <(collect_network_interfaces)
    if [ -z "$primary_ip" ]; then
        mr_field 'NIC' '-'
        primary_ip='UNKNOWN'
    fi
    _profile_end

    # 页脚两行；不需要就把对应那行注释掉。
    mr_footer_line "${C_K}SERVER${C_RESET} ${C_V}${login_user}@${hostname} ${primary_ip}${C_RESET}"
    mr_footer_line "${C_MUTED}CLIENT ${login_client}${C_RESET}"
}

mr_register network
