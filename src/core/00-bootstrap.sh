#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# -*- coding: utf-8 -*-
# ============================================================
# File    : machine_report.sh
# Author  : song.jinfeng@outlook.com
# Date    : BUILD_TIME
# Version : BUILD_VERSION
# Repo    : https://github.com/SJFCS/machine_report.sh.git
# Desc    : It displays useful machine information right in the terminal session. 
# ============================================================
# 本脚本的约定：
#   1. 所有可能含中文、ANSI 或图标的宽度、补齐、居中、截断都经过
#      display_width() / fit_display()。单列文本走 Bash 快路径，复杂
#      Unicode 文本走批量 Perl。
#   2. Perl 自带 Unicode 属性匹配，用 East_Asian_Width 和
#      General_Category 判断宽字符、组合符；无需安装 CPAN 包。
#   3. ANSI CSI/OSC 序列占 0 列；私有区字符（Nerd Font）按 1 列处理。
#   4. 单元格只支持单行。超宽内容显示“…”并保留原始数据，不会撑破边框。
#
# ── 代码分层 ────────────────────────────────────────────────────────────
#
#   src/core/      框架内核：宽度、数字、表格、布局、渲染、mr_* API
#   src/sources/   纯数据采集：只输出文本或 TSV，不画边框、不加颜色
#   src/handlers/  UI 逻辑：一个文件一个 handler，用 mr_* 排版
#   src/main.sh    执行入口：采集 → 依次运行 handler → 测量 → 回填 → 渲染
#
# 想加自己的内容，不用看内核，只写一个 handler：
#   1. 在 src/handlers/ 下新建 70-mything.sh
#   2. 定义 handler_mything()，调用 mr_field 追加行
#   3. 文件末尾写 mr_register mything
#   4. ./build.sh
#
# mr_ 开头的函数是对外 API（实现见 core/45-api.sh），其余函数都是内部实现。
# 字段名和数据列会自动测量；NAME_W / DATA_W 再由上下限夹住。
#
# 依赖列宽的行（条形图、百分比）先占位，等测量完再回填：
#   handler_mything() {
#       mr_field_break 'LAST BOOT' "$(date '+%Y-%m-%d %H:%M')"
#       mr_field 'DISK TEMP' ''
#       TEMP_ROW=$FIELD_INDEX
#   }
#   handler_mything_fill() {
#       mr_update "$TEMP_ROW" "$(mr_bar 42 100)"
#   }
#   mr_register mything
#
# 依赖：Bash、awk、Perl 5。适用于 macOS/Linux。
# 颜色：终端里自动启用；设置 NO_COLOR=1 可关闭，FORCE_COLOR=1 可强制启用。
# 性能：设置 REPORT_PROFILE=1 后，各采集与渲染阶段的耗时写入 stderr。
# GPU：REPORT_GPU_ENABLED=0 跳过采集；REPORT_GPU_TIMEOUT 控制 nvidia-smi
#      发出终止信号的秒数（默认 1，设为 0 表示不限制）。驱动处于不可中断
#      等待时，信号也可能延迟生效；需要稳定速度时应直接跳过 GPU。
# SMART：需要 smartmontools 的 smartctl。REPORT_SMART_ENABLED=0 跳过采集；
#        REPORT_SMART_TIMEOUT 控制单块磁盘超时秒数（默认 2，0 表示不限制）。
# 数据：REPORT_MOCK_ENABLED=0（默认）关闭 mock，=1 开启完整演示数据；
#
# ── 函数索引（内核开发用） ──────────────────────────────────────────────
#
# [MOCK] 演示数据（只影响展示，不负责采集）
#   load_mock_scalars      OS/CPU/负载/内存等固定标量
#   demo_gpu_rows          无 nvidia-smi 时的双 GPU 示例
#   demo_disk_rows         无 lsblk 时的多磁盘示例
#   用法：仅当 REPORT_MOCK_ENABLED=1 时调用；保持变量/TSV 格式不变。
#
# [SOURCE] 实际数据采集（输出纯文本或 TSV，不负责边框、颜色和截断）
#   collect_shared_scalars 汇总标量（mock/真实）与内核/主机名等元数据
#   collect_platform_session 汇总厂商、型号、UUID、locale 与登录会话
#   collect_real_scalars   OS/CPU/负载/内存/运行时间等真实标量
#   dmi_field / darwin_field
#   detect_manufacturer / detect_product_name / detect_virtualization
#   detect_system_uuid / detect_locale / detect_timezone
#   detect_login_user / detect_login_client
#   collect_network_interfaces   输出：IFACE<TAB>IPv4
#   collect_dns_servers          输出：去重后的 DNS 服务器地址
#   collect_gpu_rows             输出：NAME<TAB>TOTAL<TAB>USED<TAB>UTIL<TAB>MIN<TAB>MAX<TAB>METRICS
#   physical_disk_rows           输出：NAME<TAB>SIZE<TAB>MEDIA<TAB>MOUNTS<TAB>PCT<TAB>USED<TAB>AVAIL<TAB>FORMAT<TAB>HEALTH<TAB>WEAR<TAB>ERR_LABEL<TAB>ERR
#   disk_usage_values / collect_disk_mount_map / disk_media_type
#   disk_mount_details / disk_usage_summary / disk_smart_info
#   用法：value=$(detect_locale)；建议单个 handler 只做一件事并输出纯数据。
#
# [FORMAT] 纯值格式化（不画边框）
#   is_number / nonfinite_as_dash / percent_of / human_bytes
#   format_percent_text / format_percent_suffix
#   format_mib_as_gib / format_gpu_frequency / format_quantity
#   format_mem_quantity / align_row_ends / align_mem_percent
#   memory_status_text / color_kv_segment / color_kv_segments
#   format_disk_columns
#   用法：formatted=$(format_percent_text 82.5)。
#
# [TABLE] 表格控制（宽度、字段、条形图、边框）
#   display_width / fit_display / pad_display / repeat_char
#   max_display_width / max_tsv_column_width
#   add_field / measure_fields / ensure_centered_width / ensure_data_width
#   print_divider / print_dashed_divider / print_header
#   print_merged_divider / _format_report_lines
#   bar / percent_bar_display / disk_usage_display
#   gpu_memory_display / gpu_util_display / load_display / stacked_bar
#   用法：add_field 'LABEL' 'VALUE'；measure_fields；render_report。
#   TABLE 层只消费已完成的数据，不应调用 lsblk、nvidia-smi 或 dmidecode。
#
# [HANDLER] 展示层
#   每个 handlers/*.sh 定义 handler_xxx（必需）、handler_xxx_measure
#   （可选）和 handler_xxx_fill（可选），用 mr_field / mr_update 排版。

set -u

# 配置校验：把开关和超时统一规范化，非法值在采集开始前退出。
_report_parse_bool() {
    local name=$1 setting=$2
    case $setting in
        1|true|TRUE|yes|YES|on|ON) setting=1 ;;
        0|false|FALSE|no|NO|off|OFF) setting=0 ;;
        *)
            printf '%s\n' \
                "$name 只能是 0/1（也支持 true/false/on/off）：$setting" >&2
            return 2
            ;;
    esac
    printf -v "$name" '%s' "$setting"
}

_report_parse_seconds() {
    local name=$1 setting=$2
    if ! [[ $setting =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$name 必须是非负整数秒：$setting" >&2
        return 2
    fi
    printf -v "$name" '%s' "$((10#$setting))"
}

_report_parse_bool REPORT_MOCK_ENABLED "${REPORT_MOCK_ENABLED:-0}" || exit $?
_report_parse_bool REPORT_PROFILE "${REPORT_PROFILE:-0}" || exit $?
_report_parse_bool REPORT_GPU_ENABLED "${REPORT_GPU_ENABLED:-1}" || exit $?
_report_parse_seconds REPORT_GPU_TIMEOUT "${REPORT_GPU_TIMEOUT:-1}" || exit $?
_report_parse_bool REPORT_SMART_ENABLED "${REPORT_SMART_ENABLED:-1}" || exit $?
_report_parse_seconds REPORT_SMART_TIMEOUT "${REPORT_SMART_TIMEOUT:-2}" || exit $?

# 计时器
_profile_now_into() {
    local __var=$1 now=${EPOCHREALTIME:-}
    if [ -n "$now" ]; then
        printf -v "$__var" '%s' "${now/./}"
    else
        printf -v "$__var" '%s' "$(
            perl -MTime::HiRes=time -e 'printf "%.0f", time * 1_000_000'
        )"
    fi
}

if (( REPORT_PROFILE == 1 )); then
    _profile_begin() {
        REPORT_PROFILE_STAGE_LABEL=$1
        _profile_now_into REPORT_PROFILE_STAGE_START_US
    }

    _profile_end() {
        local now_us elapsed_us
        _profile_now_into now_us
        elapsed_us=$((now_us - REPORT_PROFILE_STAGE_START_US))
        (( elapsed_us >= 0 )) || elapsed_us=0
        printf 'REPORT_PROFILE %-20s %6d.%03d ms\n' \
            "$REPORT_PROFILE_STAGE_LABEL" \
            "$((elapsed_us / 1000))" \
            "$((elapsed_us % 1000))" >&2
    }

    _profile_total() {
        local now_us elapsed_us
        _profile_now_into now_us
        elapsed_us=$((now_us - REPORT_PROFILE_SCRIPT_START_US))
        (( elapsed_us >= 0 )) || elapsed_us=0
        printf 'REPORT_PROFILE %-20s %6d.%03d ms\n' \
            'total' \
            "$((elapsed_us / 1000))" \
            "$((elapsed_us % 1000))" >&2
    }

    _profile_now_into REPORT_PROFILE_SCRIPT_START_US
else
    _profile_begin() { :; }
    _profile_end() { :; }
    _profile_total() { :; }
fi

# 左列和右列的最小/最大宽度，单位都是“terminal display columns”。
# NAME_MAX 用来防止某个异常长的字段名把整张表撑得太宽；超长字段名会被截断。
NAME_MIN=13
NAME_MAX=24
DATA_MIN=24
DATA_MAX=100

# 绘图时反复使用的小边框字符。
TOP_LEFT='┌'
TOP_MID='┬'
TOP_RIGHT='┐'
MID_LEFT='├'
MID_MID='┼'
MID_RIGHT='┤'
BOTTOM_LEFT='└'
BOTTOM_MID='┴'
BOTTOM_RIGHT='┘'
HORIZONTAL='─'
DASHED_HORIZONTAL='┄'

# ${C_*} 只含 ANSI 控制码，display_width() 会把它们当 0 列。
# 这些变量里只有终端控制序列，没有可见字符。
# 计算显示宽度时跳过 ANSI 序列，
# 否则会把 \033[1;36m 这 7 个字符也算进列宽，导致表格对不齐、进度条溢出。
C_RESET=''
C_TITLE=''
C_ACCENT=''
C_OK=''
C_WARN=''
C_CRIT=''
C_BAR_USED=''
C_BAR_CACHE=''
C_BAR_FREE=''
C_BAR_AVAILABLE=''
C_BAR_EMPTY=''
C_MEM_TOTAL=''
C_MEM_SHARED=''
C_ENV=''
C_K=''
C_V=''
C_MUTED=''
if [ -n "${FORCE_COLOR:-}" ] || { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; }; then
    C_RESET=$'\033[0m'
    C_TITLE=$'\033[1;36m'
    C_ACCENT=$'\033[1;33m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_CRIT=$'\033[1;31m'
    C_BAR_USED=$'\033[1;34m'
    C_BAR_CACHE=$'\033[1;33m'
    C_BAR_FREE=$'\033[1;32m'
    C_BAR_AVAILABLE=$'\033[1;36m'
    C_BAR_EMPTY=$'\033[2;37m'
    C_MEM_TOTAL=$'\033[1;37m'
    C_MEM_SHARED=$'\033[1;35m'
    C_ENV=$'\033[1;31m'
    C_K=$'\033[1;36m'
    C_V=$'\033[1;33m'
    C_MUTED=$'\033[90m'
fi

