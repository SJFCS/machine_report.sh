# shellcheck shell=bash
# ── [FORMAT] 无外部进程的数值基础函数 ─────────────────────────────────
#
# 采集阶段早于 40-format.sh 执行，因此这些最底层的定点换算单独放在这里。
# 它们只使用 Bash 内建算术，避免每个 CPU/内存/容量数值都启动一次 awk。
# 输入范围受 64 位整数限制；需要更高精度或科学计数法时由上层回退到 awk。

# [FORMAT] _number_to_scaled_into VAR VALUE DECIMALS -> 定点整数。
# 例如 _number_to_scaled_into x 12.34 2 得到 1234。
# 只接受普通十进制（可带符号、小数），指数形式返回 1。
_number_to_scaled_into() {
    local __var=$1 value=${2-} decimals=${3:-0}
    local sign int_part frac digits scaled

    [[ $decimals =~ ^[0-9]+$ ]] || return 1
    (( decimals <= 6 )) || return 1
    case $value in
        .*) value="0$value" ;;
        -.*) value="-0${value#-}" ;;
        +.*) value="+0${value#+}" ;;
    esac
    [[ $value =~ ^([+-]?)([0-9]+)([.]([0-9]*))?$ ]] || return 1

    sign=${BASH_REMATCH[1]}
    int_part=${BASH_REMATCH[2]}
    frac=${BASH_REMATCH[4]:-}
    while [[ $int_part == 0* && ${#int_part} -gt 1 ]]; do
        int_part=${int_part#0}
    done
    while (( ${#frac} < decimals )); do
        frac+='0'
    done
    if (( decimals == 0 )); then
        frac=''
    else
        frac=${frac:0:decimals}
    fi

    digits="${int_part}${frac}"
    scaled=$((10#$digits))
    [[ $sign == - ]] && scaled=$((-scaled))
    printf -v "$__var" '%s' "$scaled"
}

# [FORMAT] _number_integer_into VAR VALUE -> 截断为整数。
_number_integer_into() {
    _number_to_scaled_into "${1-}" "${2-}" 0
}

# [FORMAT] _scaled_to_fixed_into VAR VALUE DECIMALS -> 定点整数转小数文本。
_scaled_to_fixed_into() {
    local __var=$1 value=${2-0} decimals=${3:-0}
    local sign='' factor=1 whole frac i

    [[ $value =~ ^[+-]?[0-9]+$ && $decimals =~ ^[0-9]+$ ]] || return 1
    if (( value < 0 )); then
        sign='-'
        value=$((-value))
    fi
    for ((i = 0; i < decimals; i++)); do
        factor=$((factor * 10))
    done
    whole=$((value / factor))
    frac=$((value % factor))
    if (( decimals == 0 )); then
        printf -v "$__var" '%s%d' "$sign" "$whole"
    else
        printf -v "$__var" '%s%d.%0*d' "$sign" "$whole" "$decimals" "$frac"
    fi
}

# [FORMAT] _ratio_to_fixed_into VAR NUMERATOR DENOMINATOR DECIMALS
# 整数比值四舍五入成固定小数位；DENOMINATOR 必须大于 0。
_ratio_to_fixed_into() {
    local __var=$1 numerator=${2-0} denominator=${3-1} decimals=${4:-0}
    local sign='' factor=1 scaled whole frac i

    [[ $numerator =~ ^[+-]?[0-9]+$ ]] || return 1
    [[ $denominator =~ ^[0-9]+$ ]] || return 1
    [[ $decimals =~ ^[0-9]+$ ]] || return 1
    (( denominator > 0 && decimals <= 6 )) || return 1

    for ((i = 0; i < decimals; i++)); do
        factor=$((factor * 10))
    done
    if (( numerator < 0 )); then
        sign='-'
        numerator=$((-numerator))
    fi
    scaled=$(((numerator * factor + denominator / 2) / denominator))
    (( scaled == 0 )) && sign=''
    whole=$((scaled / factor))
    frac=$((scaled % factor))
    if (( decimals == 0 )); then
        printf -v "$__var" '%s%d' "$sign" "$whole"
    else
        printf -v "$__var" '%s%d.%0*d' "$sign" "$whole" "$decimals" "$frac"
    fi
}

# [FORMAT] _mhz_to_ghz_into VAR MHZ -> GHz 文本，保留两位小数。
# 构造可被 Bash printf 解析的十进制文本，既不需要 awk，也与 printf "%.2f"
# 的舍入行为保持一致。
_mhz_to_ghz_into() {
    local __var=$1 mhz=${2-0} whole remainder decimal
    [[ $mhz =~ ^[0-9]+$ ]] || return 1
    whole=$((mhz / 1000))
    remainder=$((mhz % 1000))
    printf -v decimal '%d.%03d' "$whole" "$remainder"
    printf -v "$__var" '%.2f' "$decimal"
}
