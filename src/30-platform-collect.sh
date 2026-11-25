# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
#
# ── 平台与 DMI 探测 ────────────────────────────────────────────────────

# [HANDLER] dmi_field KEY SYSFS_PATH -> 读取 DMI 字段纯文本。
# 优先 sysfs，其次 dmidecode；失败时返回空串，由调用方决定回退值。
# 用法：vendor=$(dmi_field system-manufacturer /sys/class/dmi/id/sys_vendor)
dmi_field() {
    local key=$1 path=$2
    if [ -r "$path" ]; then
        cat "$path"
    elif command -v dmidecode >/dev/null 2>&1; then
        dmidecode -s "$key" 2>/dev/null | tr -d '\r'
    fi
}

# [HANDLER] darwin_field KEY -> 读取 ioreg 中的平台字段。
# 用法：model=$(darwin_field model)
darwin_field() {
    local raw=${DARWIN_PLATFORM_RAW:-} line value
    local prefix="\"${1-}\" = "
    if [ -z "$raw" ]; then
        raw=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null)
    fi
    # 只用内建字符串处理解析，不再为每个字段起一次 awk。
    while IFS= read -r line; do
        case $line in
            *"$prefix"*) ;;
            *) continue ;;
        esac
        value=${line#*"$prefix"}
        value=${value#<}
        value=${value%>}
        value=${value#\"}
        value=${value%\"}
        printf '%s\n' "$value"
        return 0
    done <<<"$raw"
}

# [HANDLER] detect_manufacturer -> 输出服务器厂商；未知时为 UNKNOWN。
# 用法：vendor=$(detect_manufacturer)
detect_manufacturer() {
    local manufacturer
    manufacturer=$(dmi_field \
        system-manufacturer /sys/class/dmi/id/sys_vendor)
    if [ -z "$manufacturer" ] && [ "$platform_name" = Darwin ]; then
        manufacturer=$(darwin_field manufacturer)
    fi
    [ -n "$manufacturer" ] || manufacturer=UNKNOWN
    printf '%s' "$manufacturer"
}

# [HANDLER] detect_product_name -> 输出产品型号；未知时为 UNKNOWN。
# 用法：product=$(detect_product_name)
detect_product_name() {
    local product
    product=$(dmi_field system-product-name /sys/class/dmi/id/product_name)
    if [ -z "$product" ] && [ "$platform_name" = Darwin ]; then
        product=$(darwin_field model)
    fi
    [ -n "$product" ] || product=UNKNOWN
    printf '%s' "$product"
}

# [HANDLER] detect_virtualization -> 输出 KVM/VMWARE/BARE METAL 等类型。
# 无法识别时沿用 BARE METAL 回退值，不等同于已确认是裸机。
# 用法：virt=$(detect_virtualization)
detect_virtualization() {
    local virt='' vendor='' manufacturer='' product=''

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null)
        case $virt in
            ''|none) ;;
            *) printf '%s' "$virt" | tr '[:lower:]' '[:upper:]'; return ;;
        esac
    fi

    if [ -n "${lscpu_output:-}" ]; then
        local key value
        while IFS=: read -r key value; do
            key=${key//[[:space:]]/}
            if [[ $key == Hypervisorvendor ]]; then
                vendor=${value#"${value%%[![:space:]]*}"}
                vendor=${vendor%"${vendor##*[![:space:]]}"}
                break
            fi
        done <<<"$lscpu_output"
        if [ -n "$vendor" ]; then
            printf '%s' "$vendor" | tr '[:lower:]' '[:upper:]'
            return
        fi
    fi

    manufacturer=$(dmi_field system-manufacturer /sys/class/dmi/id/sys_vendor)
    product=$(dmi_field system-product-name /sys/class/dmi/id/product_name)
    product="${manufacturer:+$manufacturer }$product"
    case $product in
        *KVM*|*QEMU*|*Bochs*) printf 'KVM' ;;
        *VMware*) printf 'VMWARE' ;;
        *VirtualBox*|*innotek*) printf 'VIRTUALBOX' ;;
        *Microsoft*|*Hyper-V*) printf 'HYPER-V' ;;
        *Xen*) printf 'XEN' ;;
        *Amazon*) printf 'AWS' ;;
        *Google*) printf 'GCE' ;;
        # 无法识别时沿用演示默认值；这个结果不代表已经确认是裸机。
        *) printf 'BARE METAL' ;;
    esac
}

# [HANDLER] detect_system_uuid -> 输出小写 UUID；无效值统一为 UNKNOWN。
# 用法：uuid=$(detect_system_uuid)
# ── [HANDLER] 身份、Locale 与登录会话 ─────────────────────────────────

detect_system_uuid() {
    local uuid
    uuid=$(dmi_field system-uuid /sys/class/dmi/id/product_uuid)
    if [ -z "$uuid" ] && [ "$platform_name" = Darwin ]; then
        uuid=$(darwin_field IOPlatformUUID)
    fi
    uuid=$(printf '%s' "$uuid" | tr '[:upper:]' '[:lower:]')
    case $uuid in
        ''|'not settable'|'not present'|\
        00000000-0000-0000-0000-000000000000|\
        03000200-0400-0500-0006-000700080009)
            printf 'UNKNOWN'
            ;;
        *) printf '%s' "$uuid" ;;
    esac
}


# [HANDLER] detect_locale -> 输出当前有效 Locale。
# 优先级：LC_ALL > LC_CTYPE > LANG。
# 用法：locale_name=$(detect_locale)
detect_locale() {
    local value=${LC_ALL:-}
    [ -n "$value" ] || value=${LC_CTYPE:-}
    [ -n "$value" ] || value=${LANG:-}
    [ -n "$value" ] || value='UNKNOWN'
    printf '%s' "$value"
}

# [HANDLER] detect_timezone -> 输出 Asia/Shanghai 等 IANA 时区名。
# 来源优先级：TZ > timedatectl > /etc/timezone > /etc/localtime 链接。
# 用法：tz=$(detect_timezone)
detect_timezone() {
    local value=${TZ:-} link
    if [ -z "$value" ] && command -v timedatectl >/dev/null 2>&1; then
        value=$(timedatectl show -p Timezone --value 2>/dev/null)
    fi
    if [ -z "$value" ] && [ -r /etc/timezone ]; then
        value=$(sed -n '1p' /etc/timezone 2>/dev/null)
    fi
    if [ -z "$value" ] && [ -L /etc/localtime ]; then
        link=$(readlink /etc/localtime 2>/dev/null)
        case $link in
            */zoneinfo/*) value=${link#*/zoneinfo/} ;;
        esac
    fi
    [ -n "$value" ] || value='UNKNOWN'
    printf '%s' "$value"
}

# [HANDLER] login_who_line -> `who am i` 的本次运行首次输出。
# 用户和客户端都来自同一行，取一次即可，避免 session 阶段跑两次 who。
login_who_line() {
    if [ -z "${LOGIN_WHO_AM_I_LOADED:-}" ]; then
        LOGIN_WHO_AM_I=$(who am i 2>/dev/null)
        LOGIN_WHO_AM_I_LOADED=1
    fi
    printf '%s' "$LOGIN_WHO_AM_I"
}

# [HANDLER] detect_login_user -> 当前登录用户，who 为空时回退环境变量。
# 用法：user=$(detect_login_user)
detect_login_user() {
    local user=''
    read -r user _ <<<"$(login_who_line)" || true
    [ -n "$user" ] || user=${USER:-$(id -un)}
    printf '%s' "$user"
}

# [HANDLER] detect_login_client -> SSH 客户端 IP 或本地标记 local。
# 用法：client=$(detect_login_client)
detect_login_client() {
    local client='' line
    if [ -n "${SSH_CLIENT:-}" ]; then
        client=${SSH_CLIENT%% *}
    elif [ -n "${SSH_CONNECTION:-}" ]; then
        client=${SSH_CONNECTION%% *}
    else
        line=$(login_who_line)
        if [[ $line == *'('*')'* ]]; then
            client=${line##*\(}
            client=${client%%)*}
        fi
    fi
    [ -n "$client" ] || client=local
    printf '%s' "$client"
}

# ── [HANDLER] 网卡 ─────────────────────────────────────────────────────

# [HANDLER] collect_network_interfaces -> 输出 IFACE<TAB>IPv4。
# 过滤回环、容器和虚拟隧道接口。
# 用法：while IFS=$'\t' read -r iface ip; do ...; done < <(collect_network_interfaces)
collect_network_interfaces() {
    local iface state address rest

    # macOS 默认没有 ip；Homebrew 的 iproute2mac 单次约 40 ms，
    # 而系统自带 ifconfig 通常只要几毫秒。这里优先用 ifconfig，
    # 并保持与下面 ip 分支相同的接口过滤规则。
    if [ "$platform_name" = Darwin ] &&
        command -v ifconfig >/dev/null 2>&1; then
        LC_ALL=C ifconfig 2>/dev/null | awk '
            /^[A-Za-z0-9_.-]+:/ {
                iface = $1
                sub(/:$/, "", iface)
            }
            $1 == "inet" && $2 != "" && $2 != "127.0.0.1" {
                if (iface ~ /^(lo|docker|virbr|veth|br-|cni|flannel|cali|kube|tun|tap)/)
                    next
                print iface "\t" $2
            }
        '
        return
    fi

    if command -v ip >/dev/null 2>&1; then
        while read -r iface state address rest; do
            [ -n "$iface" ] || continue
            case $iface in
                lo*|docker*|virbr*|veth*|br-*|cni*|flannel*|cali*|\
                kube*|tun*|tap*) continue ;;
            esac
            [ -n "$address" ] || continue
            printf '%s\t%s\n' "$iface" "${address%%/*}"
        done < <(LC_ALL=C ip -4 -br addr 2>/dev/null)
    fi
}

# [HANDLER] collect_dns_servers -> 去重后以逗号分隔的 DNS 服务器地址。
collect_dns_servers() {
    local dns=''
    if [ "$platform_name" = Darwin ] &&
        command -v scutil >/dev/null 2>&1; then
        dns=$(scutil --dns 2>/dev/null |
            awk '/nameserver\[[0-9]+\]/ { print $3 }')
    fi
    if [ -z "$dns" ] && command -v resolvectl >/dev/null 2>&1; then
        dns=$(resolvectl dns 2>/dev/null | awk '
            {
                sub(/^[^:]*:[[:space:]]*/, "")
                for (i = 1; i <= NF; i++)
                    if ($i ~ /^[0-9A-Fa-f:.]+(%[^ ]+)?$/) print $i
            }
        ')
    fi
    if [ -z "$dns" ] && [ -r /etc/resolv.conf ]; then
        dns=$(awk '$1 == "nameserver" && NF >= 2 { print $2 }' \
            /etc/resolv.conf)
    fi
    printf '%s\n' "$dns" | awk '
        NF && !seen[$1]++ {
            if (out != "") out = out ", "
            out = out $1
        }
        END { if (out != "") print out }
    '
}

_profile_begin 'platform'
if [ "$platform_name" = Darwin ]; then
    # 厂商、型号和 UUID 都会读同一份 IOPlatformExpertDevice；先取一次，
    # 后续 darwin_field 直接复用，避免每个字段都启动一次 ioreg。
    DARWIN_PLATFORM_RAW=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null)
fi
server_manufacturer=$(detect_manufacturer)
server_product_name=$(detect_product_name)
virt_type=$(detect_virtualization)
system_uuid=$(detect_system_uuid)
_profile_end
_profile_begin 'session'
locale_name=$(detect_locale)
timezone_name=$(detect_timezone)
login_user=$(detect_login_user)
login_client=$(detect_login_client)
_profile_end
