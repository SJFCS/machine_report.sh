#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
#
#
# 终端“服务器报告”表格 + 条形图示例。
# https://github.com/usgraphics/usgc-machine-report

#
# 本脚本的约定：
#   1. 所有可能含中文、ANSI 或图标的宽度、补齐、居中、截断都经过
#      display_width() / fit_display()；只有纯 ASCII 的数字后缀才直接用 ${#}。
#   2. Perl 自带 Unicode 属性匹配，用 East_Asian_Width 和
#      General_Category 判断宽字符、组合符；无需安装 CPAN 包。
#   3. ANSI CSI/OSC 序列占 0 列；私有区字符（Nerd Font）按 1 列处理。
#   4. 单元格只支持单行。超宽内容显示为“…”并保留原始数据，不会撑破边框。
#
# ── 怎样增加字段 ────────────────────────────────────────────────────────
# 按显示顺序调用 add_field 即可，三个底层数组会由函数自动同步：
#   add_field '字段名' '字段值' [分隔线样式]
#
# 第三个参数省略或为 0 时不画分隔线；1 为实线，2 为虚线。
# 字段值可以含中文、ANSI 颜色和 Nerd Font 图标。
#
# 例如在 UPTIME 后面增加一行，并开启一个新分组：
#   add_field 'LAST BOOT' "$(date '+%Y-%m-%d %H:%M')" 1
#
# 字段名和数据列都会自动测量；NAME_W 与 DATA_W 再由上下限夹住。
# 如果新增的字段名比现有列宽更长，可以调整 NAME_MIN / NAME_MAX；如果数据
# 普遍更长，可以调整 DATA_MIN / DATA_MAX。无需修改任何画线函数。
#
# 依赖：Bash、Perl 5、awk。适用于 macOS/Linux。
# 颜色：终端里自动启用；设置 NO_COLOR=1 可关闭，FORCE_COLOR=1 可强制启用。
# 数据：REPORT_MOCK_ENABLED=0（默认）关闭 mock，=1 开启完整演示数据；
#       REPORT_MOCK 作为兼容别名，外部传入 REPORT_MOCK_ENABLED 时优先。
#
# ── 代码分层与函数索引 ──────────────────────────────────────────────────
#
# [MOCK] 演示数据（只影响展示，不负责采集）
#   load_mock_scalars      OS/CPU/负载/内存等固定标量
#   demo_gpu_rows          无 nvidia-smi 时的双 GPU 示例
#   demo_disk_rows         无 lsblk 时的多磁盘示例
#   用法：仅当 REPORT_MOCK_ENABLED=1 时调用；保持变量/TSV 格式不变。
#
# [HANDLER] 实际数据采集（输出纯文本或 TSV，不负责边框、颜色和截断）
#   collect_real_scalars   OS/CPU/负载/内存/运行时间等真实标量
#   dmi_field / darwin_field
#   detect_manufacturer / detect_product_name / detect_virtualization
#   detect_system_uuid / detect_locale / detect_timezone
#   detect_login_user / detect_login_client
#   collect_network_interfaces   输出：IFACE<TAB>IPv4
#   collect_gpu_rows             输出：NAME<TAB>TOTAL<TAB>USED<TAB>UTIL<TAB>MIN<TAB>MAX
#   physical_disk_rows           输出：NAME<TAB>SIZE<TAB>MEDIA<TAB>MOUNTS<TAB>PCT<TAB>USED<TAB>AVAIL<TAB>FORMAT
#   disk_usage_values / collect_disk_mount_map / disk_media_type
#   disk_mount_details / disk_usage_summary
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
#   print_merged_divider / print_centered / print_row
#   bar / percent_bar_display / disk_usage_display
#   gpu_memory_display / gpu_util_display / load_display / stacked_bar
#   用法：add_field 'LABEL' 'VALUE'；measure_fields；print_row LABEL VALUE。
#   TABLE 层只消费已完成的数据，不应调用 lsblk、nvidia-smi 或 dmidecode。
#
# [REPORT] 字段组装与输出
#   本文件后半段按最终显示顺序调用 add_field，再执行 measure_fields，
#   最后填充动态条形图并渲染。新增业务项时应先定义 handler，再组装字段。

set -u
# REPORT_MOCK_ENABLED=1
# NO_COLOR=1

# mock 默认关闭；兼容旧的 REPORT_MOCK 变量，并在入口处拒绝非法开关值。
report_mock_setting=${REPORT_MOCK_ENABLED:-${REPORT_MOCK:-0}}
case $report_mock_setting in
    1|true|TRUE|yes|YES|on|ON) REPORT_MOCK_ENABLED=1 ;;
    0|false|FALSE|no|NO|off|OFF) REPORT_MOCK_ENABLED=0 ;;
    *)
        printf '%s\n' \
            "REPORT_MOCK_ENABLED/REPORT_MOCK 只能是 0/1（也支持 true/false/on/off）：$report_mock_setting" >&2
        exit 2
        ;;
esac

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
    C_BAR_USED=$'\033[1;34m'      # 已用内存用中性蓝色，不表达告警
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

