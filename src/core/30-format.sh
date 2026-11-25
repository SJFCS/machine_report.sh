# shellcheck shell=bash
# ── [FORMAT] 通用数值与百分比 ──────────────────────────────────────────

# [FORMAT] is_number VALUE -> 是否为可安全交给 printf/算术的十进制数值。
# 支持符号、小数和科学计数法；NaN、Inf、空串和带空格的值都不接受。
is_number() {
    [[ ${1-} =~ ^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]]
}

# [FORMAT] nonfinite_as_dash VALUE -> 将 awk 产生的 nan/inf 归一为占位符。
nonfinite_as_dash() {
    local value=${1-}
    case $value in
        ''|*[Nn][Aa][Nn]*|*[Ii][Nn][Ff]*) printf '%s' '-' ;;
        *) printf '%s' "$value" ;;
    esac
}

# [FORMAT] percent_of VALUE TOTAL -> 一位小数的百分比数值，不带 %。
# VALUE/TOTAL 非法、TOTAL <= 0 或结果非有限时返回 "-"。
# 用法：pct=$(percent_of "$used" "$total")
#
# 内存数据拆成彼此独立的数值。堆叠条只使用 used + buff/cache + free
# 三段，因为它们加起来就是 total；shared 已经包含在 used 中，available
# 又是内核给出的可回收估算值，这两项若再堆进条里会重复计数，所以只显示
# 数字。所有数值都保留原始值，避免把一段拼好的文本反解析回数字。
#
# 百分比统一以 total 为分母，方便同一行内横向比较。注意：
#   used + free + buff/cache = total
#   shared 是 used 的子集
#   available 与 free/buff-cache 有重叠
# 因此后面几项的百分比不会全部相加为 100%，这是指标定义不同，不是算错。
percent_of() {
    local value=${1-} total=${2-} result sign=''
    local scaled_value scaled_total tenths
    if ! is_number "$value" || ! is_number "$total"; then
        printf '%s' '-'
        return 0
    fi
    if _number_to_scaled_into scaled_value "$value" 6 &&
        _number_to_scaled_into scaled_total "$total" 6; then
        if (( scaled_total <= 0 )); then
            printf '%s' '-'
            return 0
        fi
        if (( scaled_value < 0 )); then
            sign='-'
            scaled_value=$((-scaled_value))
        fi
        if (( scaled_value <= 8000000000000000 )); then
            tenths=$(((scaled_value * 1000 + scaled_total / 2) / scaled_total))
            _scaled_to_fixed_into result "$tenths" 1
            printf '%s%s' "$sign" "$result"
            return 0
        fi
    fi
    result=$(awk -v v="$value" -v t="$total" 'BEGIN {
        if (t <= 0) { print "-"; exit }
        printf "%.1f", (v / t) * 100
    }' 2>/dev/null) || result='-'
    nonfinite_as_dash "$result"
}

# [FORMAT] human_bytes BYTES -> 1024 进制容量文本，例如 1.8T。
# BYTES 必须是有限的非负数，否则返回 "-"。
# 用法：size=$(human_bytes 1992294400)
human_bytes() {
    local bytes=${1-} result unit=0 divisor=1
    local -a units=('B' 'K' 'M' 'G' 'T' 'P')
    if ! is_number "$bytes" || [[ $bytes == -* ]]; then
        printf '%s' '-'
        return 0
    fi
    if [[ $bytes =~ ^[0-9]+$ ]]; then
        while (( unit < 5 && bytes >= divisor * 1024 )); do
            divisor=$((divisor * 1024))
            unit=$((unit + 1))
        done
        if (( unit == 0 )); then
            printf '%sB' "$bytes"
        elif (( bytes < divisor * 10 )); then
            _ratio_to_fixed_into result "$bytes" "$divisor" 1
            printf '%s%s' "$result" "${units[unit]}"
        else
            _ratio_to_fixed_into result "$bytes" "$divisor" 0
            printf '%s%s' "$result" "${units[unit]}"
        fi
        return 0
    fi
    result=$(awk -v b="$bytes" 'BEGIN {
        split("B K M G T P", units, " ")
        i = 1
        while (b >= 1024 && i < 6) {
            b /= 1024
            i++
        }
        if (i == 1) printf "%.0f%s", b, units[i]
        else if (b < 10) printf "%.1f%s", b, units[i]
        else printf "%.0f%s", b, units[i]
    }' 2>/dev/null) || result='-'
    nonfinite_as_dash "$result"
}

# [FORMAT] format_percent_text VALUE -> 右侧对齐的百分比，非法值占 6 列。
# 正常值先占 5 列再追加 %，例如 " 82.5%" 共 6 列；>= 1000% 会自然加宽。
# 用法：text=$(format_percent_text 82.5)
_format_percent_text_into() {
    local __var=$1 __value=${2-} __pct_text
    if ! is_number "$__value"; then
        printf -v "$__var" '%6s' '-'
        return 0
    fi
    if ! printf -v __pct_text '%5.1f%%' "$__value" 2>/dev/null; then
        printf -v "$__var" '%6s' '-'
        return 0
    fi
    case $__pct_text in
        *[Nn][Aa][Nn]*|*[Ii][Nn][Ff]*) printf -v "$__var" '%6s' '-' ;;
        *) printf -v "$__var" '%s' "$__pct_text" ;;
    esac
}

format_percent_text() {
    local out
    _format_percent_text_into out "${1-}"
    printf '%s' "$out"
}

# [FORMAT] format_percent_suffix VALUE -> 带一个前导空格的百分比后缀。
# 用法：suffix=$(format_percent_suffix 82.5)；宽度=${#suffix}
_format_percent_suffix_into() {
    local __var=$1 __suffix_text
    _format_percent_text_into __suffix_text "${2-}"
    printf -v "$__var" ' %s' "$__suffix_text"
}

format_percent_suffix() {
    local out
    _format_percent_suffix_into out "${1-}"
    printf '%s' "$out"
}

# [FORMAT] format_mib_as_gib MIB -> 一位小数的 GiB 数值，不带单位。
# MIB 必须是有限的非负数，否则返回 "-"。
# 用法：gib=$(format_mib_as_gib 81920)
format_mib_as_gib() {
    local mib=${1-} result scaled_mib
    if ! is_number "$mib" || [[ $mib == -* ]]; then
        printf '%s' '-'
        return 0
    fi
    if _number_to_scaled_into scaled_mib "$mib" 3; then
        _ratio_to_fixed_into result "$scaled_mib" 1024000 1
        printf '%s' "$result"
        return 0
    fi
    printf '%s' '-'
}

