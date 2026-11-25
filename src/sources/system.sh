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
    cpu_labels=('CPU Socket 0' '' '' '' 'CPU Socket 1' '' '')
    cpu_models=(
        '12th Gen Intel(R) Core(TM) i9-12900H'
        ''
        ''
        ''
        'AMD EPYC 9354'
        ''
        ''
    )
    cpu_freqs=(
        '20 vCPUs 14C'
        '· 4 vCPUs P(2T) 0.40–5.00 GHz'
        '· 8 vCPUs P(2T) 0.40–4.90 GHz'
        '· 8 vCPUs E(1T) 0.40–3.80 GHz'
        '64 vCPUs 32C'
        '· 32 vCPUs C(2T) 3.25–3.75 GHz'
        '· 32 vCPUs C(2T) 3.10–3.55 GHz'
    )
    cpu_summary_label='SUM CORES'
    cpu_core_summary='84 vCPUs · 46C · 6×P(2T) + 8×E(1T) + 32×C(2T) · 2 Sockets'
    cpu_cores=84
    cpu_sockets=2
    load1='16.80'
    load5='8.40'
    load15='4.20'
    uptime='2h 10m'
    mem_total='16'
    mem_used='13.2'
    mem_cache='9.6'
    mem_free='3.2'
    mem_shared='0.8'
    mem_available='1.4'
    ntp_status='SYNCED'
    ntp_server='time.cloudflare.com (162.159.200.1)'
    ntp_offset='+0.284 ms'
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

# [SOURCE] collect_linux_hybrid_cpu_groups -> 混合架频率分组 TSV。
# 每行：
#   SOCKET<TAB>LOGICAL<TAB>THREADS<TAB>CORES<TAB>TYPE<TAB>MIN_MHZ<TAB>MAX_MHZ
# 频率键来自每个物理核的 cpufreq cpuinfo min/max，不能合并不同睿频档。
# P/E 标签由每核线程数判断；按 Socket 升序、频率降序排列。
collect_linux_hybrid_cpu_groups() {
    local entries=''
    command -v lscpu >/dev/null 2>&1 || return 0
    entries=$(LC_ALL=C lscpu \
        -e=CPU,CORE,SOCKET,ONLINE,MAXMHZ,MINMHZ 2>/dev/null) ||
        return 0
    [ -n "$entries" ] || return 0

    printf '%s\n' "$entries" | awk '
        NR == 1 { next }
        $4 != "yes" { next }
        $5 == "-" || $6 == "-" { next }
        {
            key = $3 ":" $2
            rows[key]++
            if (key in seen) {
                next
            }
            seen[key] = 1
            socket[key] = $3 + 0
            core_max[key] = $5 + 0
            core_min[key] = $6 + 0
        }
        END {
            for (key in seen) {
                threads = rows[key]
                freq_key = sprintf("%s:%.0f:%.0f",
                    socket[key], core_min[key], core_max[key])
                if (!(freq_key in group_cores)) {
                    groups[++group_count] = freq_key
                    group_socket[freq_key] = socket[key]
                    group_threads[freq_key] = threads
                    group_min[freq_key] = core_min[key]
                    group_max[freq_key] = core_max[key]
                }
                group_cores[freq_key]++
            }
            if (group_count < 2) {
                exit
            }
            for (i = 1; i <= group_count; i++) {
                key = groups[i]
                if (group_threads[key] > 1) {
                    has_p = 1
                } else {
                    has_e = 1
                }
            }
            if (!has_p || !has_e) {
                exit
            }
            for (i = 1; i <= group_count; i++) {
                best = ""
                for (j = 1; j <= group_count; j++) {
                    key = groups[j]
                    if (key in used) {
                        continue
                    }
                    if (best == "" ||
                        group_socket[key] < group_socket[best] ||
                        (group_socket[key] == group_socket[best] &&
                         (group_max[key] > group_max[best] ||
                          (group_max[key] == group_max[best] &&
                           group_min[key] > group_min[best])))) {
                        best = key
                    }
                }
                used[best] = 1
                threads = group_threads[best]
                cores = group_cores[best]
                type = threads > 1 ? "P" : "E"
                printf "%d\t%d\t%d\t%d\t%s\t%.0f\t%.0f\n",
                    group_socket[best], cores * threads, threads, cores, type,
                    group_min[best], group_max[best]
            }
        }
    '
}

# [HANDLER] detect_macos_sysctl_cpu_frequency_into MIN_VAR MAX_VAR -> MHz。
# Intel Mac 通过 hw.cpufrequency* 读取；Apple Silicon 不提供这些 sysctl。
detect_macos_sysctl_cpu_frequency_into() {
    local __min_var=$1 __max_var=$2
    local max_hz='' min_hz='' min_value=0 max_value=0

    max_hz=$(sysctl -n hw.cpufrequency_max 2>/dev/null)
    [ -n "$max_hz" ] || max_hz=$(sysctl -n hw.cpufrequency 2>/dev/null)
    if [[ $max_hz =~ ^[1-9][0-9]*$ ]]; then
        max_value=$((max_hz / 1000000))
        min_hz=$(sysctl -n hw.cpufrequency_min 2>/dev/null)
        if [[ $min_hz =~ ^[0-9]+$ ]]; then
            min_value=$((min_hz / 1000000))
        fi
    fi

    printf -v "$__min_var" '%s' "$min_value"
    printf -v "$__max_var" '%s' "$max_value"
}

# [SOURCE] detect_macos_dvfs_ranges -> P/E 频率范围 TSV。
# Apple Silicon 从 pmgr 的 DVFS 表读取：表内是 4 字节频率 + 4 字节电压，
# M1-M3 用 Hz，M4 起用 kHz，旧数据可能直接用 MHz。输出：
#   P<TAB>MIN_MHZ<TAB>MAX_MHZ
#   E<TAB>MIN_MHZ<TAB>MAX_MHZ
detect_macos_dvfs_ranges() {
    ioreg -lw0 -r -n pmgr 2>/dev/null |
        perl -e '
            my (%lo, %hi);
            while (<STDIN>) {
                while (/"voltage-states(\d+)-sram" = <([0-9a-f]+)>/g) {
                    my ($key, $bytes) = ($1, pack("H*", $2));
                    for (my $offset = 0;
                         $offset + 8 <= length($bytes);
                         $offset += 8) {
                        my $freq = unpack("V", substr($bytes, $offset, 4));
                        next if !$freq;
                        if ($freq >= 100_000_000) {
                            $freq /= 1_000_000;
                        } elsif ($freq >= 100_000) {
                            $freq /= 1_000;
                        }
                        next if $freq < 100 || $freq > 10_000;
                        if (!exists($lo{$key}) || $freq < $lo{$key}) {
                            $lo{$key} = $freq;
                        }
                        if (!exists($hi{$key}) || $freq > $hi{$key}) {
                            $hi{$key} = $freq;
                        }
                    }
                }
            }

            my ($p, $e);
            $p = 5 if exists $hi{5};
            for my $candidate (1, 22, 23) {
                next if !exists $hi{$candidate};
                next if $p && $hi{$candidate} >= $hi{$p};
                $e = $candidate if !$e || $hi{$candidate} > $hi{$e};
            }

            printf "P\t%.0f\t%.0f\n", $lo{$p}, $hi{$p} if $p;
            printf "E\t%.0f\t%.0f\n", $lo{$e}, $hi{$e} if $e;
        '
}

# [HANDLER] detect_macos_cpu_frequency_text -> 静态频率区间文本。
detect_macos_cpu_frequency_text() {
    local min_mhz=0 max_mhz=0 ranges='' label='' lo='' hi=''
    local lo_ghz='' hi_ghz='' text=''

    detect_macos_sysctl_cpu_frequency_into min_mhz max_mhz
    if (( max_mhz > 0 )); then
        cpu_frequency_text "$min_mhz" "$max_mhz"
        return
    fi

    ranges=$(detect_macos_dvfs_ranges)
    while IFS=$'\t' read -r label lo hi; do
        [ -n "$label" ] || continue
        _mhz_to_ghz_into lo_ghz "$lo"
        _mhz_to_ghz_into hi_ghz "$hi"
        [ -z "$text" ] || text+=' · '
        text+="${label} ${lo_ghz}–${hi_ghz} GHz"
    done <<<"$ranges"
    printf '%s' "$text"
}

# [SOURCE] collect_macos_cpu_groups -> P/E 分组，字段与 Linux 版本一致。
# Apple 的 perflevel0/1 分别对应 Performance/Efficiency，物理和逻辑核数
# 由 sysctl 提供；频率范围来自 pmgr DVFS 表，不混用 GPU/ANE 表。
collect_macos_cpu_groups() {
    local levels='' p_phys=0 p_logical=0 e_phys=0 e_logical=0
    local ranges='' label='' lo='' hi=''
    local p_min=0 p_max=0 e_min=0 e_max=0 p_threads=0 e_threads=0

    levels=$(sysctl -n hw.nperflevels 2>/dev/null)
    [[ $levels =~ ^[1-9][0-9]*$ ]] || return 0
    (( levels == 2 )) || return 0

    p_phys=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null)
    p_logical=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null)
    e_phys=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null)
    e_logical=$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null)
    _number_integer_into p_phys "$p_phys"
    _number_integer_into p_logical "$p_logical"
    _number_integer_into e_phys "$e_phys"
    _number_integer_into e_logical "$e_logical"
    (( p_phys > 0 && p_logical >= p_phys )) || return 0
    (( e_phys > 0 && e_logical >= e_phys )) || return 0

    ranges=$(detect_macos_dvfs_ranges)
    while IFS=$'\t' read -r label lo hi; do
        case $label in
            P) p_min=$lo; p_max=$hi ;;
            E) e_min=$lo; e_max=$hi ;;
        esac
    done <<<"$ranges"
    (( p_min > 0 && p_max > 0 && e_min > 0 && e_max > 0 )) || return 0

    p_threads=$((p_logical / p_phys))
    e_threads=$((e_logical / e_phys))
    (( p_threads > 0 && e_threads > 0 )) || return 0
    printf '0\t%s\t%s\t%s\tP\t%s\t%s\n' \
        "$p_logical" "$p_threads" "$p_phys" "$p_min" "$p_max"
    printf '0\t%s\t%s\t%s\tE\t%s\t%s\n' \
        "$e_logical" "$e_threads" "$e_phys" "$e_min" "$e_max"
}

# [SOURCE] _append_socket_cpu_rows SOCKET MODEL LOGICAL PHYSICAL GROUPS...
# 生成一个 Socket 的表头行和若干频率档续行。
_append_socket_cpu_rows() {
    local socket_id=$1 model=$2 logical=$3 physical=$4 group=''
    shift 4

    cpu_labels+=("CPU Socket $socket_id")
    cpu_models+=("$model")
    cpu_freqs+=("${logical} vCPUs ${physical}C")
    for group in "$@"; do
        cpu_labels+=("")
        cpu_models+=("")
        cpu_freqs+=("· $group")
    done
}

# [HANDLER] collect_cpu_scalars -> CPU 型号、频率、核心数和 Socket 数。
collect_cpu_scalars() {
    local model='' sockets_text='' cores_text='' min_text='' max_text=''
    local sockets=1 total_cores=1 min_mhz=0 max_mhz=0 frequency='-' i
    local key value cores_per_socket=0
    local group_rows='' g_socket='' g_logical=0 g_threads=0 g_cores=0
    local g_min=0 g_max=0
    local g_label='' g_min_ghz g_max_ghz
    local current_socket='' socket_logical=0 socket_physical=0
    local -a group_lines=()
    local all_cores=0 p_cores=0 p_threads=0 e_cores=0 e_threads=0
    local core_summary='' socket_word='Sockets'
    local sysctl_raw=''

    if [ "$platform_name" = Darwin ]; then
        # 型号和核数合并成一次 sysctl 调用，输出按行对应各个 key。
        sysctl_raw=$(sysctl -n machdep.cpu.brand_string hw.ncpu 2>/dev/null)
        model=${sysctl_raw%%$'\n'*}
        if [[ $sysctl_raw == *$'\n'* ]]; then
            total_cores=${sysctl_raw#*$'\n'}
        fi
        [ -n "$model" ] || model=$(sysctl -n hw.model 2>/dev/null)
        group_rows=$(collect_macos_cpu_groups)
        [ -n "$group_rows" ] || frequency=$(detect_macos_cpu_frequency_text)
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
        _number_integer_into min_mhz "$min_text"
        _number_integer_into max_mhz "$max_text"
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
    if [ "$platform_name" != Darwin ]; then
        group_rows=$(collect_linux_hybrid_cpu_groups)
        if [ -z "$group_rows" ]; then
            frequency=$(cpu_frequency_text "$min_mhz" "$max_mhz")
        fi
    fi
    [ -n "$frequency" ] || frequency='-'

    cpu_labels=()
    cpu_models=()
    cpu_freqs=()
    cpu_summary_label=CORES
    if [ -n "$group_rows" ]; then
        while IFS=$'\t' read -r \
            g_socket g_logical g_threads g_cores g_label g_min g_max; do
            [ -n "$g_logical" ] || continue
            if [ -n "$current_socket" ] && [ "$g_socket" != "$current_socket" ]; then
                _append_socket_cpu_rows "$current_socket" "$model" \
                    "$socket_logical" "$socket_physical" "${group_lines[@]}"
                group_lines=()
                socket_logical=0
                socket_physical=0
                current_socket=$g_socket
            elif [ -z "$current_socket" ]; then
                current_socket=$g_socket
            fi

            _mhz_to_ghz_into g_min_ghz "$g_min"
            _mhz_to_ghz_into g_max_ghz "$g_max"
            if [ "$g_label" = P ]; then
                (( p_threads > 0 )) || p_threads=$g_threads
                p_cores=$((p_cores + g_cores))
            else
                e_threads=$g_threads
                e_cores=$((e_cores + g_cores))
            fi
            all_cores=$((all_cores + g_cores))
            socket_logical=$((socket_logical + g_logical))
            socket_physical=$((socket_physical + g_cores))
            group_lines+=("${g_logical} vCPUs ${g_label}(${g_threads}T) ${g_min_ghz}–${g_max_ghz} GHz")
        done <<<"$group_rows"
        if [ -n "$current_socket" ]; then
            _append_socket_cpu_rows "$current_socket" "$model" \
                "$socket_logical" "$socket_physical" "${group_lines[@]}"
        fi
        (( sockets == 1 )) && socket_word=Socket
        cpu_summary_label='SUM CORES'
        core_summary="${total_cores} vCPUs · ${all_cores}C · ${p_cores}×P(${p_threads}T) + ${e_cores}×E(${e_threads}T) · ${sockets} ${socket_word}"
    else
        for ((i = 0; i < sockets; i++)); do
            cpu_labels+=("CPU $i")
            cpu_models+=("$model")
            cpu_freqs+=("$frequency")
        done
    fi
    cpu_cores=$total_cores
    cpu_sockets=$sockets
    cpu_core_summary=$core_summary
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

# [STAGE] collect_shared_scalars -> 标量与元数据（OS/CPU/负载/运行时间/内存）。
collect_shared_scalars() {
    if (( REPORT_MOCK_ENABLED == 1 )); then
        _profile_begin 'mock scalars'
        load_mock_scalars
        _profile_end
    else
        collect_real_scalars
    fi

    # 内核版本始终使用真实值；mock 只影响上方演示指标。
    _profile_begin 'metadata'
    kernel_version=$(uname -r 2>/dev/null)
    [ -n "$kernel_version" ] || kernel_version=unknown
    kernel_summary="${platform_name} ${kernel_version}"

    # 主机名
    hostname=$(hostname 2>/dev/null)
    [ -n "$hostname" ] || hostname='unknown'
    full_hostname=$(hostname -f 2>/dev/null)
    [ -n "$full_hostname" ] || full_hostname='unknown'

    cpu_model_width=$(max_display_width "${cpu_models[@]}")
    if [ -n "${cpu_core_summary:-}" ]; then
        cores=$cpu_core_summary
    else
        cores="${cpu_cores} vCPU(s) / ${cpu_sockets} Socket(s)"
    fi
    _profile_end
}
