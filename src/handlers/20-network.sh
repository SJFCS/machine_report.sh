# shellcheck shell=bash
#
# ── [HANDLER] DNS 与网卡 ───────────────────────────────────────────────
#
# 采集和展示放在一起：这个 handler 自己调用 collect_dns_servers /
# collect_network_interfaces，再把结果交给 mr_field。
# 页脚的 SERVER/CLIENT 行也在这里生成，因为它们依赖主 IP 和登录信息。

handler_network() {
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

    server_display="${C_K}SERVER${C_RESET} ${C_V}${login_user}@${hostname} ${primary_ip}${C_RESET}"
    client_display="${C_MUTED}CLIENT ${login_client}${C_RESET}"
}

# 页脚是跨列文本，列宽测量后要保证放得下。
handler_network_measure() {
    ensure_centered_width "$server_display"
    ensure_centered_width "$client_display"
}

mr_register network
