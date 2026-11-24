# shellcheck shell=bash
# ── [HANDLER / MOCK] GPU ───────────────────────────────────────────────

# [MOCK] demo_gpu_rows -> 两块 A100 的 GPU 演示 TSV。
# 字段：NAME<TAB>TOTAL_MIB<TAB>USED_MIB<TAB>UTIL%<TAB>MIN_MHZ<TAB>MAX_MHZ<TAB>METRICS。
# 用法：demo_gpu_rows
demo_gpu_rows() {
    printf '%s\n' \
        $'NVIDIA A100-SXM4-80GB\t81920\t64000\t91\t1095\t1410\t1' \
        $'NVIDIA A100-SXM4-80GB\t81920\t20480\t27\t1095\t1410\t1'
}

# [HANDLER] collect_macos_gpu_rows -> Apple/Intel Mac GPU TSV。
# Apple Silicon 的显存是统一内存，TOTAL 使用物理内存，USED 使用
# ioreg 的 In use system memory；无实时统计时只输出机型与 GPU 核心数。
collect_macos_gpu_rows() {
    local raw='' model='' cores='' util='' used_bytes='' vram_text=''
    local total_bytes='' total_mib=0 used_mib=0 metrics=0 name=''
    local vram_value vram_unit

    raw=$(ioreg -r -c AGXAccelerator -d 1 2>/dev/null)
    if [ -n "$raw" ]; then
        model=$(printf '%s\n' "$raw" | sed -n \
            's/.*"model"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' |
            head -n 1)
        cores=$(printf '%s\n' "$raw" | sed -n \
            's/.*"gpu-core-count"[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
            head -n 1)
        util=$(printf '%s\n' "$raw" | sed -n \
            's/.*"Device Utilization %"[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
            head -n 1)
        used_bytes=$(printf '%s\n' "$raw" | sed -n \
            's/.*"In use system memory"[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
            head -n 1)
    fi

    if [ -z "$model" ]; then
        raw=$(system_profiler SPDisplaysDataType 2>/dev/null)
        model=$(printf '%s\n' "$raw" | awk -F': ' '
            /Chipset Model:/ {
                value = $2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        ')
        cores=$(printf '%s\n' "$raw" | awk -F': ' '
            /Total Number of Cores:/ {
                value = $2
                gsub(/[^0-9]/, "", value)
                print value
                exit
            }
        ')
        vram_text=$(printf '%s\n' "$raw" | awk -F': ' '
            /VRAM \(Total\):/ {
                value = $2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        ')
    fi

    [ -n "$model" ] || return 0
    if [ -n "$vram_text" ]; then
        vram_value=${vram_text%% *}
        vram_unit=${vram_text#* }
        if [[ $vram_value =~ ^[0-9]+$ ]]; then
            case $vram_unit in
                GB) total_mib=$((vram_value * 1024)) ;;
                MB) total_mib=$vram_value ;;
            esac
        fi
    elif [[ $model == Apple* ]]; then
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        if [[ $total_bytes =~ ^[0-9]+$ ]]; then
            total_mib=$((total_bytes / 1048576))
        fi
    fi

    if [ -n "$used_bytes" ] && [ -n "$util" ] && (( total_mib > 0 )); then
        used_mib=$((used_bytes / 1048576))
        metrics=1
    else
        util=0
    fi

    name=$model
    [ -n "$cores" ] && name="$name · ${cores} GPU cores"
    printf '%s\t%s\t%s\t%s\t0\t0\t%s\n' \
        "$name" "$total_mib" "$used_mib" "$util" "$metrics"
}

# [HANDLER] collect_gpu_rows -> 输出 GPU 原始 TSV（字段契约同上）。
# 只读取静态/上限频率，不查询实时 current clocks。
# nvidia-smi 没有统一暴露 base clock，因此实时数据只显示 MAX 频率；
# 演示数据则保留 base–boost 区间；仅开启 mock 时失败才使用 demo_gpu_rows。
# 用法：while IFS=$'\t' read -r name total used util min max; do ...; done
#       < <(collect_gpu_rows)
collect_gpu_rows() {
    local raw=''
    (( REPORT_GPU_ENABLED == 1 )) || return 0
    if command -v nvidia-smi >/dev/null 2>&1; then
        if (( REPORT_GPU_TIMEOUT > 0 )) &&
            command -v timeout >/dev/null 2>&1; then
            raw=$(LC_ALL=C timeout "${REPORT_GPU_TIMEOUT}s" nvidia-smi \
                --query-gpu=name,memory.total,memory.used,utilization.gpu,clocks.max.graphics \
                --format=csv,noheader,nounits 2>/dev/null) || raw=''
        elif (( REPORT_GPU_TIMEOUT > 0 )); then
            raw=$(LC_ALL=C perl -e 'alarm shift; exec @ARGV; exit 127' \
                "$REPORT_GPU_TIMEOUT" nvidia-smi \
                --query-gpu=name,memory.total,memory.used,utilization.gpu,clocks.max.graphics \
                --format=csv,noheader,nounits 2>/dev/null) || raw=''
        else
            raw=$(LC_ALL=C nvidia-smi \
                --query-gpu=name,memory.total,memory.used,utilization.gpu,clocks.max.graphics \
                --format=csv,noheader,nounits 2>/dev/null) || raw=''
        fi
        if [ -n "$raw" ]; then
            printf '%s\n' "$raw" | awk -F', *' '
                {
                    name = $1
                    gsub(/^[ \t]+|[ \t]+$/, "", name)
                    gsub(/\t/, " ", name)
                    total = $2 + 0
                    used = $3 + 0
                    util = $4 + 0
                    max_mhz = $5 + 0
                    if (total > 0)
                        printf "%s\t%d\t%d\t%d\t0\t%d\t1\n",
                            name, total, used, util, max_mhz
                }
            '
            return
        fi
    fi
    if [ "$platform_name" = Darwin ]; then
        raw=$(collect_macos_gpu_rows)
        if [ -n "$raw" ]; then
            printf '%s\n' "$raw"
            return
        fi
    fi
    if (( REPORT_MOCK_ENABLED == 1 )); then
        demo_gpu_rows
    fi
}

# [FORMAT] format_gpu_frequency MIN_MHZ MAX_MHZ -> 静态频率文本。
# MIN=0 时显示 "MAX x.xx GHz"，两者都为 0 时显示 "-"。
# 用法：freq=$(format_gpu_frequency 1095 1410)
format_gpu_frequency() {
    local min_mhz=${1:-0} max_mhz=${2:-0}
    local min_ghz max_ghz
    if ! [[ $min_mhz =~ ^[0-9]+$ && $max_mhz =~ ^[0-9]+$ ]]; then
        printf '%s' '-'
        return 0
    fi
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

# ── [HANDLER / MOCK] 磁盘 ──────────────────────────────────────────────

# [HANDLER] disk_usage_values MOUNTS_CSV -> "USED_K AVAIL_K TOTAL_K"。
# MOUNTS_CSV 是逗号分隔的挂载点；同一文件系统只统计一次。
# 用法：read -r used avail total <<<"$(disk_usage_values '/,/data')"
disk_usage_values() {
    local mounts=$1 mount
    local -a mount_list=()
    IFS=',' read -r -a mount_list <<<"$mounts"
    for mount in "${mount_list[@]}"; do
        mount=${mount# }
        mount=${mount% }
        [ -n "$mount" ] && [ "$mount" != '-' ] || continue
        LC_ALL=C df -Pk "$mount" 2>/dev/null
    done | awk '
        $1 == "Filesystem" { next }
        !seen[$1]++ {
            total += $2
            used += $3
            avail += $4
        }
        END {
            if (total > 0) print used, avail, total
        }
    '
}

# [MOCK] demo_disk_rows -> 三块物理盘的演示 TSV。
# 字段：NAME SIZE MEDIA MOUNTS PCT USED AVAIL FORMAT HEALTH WEAR ERR_LABEL ERR。
# 用法：demo_disk_rows
demo_disk_rows() {
    # 没有 lsblk 的平台（例如当前 macOS 示例环境）使用固定数据，
    # 以保证表格布局可复现；这组值不是任何真实磁盘的容量。
    printf '%s\n' \
        $'sda\t100G\tSSD\t/\t42.5\t42.5G\t57.5G\text4\tPASSED\t4\tCRC\t0' \
        $'nvme0n1\t1.8T\tSSD\t/data,/srv\t67.3\t1.2T\t588G\txfs\tPASSED\t2\tINTEG\t0' \
        $'sdb\t4T\tHDD\t/backup\t81.2\t3.2T\t752G\txfs\tPASSED\t62\tCRC\t8'
}

# [HANDLER] disk_smart_info DEVICE -> HEALTH<TAB>WEAR_PERCENT<TAB>ERR_LABEL<TAB>ERR。
# NVMe 使用 Percentage Used；SATA 使用剩余寿命属性换算磨损百分比；
# SATA/SAS 的 CRC 读取 UDMA_CRC_Error_Count 等属性的 RAW_VALUE；
# NVMe 的 CRC 等价项为 Media and Data Integrity Errors，展示时简写为 INTEG。
disk_smart_info() {
    local device=${1-} raw='' health='' wear=''
    local err_label='INTEG' err_count=''

    case $device in
        /dev/*) ;;
        *)
            printf 'N/A\t-\tINTEG\t-\n'
            return 0
            ;;
    esac
    if (( REPORT_SMART_ENABLED == 0 )) ||
        ! command -v smartctl >/dev/null 2>&1; then
        printf 'N/A\t-\tINTEG\t-\n'
        return 0
    fi

    if (( REPORT_SMART_TIMEOUT > 0 )) &&
        command -v timeout >/dev/null 2>&1; then
        raw=$(LC_ALL=C timeout "${REPORT_SMART_TIMEOUT}s" smartctl \
            -H -A -n standby "$device" 2>&1) || true
    elif (( REPORT_SMART_TIMEOUT > 0 )); then
        raw=$(LC_ALL=C perl -e 'alarm shift; exec @ARGV; exit 127' \
            "$REPORT_SMART_TIMEOUT" smartctl \
            -H -A -n standby "$device" 2>&1) || true
    else
        raw=$(LC_ALL=C smartctl -H -A -n standby "$device" 2>&1) || true
    fi
    [ -n "$raw" ] || {
        printf 'N/A\t-\tINTEG\t-\n'
        return 0
    }

    health=$(printf '%s\n' "$raw" | sed -n \
        's/^SMART overall-health self-assessment test result:[[:space:]]*//p' |
        head -n 1)
    [ -n "$health" ] || health=$(printf '%s\n' "$raw" | sed -n \
        's/^SMART Health Status:[[:space:]]*//p' | head -n 1)
    health=$(printf '%s' "$health" | awk '{ print toupper($1) }')
    health=${health%!}

    wear=$(printf '%s\n' "$raw" | sed -n \
        's/.*Percentage Used:[[:space:]]*\([0-9][0-9]*\)%.*/\1/p' |
        head -n 1)
    if [ -z "$wear" ]; then
        # SATA 属性的 VALUE 列（$4）是规范化的剩余寿命；WHEN_FAILED 为空
        # 时列数会变化，但 VALUE 始终位于 FLAG 之后，因此 $4 仍然稳定。
        wear=$(printf '%s\n' "$raw" | awk '
            $2 ~ /(Wear|Life)/ && $2 ~ /(Indicator|Left|Remain|Leveling)/ {
                if ($4 ~ /^[0-9]+$/) {
                    wear = 100 - $4
                    if (wear < 0) wear = 0
                    if (wear > 100) wear = 100
                    print wear
                    exit
                }
            }
        ')
    fi
    [[ $wear =~ ^[0-9]+$ ]] || wear='-'

    # RAW_VALUE 是最后一个字段；不能依赖固定列号，因为 WHEN_FAILED
    # 可能为空，且不同 smartctl 版本的列宽和字段数并不完全一致。
    err_count=$(printf '%s\n' "$raw" | awk '
        $2 ~ /CRC/ && $2 ~ /(Error|Err)/ && $NF ~ /^[0-9]+$/ {
            print $NF
            exit
        }
        /[Cc][Rr][Cc].*[Ee]rror/ {
            for (i = NF; i >= 1; i--) {
                if ($i ~ /^[0-9]+$/) {
                    print $i
                    exit
                }
            }
        }
    ')
    if [[ $err_count =~ ^[0-9]+$ ]]; then
        err_label=CRC
    else
        err_count=$(printf '%s\n' "$raw" | awk '
            /Media and Data Integrity Errors:/ {
                for (i = NF; i >= 1; i--) {
                    if ($i ~ /^[0-9]+$/) {
                        print $i
                        exit
                    }
                }
            }
        ')
        if ! [[ $err_count =~ ^[0-9]+$ ]]; then
            err_count='-'
        fi
    fi
    printf '%s\t%s\t%s\t%s\n' \
        "${health:-N/A}" "$wear" "$err_label" "$err_count"
}

# [HANDLER] collect_disk_mount_map -> DISK<TAB>FSTYPE<TAB>MOUNTPOINT。
# 把物理盘及其所有子设备归组；TAB 分隔可保留挂载点中的空格。
# 该解析依赖 Linux util-linux 的 lsblk 输出格式，其他平台会走 demo 数据。
# 用法：map=$(collect_disk_mount_map)
collect_disk_mount_map() {
    LC_ALL=C lsblk -nr -o NAME,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | awk '
        $2 == "disk" {
            current = $1
            fstype = $3
            mount = $4
            for (i = 5; i <= NF; i++) mount = mount " " $i
            if (mount ~ /^\[.*\]$/) mount = ""
            if (fstype != "" || mount != "")
                print current "\t" fstype "\t" mount
            next
        }
        $2 ~ /^(loop|rom|zram|raid|mpath|nbd|rbd)$/ { current = ""; next }
        {
            if (current == "") next
            fstype = $3
            mount = $4
            for (i = 5; i <= NF; i++) mount = mount " " $i
            if (mount ~ /^\[.*\]$/) mount = ""
            if (fstype != "" || mount != "")
                print current "\t" fstype "\t" mount
        }
    '
}

# [HANDLER] disk_media_type NAME ROTA -> SSD / HDD / VIRT 展示分类。
# 这是启发式判断，不替代 SMART 或存储控制器报告。
# 用法：media=$(disk_media_type "$name" "$rota")
disk_media_type() {
    local name=$1 rota=$2
    # 这是展示用的介质分类启发式，不替代 SMART 或控制器报告。
    case $name in
        nvme*) printf 'SSD' ;;
        vd*|xvd*) printf 'VIRT' ;;
        *)
            if [ "$rota" = 0 ]; then
                printf 'SSD'
            else
                printf 'HDD'
            fi
            ;;
    esac
}

# [HANDLER] disk_mount_details DISK MOUNT_MAP -> MOUNTS<TAB>FORMATS。
# 合并并去重该磁盘下所有子设备的信息；空字段用 '-' 占位。
# 用法：details=$(disk_mount_details "$name" "$mount_map")
disk_mount_details() {
    local disk_name=$1 mount_map=$2
    local child_disk fstype mountpoint mounts='' formats=''

    while IFS=$'\t' read -r child_disk fstype mountpoint; do
        [ "$child_disk" = "$disk_name" ] || continue
        if [ -n "$fstype" ]; then
            case ",$formats," in
                *",$fstype,"*) ;;
                *) formats="${formats:+$formats,}$fstype" ;;
            esac
        fi
        if [ -n "$mountpoint" ]; then
            case ",$mounts," in
                *",$mountpoint,"*) ;;
                *) mounts="${mounts:+$mounts,}$mountpoint" ;;
            esac
        fi
    done <<<"$mount_map"

    printf '%s\t%s\n' "${mounts:--}" "${formats:--}"
}

# [HANDLER] disk_usage_summary MOUNTS_CSV -> PCT<TAB>USED<TAB>AVAIL。
# bind mount 按文件系统去重，避免容量重复累计。
# 用法：summary=$(disk_usage_summary '/,/data')
disk_usage_summary() {
    local mounts=$1 usage used_k avail_k total_k percent
    usage=$(disk_usage_values "$mounts")
    if [ -z "$usage" ]; then
        printf '%s\t%s\t%s\n' '-' '-' '-'
        return
    fi

    read -r used_k avail_k total_k <<<"$usage"
    percent=$(percent_of "$used_k" "$total_k")
    printf '%s\t%s\t%s\n' \
        "${percent:--}" \
        "$(human_bytes "$((used_k * 1024))")" \
        "$(human_bytes "$((avail_k * 1024))")"
}

# [HANDLER] physical_disk_rows -> 每块物理盘一行原始 TSV。
# 字段：NAME SIZE MEDIA MOUNTS PCT USED AVAIL FORMAT HEALTH WEAR ERR_LABEL ERR。
# 只负责采集和计算，不负责补齐、颜色或边框，因此可单独测试。
# 用法：while IFS=$'\t' read -r ...; do ...; done < <(physical_disk_rows)
#
# [HANDLER] collect_macos_disk_rows -> macOS 本地卷 TSV（字段契约同上）。
collect_macos_disk_rows() {
    local device mount name format media total_k avail_k used_k percent size_h
    local used_h avail_h root_name='' link seen=':' smart_device=''
    local smart_info='' smart_health='' smart_wear=''
    local smart_err_label='' smart_err_count=''
    local last_smart_device='' last_smart_info=''

    while IFS=$'\t' read -r device mount; do
        case $mount in
            /) ;;
            /Volumes/Recovery|/Volumes/com.apple.TimeMachine.localsnapshots)
                continue
                ;;
            /Volumes/*) ;;
            *) continue ;;
        esac
        case $seen in
            *":$mount:"*) continue ;;
        esac
        seen="${seen}${mount}:"

        read -r total_k avail_k < <(
            LC_ALL=C df -Pk "$mount" 2>/dev/null |
                awk 'NR == 2 { print $2, $4 }'
        )
        [[ $total_k =~ ^[0-9]+$ && $avail_k =~ ^[0-9]+$ ]] || continue
        (( total_k > 0 )) || continue
        used_k=$((total_k - avail_k))
        (( used_k >= 0 )) || used_k=0
        percent=$(percent_of "$used_k" "$total_k")
        size_h=$(human_bytes "$((total_k * 1024))")
        used_h=$(human_bytes "$((used_k * 1024))")
        avail_h=$(human_bytes "$((avail_k * 1024))")

        if [ "$mount" = / ]; then
            root_name=''
            for link in /Volumes/*; do
                [ -L "$link" ] || continue
                [ "$(readlink "$link")" = / ] || continue
                root_name=$(basename "$link")
                break
            done
            name=${root_name:-Macintosh HD}
            media=SSD
        else
            name=${mount#/Volumes/}
            name=${name//\\040/ }
            media=EXTERNAL
        fi

        format=$(mount | awk -v target="$mount" '
            $3 == target {
                sub(/^.*\(/, "")
                sub(/,.*/, "")
                print
                exit
            }
        ')
        format=$(printf '%s' "${format:-APFS}" | tr '[:lower:]' '[:upper:]')

        if [[ $device =~ ^/dev/(disk[0-9]+)s ]]; then
            smart_device="/dev/${BASH_REMATCH[1]}"
        else
            smart_device=$device
        fi
        if [ "$smart_device" = "$last_smart_device" ]; then
            smart_info=$last_smart_info
        else
            smart_info=$(disk_smart_info "$smart_device")
            last_smart_device=$smart_device
            last_smart_info=$smart_info
        fi
        IFS=$'\t' read -r smart_health smart_wear \
            smart_err_label smart_err_count <<<"$smart_info"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$size_h" "$media" "$mount" "$percent" \
            "$used_h" "$avail_h" "$format" \
            "$smart_health" "$smart_wear" "$smart_err_label" "$smart_err_count"
    done < <(mount | awk '$1 ~ /^\/dev\/disk/ { print $1 "\t" $3 }')
}

physical_disk_rows() {
    local mount_map line name size rota type media mounts formats
    local usage percent used_h avail_h usage_details mount_details
    local smart_info smart_health smart_wear smart_err_label smart_err_count

    if [ "$platform_name" = Darwin ]; then
        if (( REPORT_MOCK_ENABLED == 1 )); then
            demo_disk_rows
        else
            collect_macos_disk_rows
        fi
        return
    fi

    if ! command -v lsblk >/dev/null 2>&1; then
        if (( REPORT_MOCK_ENABLED == 1 )); then
            demo_disk_rows
        fi
        return
    fi

    mount_map=$(collect_disk_mount_map)

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read -r name size rota type _model <<<"$line"
        [ "$type" = disk ] || continue
        case $name in
            loop*|zram*|sr*|ram*|fd*|nbd*|rbd*) continue ;;
        esac

        media=$(disk_media_type "$name" "$rota")
        mount_details=$(disk_mount_details "$name" "$mount_map")
        IFS=$'\t' read -r mounts formats <<<"$mount_details"
        usage_details=$(disk_usage_summary "$mounts")
        IFS=$'\t' read -r percent used_h avail_h <<<"$usage_details"
        smart_info=$(disk_smart_info "/dev/$name")
        IFS=$'\t' read -r smart_health smart_wear \
            smart_err_label smart_err_count <<<"$smart_info"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$(human_bytes "$size")" "$media" "$mounts" \
            "${percent:--}" "${used_h:--}" "${avail_h:--}" "$formats" \
            "$smart_health" "$smart_wear" "$smart_err_label" "$smart_err_count"
    done < <(LC_ALL=C lsblk -dn -b -o NAME,SIZE,ROTA,TYPE,MODEL 2>/dev/null)
}

