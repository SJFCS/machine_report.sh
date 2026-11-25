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
    local value='' key val product_name='' product_version=''
    if [ "$platform_name" = Darwin ] &&
        command -v sw_vers >/dev/null 2>&1; then
        # sw_vers 不带参数时一次输出全部字段，避免每取一项起一个进程。
        while IFS=: read -r key val; do
            val=${val#"${val%%[![:space:]]*}"}
            case $key in
                ProductName) product_name=$val ;;
                ProductVersion) product_version=$val ;;
            esac
        done < <(sw_vers 2>/dev/null)
        printf '%s' \
            "${product_name:-macOS}${product_version:+ $product_version}"
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
        _mhz_to_ghz_into min_ghz "$min_mhz"
        _mhz_to_ghz_into max_ghz "$max_mhz"
        printf '%s–%s GHz' "$min_ghz" "$max_ghz"
    elif (( max_mhz > 0 )); then
        _mhz_to_ghz_into max_ghz "$max_mhz"
        printf 'MAX %s GHz' "$max_ghz"
    else
        printf '%s' '-'
    fi
}

# [HANDLER] collect_cpu_scalars -> CPU 型号、频率、核心数和 Socket 数。
collect_cpu_scalars() {
    local model='' sockets_text='' cores_text='' min_text='' max_text=''
    local sockets=1 total_cores=1 min_mhz=0 max_mhz=0 frequency='-' i
    local key value cores_per_socket=0
    local sysctl_raw=''

    if [ "$platform_name" = Darwin ]; then
        # 型号和核数合并成一次 sysctl 调用，输出按行对应各个 key。
        sysctl_raw=$(sysctl -n machdep.cpu.brand_string hw.ncpu 2>/dev/null)
        model=${sysctl_raw%%$'\n'*}
        if [[ $sysctl_raw == *$'\n'* ]]; then
            total_cores=${sysctl_raw#*$'\n'}
        fi
        [ -n "$model" ] || model=$(sysctl -n hw.model 2>/dev/null)
    else
        if command -v lscpu >/dev/null 2>&1; then
            lscpu_output=$(LC_ALL=C lscpu 2>/dev/null)
            while IFS=: read -r key value; do
                key=${key//[[:space:]]/}
                value=${value#"${value%%[![:space:]]*}"}
                value=${value%"${value##*[![:space:]]}"}
                case $key in
                    Modelname) model=$value ;;
                    'Socket(s)') sockets_text=$value ;;
                    'Core(s)persocket') cores_text=$value ;;
                    CPUminMHz) min_text=$value ;;
                    CPUmaxMHz) max_text=$value ;;
                esac
            done <<<"$lscpu_output"
        fi
        if [ -z "$model" ] && [ -r /proc/cpuinfo ]; then
            while IFS=: read -r key value; do
                key=${key//[[:space:]]/}
                if [[ $key == modelname ]]; then
                    model=${value#"${value%%[![:space:]]*}"}
                    break
                fi
            done < /proc/cpuinfo
        fi
        total_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
        [ -n "$total_cores" ] || total_cores=$(nproc 2>/dev/null)
    fi

    [ -n "$model" ] || model='UNKNOWN'
    model=${model//$'\t'/ }
    sockets=0
    _number_integer_into sockets "$sockets_text"
    (( sockets > 0 )) || sockets=1
    _number_integer_into total_cores "$total_cores"
    if (( total_cores <= 0 )); then
        _number_integer_into cores_per_socket "$cores_text"
        (( cores_per_socket > 0 )) || cores_per_socket=1
        total_cores=$((sockets * cores_per_socket))
    fi
    _number_integer_into min_mhz "$min_text"
    _number_integer_into max_mhz "$max_text"
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
    local load_raw=''
    local -a load_values=()
    if [ "$platform_name" = Darwin ]; then
        load_raw=$(sysctl -n vm.loadavg 2>/dev/null)
    elif [ -r /proc/loadavg ]; then
        read -r load1 load5 load15 load_raw < /proc/loadavg || true
        [ -n "${load1:-}" ] && [ -n "${load5:-}" ] && [ -n "${load15:-}" ] &&
            return
    fi
    if [ -z "$load_raw" ]; then
        load_raw=$(uptime 2>/dev/null |
            sed -E 's/.*load averages?:[[:space:]]*//')
    fi
    load_raw=${load_raw//\{/}
    load_raw=${load_raw//\}/}
    load_raw=${load_raw//,/}
    read -r -a load_values <<<"$load_raw"
    load1=${load_values[0]:-0.00}
    load5=${load_values[1]:-0.00}
    load15=${load_values[2]:-0.00}
}

# [HANDLER] collect_uptime -> 人类可读的系统运行时间。
collect_uptime() {
    local seconds=0 boot=''
    local days hours minutes
    if [ -r /proc/uptime ]; then
        read -r seconds boot < /proc/uptime || true
        seconds=${seconds%%.*}
    elif [ "$platform_name" = Darwin ]; then
        boot=$(sysctl -n kern.boottime 2>/dev/null |
            sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p')
        if [ -n "$boot" ]; then
            seconds=$(($(date +%s) - boot))
        fi
    fi
    if (( seconds > 0 )); then
        days=$((seconds / 86400))
        hours=$(((seconds % 86400) / 3600))
        minutes=$(((seconds % 3600) / 60))
        if (( days > 0 )); then
            printf -v uptime '%dd %dh %dm' "$days" "$hours" "$minutes"
        elif (( hours > 0 )); then
            printf -v uptime '%dh %dm' "$hours" "$minutes"
        else
            printf -v uptime '%dm' "$minutes"
        fi
    else
        uptime='UNKNOWN'
    fi
}

# [HANDLER] collect_memory_scalars -> 内存各项 GiB 数值。
collect_memory_scalars() {
    local total_kb=0 used_kb=0 cache_kb=0 free_kb=0 shared_kb=0 avail_kb=0
    local total_bytes=0
    local buffers_kb=0 cached_kb=0 key value

    if [ -r /proc/meminfo ]; then
        while IFS=: read -r key value; do
            value=${value//[[:space:]]/}
            value=${value%kB}
            case $key in
                MemTotal) total_kb=$value ;;
                MemFree) free_kb=$value ;;
                MemAvailable) avail_kb=$value ;;
                Buffers) buffers_kb=$value ;;
                Cached) cached_kb=$value ;;
                Shmem) shared_kb=$value ;;
            esac
        done < /proc/meminfo
        cache_kb=$((buffers_kb + cached_kb))
        (( avail_kb > 0 )) || avail_kb=$((free_kb + cache_kb))
        used_kb=$((total_kb - free_kb - cache_kb))
        (( used_kb < 0 )) && used_kb=0
        (( used_kb > total_kb )) && used_kb=$total_kb
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

    _ratio_to_fixed_into mem_total "$total_kb" 1048576 1
    _ratio_to_fixed_into mem_used "$used_kb" 1048576 1
    _ratio_to_fixed_into mem_cache "$cache_kb" 1048576 1
    _ratio_to_fixed_into mem_free "$free_kb" 1048576 1
    _ratio_to_fixed_into mem_shared "$shared_kb" 1048576 1
    _ratio_to_fixed_into mem_available "$avail_kb" 1048576 1
}

# [HANDLER] collect_real_scalars -> 关闭 mock 时的完整真实标量数据。
collect_real_scalars() {
    _profile_begin 'os'
    os_name=$(detect_os_name)
    _profile_end
    _profile_begin 'cpu'
    collect_cpu_scalars
    _profile_end
    _profile_begin 'load'
    collect_load_averages
    _profile_end
    _profile_begin 'uptime'
    collect_uptime
    _profile_end
    _profile_begin 'memory'
    collect_memory_scalars
    _profile_end
}


