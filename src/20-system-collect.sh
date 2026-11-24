# shellcheck shell=bash
# shellcheck disable=SC2034
#
# ── 数据源开关与宿主机基础信息 ────────────────────────────────────────
#
# 下面三个数组由 add_field 维护，调用方通常不需要直接操作它们：
#   FIELD_LABELS       左边一列的字段名
#   FIELD_VALUES       右边一列的值
#   FIELD_BREAK_BEFORE 0 不画，1 实线，2 虚线
#
# 先声明空数组再逐行 add_field，字段顺序就是最终显示顺序。这样增加或
# 删除字段时不会出现“只改了标签、忘了改分隔线”的半同步状态。

# [MOCK] 固定标量数据集中在这里，仅在 REPORT_MOCK_ENABLED=1 时加载。
#
# 用法：
#   load_mock_scalars
#   printf '%s\n' "$os_name" "$mem_total"

load_mock_scalars() {
    os_name='Ubuntu 24.04 Noble'
    kernel_version='6.8.0'
    cpu_models=(
        'Intel Xeon Gold 6430'
        'AMD EPYC 9354'
    )
    cpu_freqs=(
        '2.10–3.40 GHz'
        '3.25–3.75 GHz'
    )
    cpu_cores=128
    cpu_sockets=2
    load1='25.60'
    load5='12.80'
    load15='6.40'
    uptime='2h 10m'
    mem_total='16'
    mem_used='13.2'
    mem_cache='9.6'
    mem_free='3.2'
    mem_shared='0.8'
    mem_available='1.4'
}

# 基础平台信息始终来自本机；mock 只覆盖上方标量指标。
platform_name=$(uname -s 2>/dev/null)
[ -n "$platform_name" ] || platform_name=unknown
server_arch=$(uname -m 2>/dev/null)
[ -n "$server_arch" ] || server_arch=unknown

# [HANDLER] detect_os_name -> 本机操作系统展示名称。
detect_os_name() {
    local value='' version=''
    if [ "$platform_name" = Darwin ] &&
        command -v sw_vers >/dev/null 2>&1; then
        value=$(sw_vers -productName 2>/dev/null)
        version=$(sw_vers -productVersion 2>/dev/null)
        printf '%s' "${value:-macOS}${version:+ $version}"
        return
    fi
    if [ -r /etc/os-release ]; then
        value=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null |
            tr -d '"' | head -n 1)
    fi
    [ -n "$value" ] || value=$platform_name
    printf '%s' "$value"
}

# [FORMAT] cpu_frequency_text MIN_MHZ MAX_MHZ -> CPU 静态频率区间。
cpu_frequency_text() {
    local min_mhz=${1:-0} max_mhz=${2:-0} min_ghz max_ghz
    if (( min_mhz > 0 && max_mhz > 0 )); then
        min_ghz=$(awk -v m="$min_mhz" 'BEGIN { printf "%.2f", m / 1000 }')
        max_ghz=$(awk -v m="$max_mhz" 'BEGIN { printf "%.2f", m / 1000 }')
        printf '%s–%s GHz' "$min_ghz" "$max_ghz"
    elif (( max_mhz > 0 )); then
        max_ghz=$(awk -v m="$max_mhz" 'BEGIN { printf "%.2f", m / 1000 }')
        printf 'MAX %s GHz' "$max_ghz"
    else
        printf '%s' '-'
    fi
}

# [HANDLER] collect_cpu_scalars -> CPU 型号、频率、核心数和 Socket 数。
collect_cpu_scalars() {
    local model='' sockets_text='' cores_text='' min_text='' max_text=''
    local sockets=1 total_cores=1 min_mhz=0 max_mhz=0 frequency='-' i

    if [ "$platform_name" = Darwin ]; then
        model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
        [ -n "$model" ] || model=$(sysctl -n hw.model 2>/dev/null)
        total_cores=$(sysctl -n hw.ncpu 2>/dev/null)
    else
        if command -v lscpu >/dev/null 2>&1; then
            IFS=$'\t' read -r model sockets_text cores_text min_text max_text < <(
                LC_ALL=C lscpu 2>/dev/null | awk -F: '
                    /^[[:space:]]*Model name/ {
                        v = $2
                        gsub(/^[ \t]+|[ \t]+$/, "", v)
                        model = v
                    }
                    /^[[:space:]]*Socket\(s\)/ {
                        v = $2
                        gsub(/^[ \t]+|[ \t]+$/, "", v)
                        sockets = v
                    }
                    /^[[:space:]]*Core\(s\) per socket/ {
                        v = $2
                        gsub(/^[ \t]+|[ \t]+$/, "", v)
                        cores = v
                    }
                    /^[[:space:]]*CPU min MHz/ {
                        v = $2
                        gsub(/^[ \t]+|[ \t]+$/, "", v)
                        min_mhz = v
                    }
                    /^[[:space:]]*CPU max MHz/ {
                        v = $2
                        gsub(/^[ \t]+|[ \t]+$/, "", v)
                        max_mhz = v
                    }
                    END {
                        printf "%s\t%s\t%s\t%s\t%s\n",
                            model, sockets, cores, min_mhz, max_mhz
                    }
                '
            )
        fi
        if [ -z "$model" ] && [ -r /proc/cpuinfo ]; then
            model=$(awk -F: '/^[[:space:]]*model name/ {
                sub(/^[ \t]+/, "", $2)
                print $2
                exit
            }' /proc/cpuinfo 2>/dev/null)
        fi
        total_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
        [ -n "$total_cores" ] || total_cores=$(nproc 2>/dev/null)
    fi

    [ -n "$model" ] || model='UNKNOWN'
    model=${model//$'\t'/ }
    sockets=$(awk -v v="$sockets_text" 'BEGIN { printf "%d", v + 0 }')
    (( sockets > 0 )) || sockets=1
    total_cores=$(awk -v v="$total_cores" 'BEGIN { printf "%d", v + 0 }')
    if (( total_cores <= 0 )); then
        local cores_per_socket
        cores_per_socket=$(awk -v v="$cores_text" \
            'BEGIN { printf "%d", v + 0 }')
        (( cores_per_socket > 0 )) || cores_per_socket=1
        total_cores=$((sockets * cores_per_socket))
    fi
    min_mhz=$(awk -v v="$min_text" 'BEGIN { printf "%d", v + 0 }')
    max_mhz=$(awk -v v="$max_text" 'BEGIN { printf "%d", v + 0 }')
    frequency=$(cpu_frequency_text "$min_mhz" "$max_mhz")

    cpu_models=()
    cpu_freqs=()
    for ((i = 0; i < sockets; i++)); do
        cpu_models+=("$model")
        cpu_freqs+=("$frequency")
    done
    cpu_cores=$total_cores
    cpu_sockets=$sockets
}

# [HANDLER] collect_load_averages -> load1/load5/load15。
collect_load_averages() {
    local values=''
    local -a load_values=()
    if [ "$platform_name" = Darwin ]; then
        values=$(sysctl -n vm.loadavg 2>/dev/null)
    elif [ -r /proc/loadavg ]; then
        values=$(awk '{ print $1, $2, $3 }' /proc/loadavg 2>/dev/null)
    fi
    if [ -z "$values" ]; then
        values=$(uptime 2>/dev/null |
            sed -E 's/.*load averages?:[[:space:]]*//')
    fi
    values=${values//\{/}
    values=${values//\}/}
    values=${values//,/}
    read -r -a load_values <<<"$values"
    load1=${load_values[0]:-0.00}
    load5=${load_values[1]:-0.00}
    load15=${load_values[2]:-0.00}
}

# [HANDLER] collect_uptime -> 人类可读的系统运行时间。
collect_uptime() {
    local seconds=0 boot=''
    if [ -r /proc/uptime ]; then
        seconds=$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null)
    elif [ "$platform_name" = Darwin ]; then
        boot=$(sysctl -n kern.boottime 2>/dev/null |
            sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p')
        if [ -n "$boot" ]; then
            seconds=$(($(date +%s) - boot))
        fi
    fi
    if (( seconds > 0 )); then
        uptime=$(awk -v s="$seconds" 'BEGIN {
            d = int(s / 86400)
            h = int((s % 86400) / 3600)
            m = int((s % 3600) / 60)
            if (d > 0) printf "%dd %dh %dm", d, h, m
            else if (h > 0) printf "%dh %dm", h, m
            else printf "%dm", m
        }')
    else
        uptime='UNKNOWN'
    fi
}

# [HANDLER] collect_memory_scalars -> 内存各项 GiB 数值。
collect_memory_scalars() {
    local total_kb=0 used_kb=0 cache_kb=0 free_kb=0 shared_kb=0 avail_kb=0
    local total_bytes=0

    if [ -r /proc/meminfo ]; then
        read -r total_kb used_kb cache_kb free_kb shared_kb avail_kb < <(
            awk '
                /^MemTotal:/ { total = $2 }
                /^MemFree:/ { free = $2 }
                /^MemAvailable:/ { avail = $2 }
                /^Buffers:/ { buffers = $2 }
                /^Cached:/ { cached = $2 }
                /^Shmem:/ { shared = $2 }
                END {
                    cache = buffers + cached
                    if (avail == "") avail = free + cache
                    used = total - free - cache
                    if (used < 0) used = 0
                    if (used > total) used = total
                    printf "%.0f %.0f %.0f %.0f %.0f %.0f\n",
                        total, used, cache, free, shared, avail
                }
            ' /proc/meminfo 2>/dev/null
        )
    elif [ "$platform_name" = Darwin ] &&
        command -v vm_stat >/dev/null 2>&1; then
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        read -r total_kb used_kb cache_kb free_kb shared_kb avail_kb < <(
            vm_stat 2>/dev/null | awk -v total="$total_bytes" '
                /page size of/ { page_size = $(NF - 1) + 0 }
                /^Pages free:/ { free = $NF + 0 }
                /^Pages speculative:/ { speculative = $NF + 0 }
                /^Pages inactive:/ { inactive = $NF + 0 }
                /^Pages purgeable:/ { purgeable = $NF + 0 }
                END {
                    if (!page_size) page_size = 4096
                    free_bytes = (free + speculative) * page_size
                    cache_bytes = (inactive + purgeable) * page_size
                    used_bytes = total - free_bytes - cache_bytes
                    if (used_bytes < 0) used_bytes = 0
                    if (used_bytes > total) used_bytes = total
                    avail_bytes = free_bytes + cache_bytes
                    printf "%.0f %.0f %.0f %.0f 0 %.0f\n",
                        total / 1024, used_bytes / 1024,
                        cache_bytes / 1024, free_bytes / 1024,
                        avail_bytes / 1024
                }
            '
        )
    fi

    mem_total=$(awk -v kb="$total_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')
    mem_used=$(awk -v kb="$used_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')
    mem_cache=$(awk -v kb="$cache_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')
    mem_free=$(awk -v kb="$free_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')
    mem_shared=$(awk -v kb="$shared_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')
    mem_available=$(awk -v kb="$avail_kb" \
        'BEGIN { printf "%.1f", kb / 1048576 }')
}

# [HANDLER] collect_real_scalars -> 关闭 mock 时的完整真实标量数据。
collect_real_scalars() {
    os_name=$(detect_os_name)
    collect_cpu_scalars
    collect_load_averages
    collect_uptime
    collect_memory_scalars
}

if (( REPORT_MOCK_ENABLED == 1 )); then
    load_mock_scalars
else
    collect_real_scalars
fi

# 内核版本始终使用真实值；mock 只影响上方演示指标。
kernel_version=$(uname -r 2>/dev/null)
[ -n "$kernel_version" ] || kernel_version=unknown
kernel_summary="${platform_name} ${kernel_version} · ${server_arch}"

# 主机名
hostname=$(hostname 2>/dev/null)
[ -n "$hostname" ] || hostname='unknown'
full_hostname=$(hostname -f 2>/dev/null)
[ -n "$full_hostname" ] || full_hostname='unknown'

cpu_model_width=$(max_display_width "${cpu_models[@]}")
cores="${cpu_cores} vCPU(s) / ${cpu_sockets} Socket(s)"

