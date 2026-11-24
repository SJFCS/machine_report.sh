#!/usr/bin/env bash
# shellcheck shell=bash
# -*- coding: utf-8 -*-
# ============================================================
# File    : machine_report.sh
# Author  : song.jinfeng@outlook.com
# Date    : 2026-11-25
# Version : 0.1.1
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
# 依赖：Bash、awk、Perl 5。适用于 macOS/Linux。
# 颜色：终端里自动启用；设置 NO_COLOR=1 可关闭，FORCE_COLOR=1 可强制启用。
# 性能：设置 REPORT_PROFILE=1 后，各采集与渲染阶段的耗时写入 stderr。
# GPU：REPORT_GPU_ENABLED=0 跳过采集；REPORT_GPU_TIMEOUT 控制 nvidia-smi
#      发出终止信号的秒数（默认 1，设为 0 表示不限制）。驱动处于不可中断
#      等待时，信号也可能延迟生效；需要稳定速度时应直接跳过 GPU。
# SMART：需要 smartmontools 的 smartctl。REPORT_SMART_ENABLED=0 跳过采集；
#        REPORT_SMART_TIMEOUT 控制单块磁盘超时秒数（默认 2，0 表示不限制）。
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
# [REPORT] 字段组装与输出
#   本文件后半段按最终显示顺序调用 add_field，再执行 measure_fields，
#   最后填充动态条形图并渲染。新增业务项时应先定义 handler，再组装字段。

set -u
# REPORT_MOCK_ENABLED=1
# REPORT_PROFILE=1
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

report_profile_setting=${REPORT_PROFILE:-0}
case $report_profile_setting in
    1|true|TRUE|yes|YES|on|ON) REPORT_PROFILE=1 ;;
    0|false|FALSE|no|NO|off|OFF) REPORT_PROFILE=0 ;;
    *)
        printf '%s\n' \
            "REPORT_PROFILE 只能是 0/1（也支持 true/false/on/off）：$report_profile_setting" >&2
        exit 2
        ;;
esac

report_gpu_setting=${REPORT_GPU_ENABLED:-1}
case $report_gpu_setting in
    1|true|TRUE|yes|YES|on|ON) REPORT_GPU_ENABLED=1 ;;
    0|false|FALSE|no|NO|off|OFF) REPORT_GPU_ENABLED=0 ;;
    *)
        printf '%s\n' \
            "REPORT_GPU_ENABLED 只能是 0/1（也支持 true/false/on/off）：$report_gpu_setting" >&2
        exit 2
        ;;
esac

report_gpu_timeout=${REPORT_GPU_TIMEOUT:-1}
if ! [[ $report_gpu_timeout =~ ^[0-9]+$ ]]; then
    printf '%s\n' \
        "REPORT_GPU_TIMEOUT 必须是非负整数秒：$report_gpu_timeout" >&2
    exit 2
fi
REPORT_GPU_TIMEOUT=$((10#$report_gpu_timeout))

report_smart_setting=${REPORT_SMART_ENABLED:-1}
case $report_smart_setting in
    1|true|TRUE|yes|YES|on|ON) REPORT_SMART_ENABLED=1 ;;
    0|false|FALSE|no|NO|off|OFF) REPORT_SMART_ENABLED=0 ;;
    *)
        printf '%s\n' \
            "REPORT_SMART_ENABLED 只能是 0/1（也支持 true/false/on/off）：$report_smart_setting" >&2
        exit 2
        ;;
esac

report_smart_timeout=${REPORT_SMART_TIMEOUT:-2}
if ! [[ $report_smart_timeout =~ ^[0-9]+$ ]]; then
    printf '%s\n' \
        "REPORT_SMART_TIMEOUT 必须是非负整数秒：$report_smart_timeout" >&2
    exit 2
fi
REPORT_SMART_TIMEOUT=$((10#$report_smart_timeout))

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

# shellcheck shell=bash
# ── 显示宽度引擎 ───────────────────────────────────────────────────────
#
# 这段 Perl 从标准输入读取 UTF-8 字符串，由 TABLE_MODE 决定行为：
#   width       ：只输出该字符串的显示列数
#   fit         ：在 TABLE_LIMIT 列以内截断，并输出可以安全打印的字符串
#   batch-width ：读取 NUL 分隔的多个字符串，逐项输出 NUL 分隔的宽度
#   render-report：一次输出居中行和字段行，减少一次 Perl 启动
#
# 渲染路径把整张表交给一个 Perl 进程处理，避免每个单元格启动一次解释器。
# 纯 ASCII 和已知单列字符使用下面基于 ${#} 的 Bash 快路径。
#
# 采用 Perl 的 Unicode 属性而不是手写简体中文区间，原因有三点：
#   * 能覆盖中文、日文、韩文、全角符号以及以后新增的宽字符；
#   * 能识别 Mn/Me 组合符和 Cf 格式字符（零宽）；
#   * 私有区字符被单独归为 1 列，符合 Nerd Font 等“单宽图标字体”的常见行为。
#
# 这里还做了基础的“字形簇”合并：组合符、“️”变体选择符、肤色修饰符和
# ZWJ 连字会跟随前一个字符，不会给一个 emoji 家族错误地累计很多列。
# 完整实现 Unicode 字形簇需要 Unicode::GCString 等额外模块；本脚本只使用
# Perl 核心模块，因此对极少数复杂排版序列采用保守的近似处理。
read -r -d '' DISPLAY_WIDTH_PERL <<'PERL'
use strict;
use warnings;
use utf8;

binmode STDIN,  ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';

my $mode  = $ENV{TABLE_MODE}  || 'width';
my $limit = $ENV{TABLE_LIMIT} || 0;
my $text  = do { local $/; <STDIN> };
$text = '' unless defined $text;

# 返回从 $pos 开始的转义序列长度；0 表示当前位置不是 ESC。
# 支持：
#   CSI：\e[ ... 字母      （颜色、光标移动等）
#   OSC：\e] ... BEL/ST     （部分终端超链接、标题等）
#   其他两字节 ESC 序列     （例如 \e(B）
sub escape_length {
    my ($s, $pos) = @_;
    return 0 unless substr($s, $pos, 1) eq "\e";

    my $rest = substr($s, $pos);
    return length($1) if $rest =~ /\A(\e\[[0-?]*[ -\/]*[@-~])/s;
    return length($1) if $rest =~ /\A(\e\][^\x07]*(?:\x07|\e\\))/s;
    return 2 if $rest =~ /\A\e./s;
    return 1;
}

# Unicode 的 East_Asian_Width 为 Wide/Fullwidth 时占两列。
# 这里直接使用 Perl 内置属性匹配，避免每个字符查一次 UCD 表；
# 输出与 Unicode::UCD 的 charprop() 一致，但启动和查询都更快。
# Private_Use 单独按一列处理：Nerd Font 图标属于这个区段，
# 终端通常只为它保留一个单元格，而且它的字节数完全不能用于对齐。
sub base_width {
    my ($char) = @_;
    my $cp = ord($char);
    return 0 if $cp == 0;
    return 0 if $cp < 0x20 || ($cp >= 0x7f && $cp <= 0x9f);

    return 0 if $char =~ /\A(?:\p{Mn}|\p{Me}|\p{Cf})\z/;

    return 1 if ($cp >= 0xe000  && $cp <= 0xf8ff)
             || ($cp >= 0xf0000 && $cp <= 0xffffd)
             || ($cp >= 0x100000 && $cp <= 0x10fffd);

    return 2 if $char =~ /\A(?:\p{EA=Wide}|\p{EA=Fullwidth})\z/;
    return 1;
}

sub is_regional_indicator {
    my ($char) = @_;
    my $cp = ord($char);
    return $cp >= 0x1f1e6 && $cp <= 0x1f1ff;
}

# 跟在基础字符后面、不单独占列的字符。除组合附加符外，还额外处理
# emoji 变体选择符、肤色修饰符以及标签字符（常见于旗帜 emoji 序列）。
sub is_extend {
    my ($char) = @_;
    my $cp = ord($char);
    return 1 if $cp >= 0xfe00  && $cp <= 0xfe0f;       # VS1..VS16
    return 1 if $cp >= 0xe0100 && $cp <= 0xe01ef;      # VS17..VS256
    return 1 if $cp >= 0x1f3fb && $cp <= 0x1f3ff;      # 肤色修饰符
    return 1 if $cp >= 0xe0020 && $cp <= 0xe007f;      # 标签字符

    return $char =~ /\A(?:\p{Mn}|\p{Me}|\p{Cf})\z/;
}

# 把一个“基础字符 + 组合符/ZWJ 连字”组合成一个 token。
# token 保留原字符串，供截断后原样输出；width 用于对齐计算。
sub next_cluster {
    my ($s, $pos_ref) = @_;
    my $start = $$pos_ref;
    my $char = substr($s, $$pos_ref, 1);
    my $cp = ord($char);
    $$pos_ref++;
    my $width = base_width($char);

    # 两个区域指示符组成一面旗帜，整体占两列；只出现一个时按一列近似。
    if (is_regional_indicator($char) && $$pos_ref < length($s)) {
        my $next_char = substr($s, $$pos_ref, 1);
        if (is_regional_indicator($next_char)) {
            $$pos_ref++;
            $width = 2;
        }
    }

    while ($$pos_ref < length($s)) {
        my $next_char = substr($s, $$pos_ref, 1);
        my $next_cp = ord($next_char);

        # ZWJ 连字必须放在通用 extend 判断之前：否则 ZWJ 只会被吞掉，
        # 后面的 emoji 又会被当成新的字形簇，导致整簇被重复计宽。
        if ($next_cp == 0x200d) {
            $$pos_ref++;
            if ($$pos_ref < length($s)) {
                my $joined_char = substr($s, $$pos_ref, 1);
                $$pos_ref++;
                my $joined_width = base_width($joined_char);
                $width = $joined_width if $joined_width > $width;
            }
            next;
        }

        if (is_extend($next_char)) {
            $$pos_ref++;
            next;
        }

        last;
    }

    return [substr($s, $start, $$pos_ref - $start), $width];
}

# token 化时不把颜色码交给宽度计算；同时保持 token 的原始文本。
sub tokenize {
    my ($s) = @_;
    my @tokens;
    my $pos = 0;
    while ($pos < length($s)) {
        my $esc_len = escape_length($s, $pos);
        if ($esc_len > 0) {
            push @tokens, [substr($s, $pos, $esc_len), 0];
            $pos += $esc_len;
            next;
        }
        push @tokens, next_cluster($s, \$pos);
    }
    return @tokens;
}

sub text_width {
    my ($value) = @_;
    my $width = 0;
    $width += $_->[1] for tokenize($value);
    return $width;
}

sub fit_text {
    my ($value, $max) = @_;
    $max = int($max);
    return '' if $max <= 0;

    my @tokens = tokenize($value);
    my $total = 0;
    $total += $_->[1] for @tokens;
    return $value if $total <= $max;

    # 预留一列给省略号。最后一个完整字形簇之后可能还有颜色码，
    # 所以只在确实遇到过 ANSI 时补一个 reset，避免颜色泄漏到后续边框。
    my $budget = $max - 1;
    my $width = 0;
    my $out = '';
    my $used_ansi = 0;
    for my $token (@tokens) {
        my ($chunk, $chunk_width) = @$token;
        if ($chunk_width == 0) {
            $out .= $chunk;
            $used_ansi = 1 if $chunk =~ /\e/;
            next;
        }
        last if $width + $chunk_width > $budget;
        $out .= $chunk;
        $width += $chunk_width;
    }
    $out .= '…';
    $out .= "\e[0m" if $used_ansi;
    return $out;
}

# 表格行需要“截断 + 补空格”。把两步合成一次 token 化，避免每个单元格
# 在同一个 Perl 进程里还要重复扫描字符串。
sub fit_and_pad {
    my ($value, $max) = @_;
    $max = int($max);
    return '' if $max <= 0;

    my @tokens = tokenize($value);
    my $total = 0;
    $total += $_->[1] for @tokens;
    return $value . (' ' x ($max - $total)) if $total <= $max;

    my $budget = $max - 1;
    my $width = 0;
    my $out = '';
    my $used_ansi = 0;
    for my $token (@tokens) {
        my ($chunk, $chunk_width) = @$token;
        if ($chunk_width == 0) {
            $out .= $chunk;
            $used_ansi = 1 if $chunk =~ /\e/;
            next;
        }
        last if $width + $chunk_width > $budget;
        $out .= $chunk;
        $width += $chunk_width;
    }
    $out .= '…';
    $out .= "\e[0m" if $used_ansi;
    $out .= ' ' x ($max - $width - 1) if $max > $width + 1;
    return $out;
}

sub centered_line {
    my ($value, $inner) = @_;
    $inner = int($inner);
    return '' if $inner <= 0;

    my $fitted = fit_text($value, $inner);
    my $width = text_width($fitted);
    my $left = int(($inner - $width) / 2);
    my $right = $inner - $width - $left;
    return '│' . (' ' x $left) . $fitted . (' ' x $right) . '│';
}

sub input_records {
    my @records = split(/\0/, $text, -1);
    pop @records if @records && $records[-1] eq '';
    return @records;
}

if ($mode eq 'batch-width') {
    print text_width($_), "\0" for input_records();
    exit;
}

if ($mode eq 'render-report') {
    my $inner = int($ENV{TABLE_INNER} || 0);
    my $center_count = int($ENV{TABLE_CENTER_COUNT} || 0);
    my $row_count = int($ENV{TABLE_ROWS} || 0);
    my $name_width = int($ENV{TABLE_NAME_W} || 0);
    my $data_width = int($ENV{TABLE_DATA_W} || 0);
    my @records = input_records();
    my @centered = splice(@records, 0, $center_count);
    my @labels = splice(@records, 0, $row_count);

    print 'C', centered_line($_, $inner), "\0" for @centered;
    for my $i (0 .. $row_count - 1) {
        my $label = defined $labels[$i] ? $labels[$i] : '';
        my $value = defined $records[$i] ? $records[$i] : '';
        print 'R',
            '│ ',
            fit_and_pad($label, $name_width),
            ' │ ',
            fit_and_pad($value, $data_width),
            ' │', "\0";
    }
    exit;
}

if ($mode eq 'fit') {
    print fit_text($text, $limit);
    exit;
}

print text_width($text);
PERL

# Bash 正则先存入变量：直接把带空格的字符区间写在 [[ =~ ]] 里会被
# Bash 当成语法分隔符。ANSI 清理和单列宽度判断复用这两个表达式。
# 这些区间必须在 C locale 下匹配，UTF-8 locale 的排序规则不同。
TABLE_ASCII_RE='^[ -~]*$'
TABLE_CSI_RE=$'\e\\[[0-?]*[ -/]*[@-~]'
TABLE_OSC_RE=$'\e\\][^\a]*(\a|\e\\\\)'

_is_ascii_text() {
    local LC_ALL=C
    [[ ${1-} =~ $TABLE_ASCII_RE ]]
}

# [TABLE] _strip_ansi_into VAR TEXT -> 去掉 CSI/OSC 控制序列。
_strip_ansi_into() {
    local LC_ALL=C
    local __var=$1 __strip_text=${2-}
    if [[ $__strip_text == *$'\e'* ]]; then
        while [[ $__strip_text =~ $TABLE_CSI_RE ]]; do
            __strip_text=${__strip_text/"${BASH_REMATCH[0]}"/}
        done
        while [[ $__strip_text =~ $TABLE_OSC_RE ]]; do
            __strip_text=${__strip_text/"${BASH_REMATCH[0]}"/}
        done
    fi
    printf -v "$__var" '%s' "$__strip_text"
}

# [TABLE] _single_width_filter_into VAR TEXT -> 保留已知单列字符。
# 用于快速判断一段文本是否只由 ASCII、边框和进度符号组成；其他宽字符、
# 组合符或控制字符会变成“?”，以便调用方通过比较识别是否走了快路径。
_single_width_filter_into() {
    local LC_ALL=C
    local __var=$1 __single_text __single_char __single_out=''
    _strip_ansi_into __single_text "${2-}"

    while [[ -n $__single_text ]]; do
        __single_char=${__single_text:0:1}
        __single_text=${__single_text:1}
        case $__single_char in
            [\ -~]) __single_out+=$__single_char ;;
            '─'|'│'|'┌'|'┐'|'└'|'┘'|'├'|'┤'|'┬'|'┴'|'┼'|'┄')
                __single_out+=$__single_char
                ;;
            '█'|'▓'|'░'|'·'|'…'|'●'|'–')
                __single_out+=$__single_char
                ;;
            *) __single_out+='?' ;;
        esac
    done
    printf -v "$__var" '%s' "$__single_out"
}

# [TABLE] _simple_display_width_into VAR TEXT -> 单列字符的 Bash 快路径。
# 去掉 ANSI 后，如果剩余字符全部在单列白名单中，此时 ${#text} 就是显示
# 宽度；发现宽字符或组合符时返回 1，交给 Perl 精确计算。
_simple_display_width_into() {
    local __var=$1 plain allowed
    _strip_ansi_into plain "${2-}"
    _single_width_filter_into allowed "$plain"
    [[ $allowed == "$plain" ]] || return 1
    printf -v "$__var" '%s' "${#plain}"
}

# [TABLE] _truncate_bash_into VAR TEXT MAX MARK -> ASCII 快路径截断。
_truncate_bash_into() {
    local __var=$1 __trunc_text=$2 max=$3 mark=$4 __trunc_value
    if (( max <= 0 )); then
        __trunc_value=''
    elif (( ${#__trunc_text} > max )); then
        __trunc_value="${__trunc_text:0:max-1}${mark}"
    else
        __trunc_value=$__trunc_text
    fi
    printf -v "$__var" '%s' "$__trunc_value"
}

# [TABLE] display_width TEXT -> 输出终端显示列数。
# 纯 ASCII 和已确认的单列 Unicode 不启动进程；复杂文本交给 Perl。
# 用法：columns=$(display_width "$cell")
display_width() {
    local text=${1-} simple_width
    if _is_ascii_text "$text"; then
        printf '%s' "${#text}"
        return
    fi
    if _simple_display_width_into simple_width "$text"; then
        printf '%s' "$simple_width"
        return
    fi
    printf '%s' "$text" |
        TABLE_MODE=width perl -CS -e "$DISPLAY_WIDTH_PERL"
}

# [TABLE] _fit_display_into VAR TEXT MAX -> 截断后写入指定变量。
_fit_display_into() {
    local __var=$1 __fit_text=$2 max=${3:-0}
    local __fit_result
    [[ $max =~ ^[0-9]+$ ]] || max=0

    if _is_ascii_text "$__fit_text"; then
        _truncate_bash_into "$__var" "$__fit_text" "$max" '…'
        return
    fi
    __fit_result=$(printf '%s' "$__fit_text" |
        TABLE_MODE=fit TABLE_LIMIT="$max" \
            perl -CS -e "$DISPLAY_WIDTH_PERL")
    printf -v "$__var" '%s' "$__fit_result"
}

# [TABLE] fit_display TEXT MAX -> 按显示列数截断，超宽时以“…”结尾。
# 用法：fitted=$(fit_display "$long_text" 40)
fit_display() {
    local text=${1-} max=${2:-0} fitted
    _fit_display_into fitted "$text" "$max"
    printf '%s' "$fitted"
}

# [TABLE] repeat_char CHAR COUNT -> 重复单列字符，用于边框和条形图。
# 只接受单列字符；不要把中文或 ANSI 字符串传进来。
# 用法：line=$(repeat_char '─' 20)
repeat_char() {
    local char=$1 count=$2 out
    (( count > 0 )) || return 0
    printf -v out '%*s' "$count" ''
    printf '%s' "${out// /$char}"
}

# [TABLE] _pad_display_into VAR TEXT WIDTH [CURRENT_WIDTH]
# 左对齐并用 ASCII 空格补齐；CURRENT_WIDTH 可跳过再次测量。
_pad_display_into() {
    local __var=$1 __pad_text=$2 width=${3:-0} current=${4-}
    [[ $width =~ ^[0-9]+$ ]] || width=0

    if _is_ascii_text "$__pad_text"; then
        current=${#__pad_text}
    elif [[ -z $current ]]; then
        current=$(display_width "$__pad_text")
    fi

    if (( current < width )); then
        printf -v "$__var" '%s%*s' "$__pad_text" "$((width - current))" ''
    else
        printf -v "$__var" '%s' "$__pad_text"
    fi
}

# [TABLE] pad_display TEXT WIDTH -> 左对齐并用 ASCII 空格补齐。
# 用法：padded=$(pad_display "$text" 20)
pad_display() {
    local text=${1-} width=${2:-0} padded
    _pad_display_into padded "$text" "$width"
    printf '%s' "$padded"
}

# [TABLE] _display_widths_batch VALUE... -> 输出 NUL 分隔的宽度。
# 纯 ASCII/单列文本批次不启动进程；复杂 Unicode/ANSI 只启动一个 Perl。
_display_widths_batch() {
    local text simple_width context_width needs_perl=0
    local -a computed=()

    for text in "$@"; do
        if _is_ascii_text "$text"; then
            computed+=("${#text}")
        elif _simple_display_width_into simple_width "$text"; then
            computed+=("$simple_width")
        else
            needs_perl=1
            break
        fi
    done
    if (( needs_perl == 0 )); then
        for context_width in "${computed[@]}"; do
            printf '%s\0' "$context_width"
        done
        return
    fi

    printf '%s\0' "$@" |
        TABLE_MODE=batch-width perl -CS -e "$DISPLAY_WIDTH_PERL"
}

# [TABLE] max_display_width VALUE... -> 返回最大显示列数。
# 传入数组时必须写成 "${array[@]}"，避免元素内空格被拆成新参数。
# 用法：width=$(max_display_width "${FIELD_LABELS[@]}")
max_display_width() {
    local width max=0
    while IFS= read -r -d '' width; do
        [[ $width =~ ^[0-9]+$ ]] || width=0
        (( width > max )) && max=$width
    done < <(_display_widths_batch "$@")
    printf '%s' "$max"
}

# [TABLE] max_tsv_column_width COLUMN ROW... -> TSV 指定列的最大显示宽度。
# COLUMN 从 0 开始；记录通过参数传入，不依赖固定全局数组名。
# 用法：w=$(max_tsv_column_width 1 "${rows[@]}")
max_tsv_column_width() {
    local column=$1
    shift
    local row width max=0
    local -a cells=()
    local -a column_values=()
    for row in "$@"; do
        IFS=$'\t' read -r -a cells <<<"$row"
        column_values+=("${cells[column]:-}")
    done
    if (( ${#column_values[@]} == 0 )); then
        printf '0'
        return
    fi
    while IFS= read -r -d '' width; do
        [[ $width =~ ^[0-9]+$ ]] || width=0
        (( width > max )) && max=$width
    done < <(_display_widths_batch "${column_values[@]}")
    printf '%s' "$max"
}

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
# shellcheck shell=bash
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

    if [ "$platform_name" = Darwin ]; then
        model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
        [ -n "$model" ] || model=$(sysctl -n hw.model 2>/dev/null)
        total_cores=$(sysctl -n hw.ncpu 2>/dev/null)
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
    local values=''
    local -a load_values=()
    if [ "$platform_name" = Darwin ]; then
        values=$(sysctl -n vm.loadavg 2>/dev/null)
    elif [ -r /proc/loadavg ]; then
        read -r load1 load5 load15 values < /proc/loadavg || true
        [ -n "${load1:-}" ] && [ -n "${load5:-}" ] && [ -n "${load15:-}" ] &&
            return
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
kernel_summary="${platform_name} ${kernel_version} · ${server_arch}"

# 主机名
hostname=$(hostname 2>/dev/null)
[ -n "$hostname" ] || hostname='unknown'
full_hostname=$(hostname -f 2>/dev/null)
[ -n "$full_hostname" ] || full_hostname='unknown'

cpu_model_width=$(max_display_width "${cpu_models[@]}")
cores="${cpu_cores} vCPU(s) / ${cpu_sockets} Socket(s)"
_profile_end

# shellcheck shell=bash
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
    local key=$1
    ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
        awk -F'"' -v key="$key" '$2 == key { print $4; exit }'
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

# [HANDLER] detect_login_user -> 当前登录用户，who 为空时回退环境变量。
# 用法：user=$(detect_login_user)
detect_login_user() {
    local user
    read -r user _ < <(who am i 2>/dev/null) || true
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
        line=$(who am i 2>/dev/null | sed -n '1p')
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
format_percent_text() {
    local value=${1-} text
    if ! is_number "$value"; then
        printf '%6s' '-'
        return 0
    fi
    if ! printf -v text '%5.1f%%' "$value" 2>/dev/null; then
        printf '%6s' '-'
        return 0
    fi
    case $text in
        *[Nn][Aa][Nn]*|*[Ii][Nn][Ff]*) printf '%6s' '-' ;;
        *) printf '%s' "$text" ;;
    esac
}

# [FORMAT] format_percent_suffix VALUE -> 带一个前导空格的百分比后缀。
# 用法：suffix=$(format_percent_suffix 82.5)；宽度=${#suffix}
format_percent_suffix() {
    printf ' %s' "$(format_percent_text "${1-}")"
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

# shellcheck shell=bash
#
# [FORMAT] align_row_ends LEFT RIGHT [WIDTH] -> 两端对齐到一行。
# 两侧都可以带 ANSI；省略 WIDTH 时使用当前 DATA_W。
# 用法：line=$(align_row_ends "$left" "$right")

align_row_ends() {
    local left=$1 right=$2 width=${3:-$DATA_W} gap
    gap=$((width - $(display_width "$left") - $(display_width "$right")))
    (( gap >= 1 )) || gap=1
    printf '%s%*s%s' "$left" "$gap" '' "$right"
}

# [FORMAT] format_quantity QTY UNIT COLOR WIDTH -> 左对齐数量 + 固定单位。
# 用法：cell=$(format_quantity 13.2 GiB "$C_V" 5)
format_quantity() {
    local quantity=${1-} unit=${2-} color=${3-} width=${4:-0}
    [[ $width =~ ^[0-9]+$ ]] || width=0
    printf '%s%-*s %s%s' "$color" "$width" "$quantity" "$unit" "$C_RESET"
}

# [FORMAT] format_mem_quantity QTY COLOR -> 带 GiB 且单位纵向对齐。
# 用法：cell=$(format_mem_quantity 13.2 "$C_BAR_USED")
format_mem_quantity() {
    format_quantity "$1" 'GiB' "$2" "$MEM_QTY_W"
}

# [FORMAT] align_mem_percent LABEL PCT COLOR -> 左数量、右百分比的整行值。
# 用法：row=$(align_mem_percent "$display" 82.5 "$C_BAR_USED")
align_mem_percent() {
    local metric=$1 percent=$2 color=$3 percent_text
    percent_text=$(format_percent_text "$percent")
    align_row_ends "$metric" "${color}${percent_text}${C_RESET}"
}

mem_used_percent=$(percent_of "$mem_used" "$mem_total")
mem_free_percent=$(percent_of "$mem_free" "$mem_total")
mem_shared_percent=$(percent_of "$mem_shared" "$mem_total")
mem_cache_percent=$(percent_of "$mem_cache" "$mem_total")
mem_available_percent=$(percent_of "$mem_available" "$mem_total")

# 统一格式化为一位小数，避免 16 和 3.2 的小数点无法纵向对齐。
printf -v mem_total_qty     '%.1f' "$mem_total"
printf -v mem_used_qty      '%.1f' "$mem_used"
printf -v mem_free_qty      '%.1f' "$mem_free"
printf -v mem_shared_qty    '%.1f' "$mem_shared"
printf -v mem_cache_qty     '%.1f' "$mem_cache"
printf -v mem_available_qty '%.1f' "$mem_available"

MEM_QTY_W=$(max_display_width \
    "$mem_total_qty" "$mem_used_qty" "$mem_free_qty" \
    "$mem_shared_qty" "$mem_cache_qty" "$mem_available_qty")

# “是否正常”看 available，而不是看 used：used 高不代表新进程没有内存
# 可用，因为 buff/cache 中可以回收一部分。阈值可按业务调整；这里采用
# 常见默认值：available >= 20% 正常，10%~20% 偏紧，< 10% 危险。
MEM_OK_PERCENT=20
MEM_WARN_PERCENT=10

# [FORMAT] memory_status_text PCT OK_THRESHOLD WARN_THRESHOLD -> 彩色状态。
# 状态只依据 available 百分比，不依据 used。
# 用法：status=$(memory_status_text 8.8 20 10)
memory_status_text() {
    local percent=$1 ok=$2 warn=$3 state='crit'
    local scaled_percent
    if _number_to_scaled_into scaled_percent "$percent" 1; then
        if (( scaled_percent >= ok * 10 )); then
            state='ok'
        elif (( scaled_percent >= warn * 10 )); then
            state='warn'
        fi
    fi
    case "$state" in
        ok)   printf '%s●可用内存正常%s' "$C_OK" "$C_RESET" ;;
        warn) printf '%s●可用内存偏紧%s' "$C_WARN" "$C_RESET" ;;
        *)    printf '%s●可用内存危险%s' "$C_CRIT" "$C_RESET" ;;
    esac
}

mem_status=$(memory_status_text \
    "$mem_available_percent" "$MEM_OK_PERCENT" "$MEM_WARN_PERCENT")

# TOTAL 只显示容量；健康状态放在该行末尾，并明确标明它评估的是可用内存。
total_display=$(format_mem_quantity "$mem_total_qty" "$C_MEM_TOTAL")
used_display=$(format_mem_quantity "$mem_used_qty" "$C_BAR_USED")
free_display=$(format_mem_quantity "$mem_free_qty" "$C_BAR_FREE")
shared_display=$(format_mem_quantity "$mem_shared_qty" "$C_MEM_SHARED")
cache_display=$(format_mem_quantity "$mem_cache_qty" "$C_BAR_CACHE")
available_display=$(format_mem_quantity \
    "$mem_available_qty" "$C_BAR_AVAILABLE")

FIELD_LABELS=()
FIELD_VALUES=()
FIELD_BREAK_BEFORE=()

# ── [TABLE] 字段注册与值对齐 ───────────────────────────────────────────

# [TABLE] add_field LABEL VALUE [BREAK] -> 追加一行字段。
# BREAK：0 不画线，1 实线，2 虚线；FIELD_INDEX 保存刚追加的行号。
# 用法：add_field 'UPTIME' '2h 10m' 1；row=$FIELD_INDEX
add_field() {
    FIELD_LABELS+=("$1")
    FIELD_VALUES+=("${2-}")
    FIELD_BREAK_BEFORE+=("${3:-0}")
    FIELD_INDEX=$((${#FIELD_LABELS[@]} - 1))
}

# [FORMAT] color_kv_segment "KEY VALUE" -> 青色键、黄色值。
# 没有空格的段落整段按值着色，适合 '-' 等占位符。
# 用法：colored=$(color_kv_segment 'TYPE SSD')
color_kv_segment() {
    local part=$1 key value
    if [[ "$part" == *" "* ]]; then
        key=${part%% *}
        value=${part#* }
        printf '%s%s%s %s%s%s' \
            "$C_K" "$key" "$C_RESET" \
            "$C_V" "$value" "$C_RESET"
    else
        printf '%s%s%s' "$C_V" "$part" "$C_RESET"
    fi
}

# [FORMAT] color_kv_segments TEXT -> 统一着色以 " · " 分隔的 KV 段落。
# 只处理颜色和分隔符，不补齐宽度；应先用 pad_display 对齐各列。
# 用法：colored=$(color_kv_segments 'DISK sda · TYPE SSD')
color_kv_segments() {
    local rest=$1 part out=''
    while [[ "$rest" == *" · "* ]]; do
        part=${rest%% · *}
        out+="$(color_kv_segment "$part") · "
        rest=${rest#* · }
    done
    out+=$(color_kv_segment "$rest")
    printf '%s' "$out"
}

# shellcheck shell=bash
#
# ── [REPORT] 静态字段组装 ──────────────────────────────────────────────

# 按最终显示顺序组装字段。LOAD、GPU 和内存条形图先留空，测量列宽后再填。
add_field 'OS'          "$os_name"
add_field 'KERNEL'      "$kernel_summary"
add_field 'VIRT'        "$virt_type"
add_field 'LOCALE'      "$locale_name"
add_field 'TIMEZONE'    "$timezone_name"
add_field 'SERVER'      "${server_manufacturer} · ${server_product_name}"
add_field 'SYSTEM UUID' "$system_uuid"
add_field 'UPTIME'      "$uptime"
add_field 'HOSTNAME'    "$hostname"     1
_profile_begin 'network'
dns_servers=$(collect_dns_servers)
add_field 'DNS' "${dns_servers:--}"
primary_ip=''
while IFS=$'\t' read -r nic_name nic_ip; do
    [ -n "$nic_name" ] || continue
    [ -n "$primary_ip" ] || primary_ip=$nic_ip
    add_field "NIC $nic_name" "$nic_ip"
done < <(collect_network_interfaces)
if [ -z "$primary_ip" ]; then
    add_field 'NIC' '-'
    primary_ip='UNKNOWN'
fi
_profile_end
server_display="${C_K}SERVER${C_RESET} ${C_V}${login_user}@${hostname} ${primary_ip}${C_RESET}"
client_display="${C_MUTED}CLIENT ${login_client}${C_RESET}"
for i in "${!cpu_models[@]}"; do
    break_before=0
    [ "$i" -eq 0 ] && break_before=1
    model=$(pad_display "${cpu_models[i]}" "$cpu_model_width")
    add_field "CPU $i" "$model · ${cpu_freqs[i]}" "$break_before"
done
add_field 'CORES'       "$cores"
add_field 'LOAD 1m'     ''              # 条形图在下面计算后填入
LOAD_1M_ROW=$FIELD_INDEX
add_field 'LOAD 5m'     ''
LOAD_5M_ROW=$FIELD_INDEX
add_field 'LOAD 15m'    ''
LOAD_15M_ROW=$FIELD_INDEX

# GPU 按实际数量逐块展开；MEM、UTIL 条形图留到列宽确定后再填充。
GPU_RECORDS=()
GPU_MEM_ROWS=()
GPU_UTIL_ROWS=()
GPU_IDENTITY_LINES=()
gpu_index=0
_profile_begin 'gpu'
while IFS=$'\t' read -r gpu_name gpu_total gpu_used gpu_util \
    gpu_min_mhz gpu_max_mhz gpu_metrics; do
    [ -n "$gpu_name" ] || continue
    gpu_break=0
    [ "$gpu_index" -eq 0 ] && gpu_break=1
    gpu_identity=$gpu_name
    if [[ $gpu_total =~ ^[0-9]+$ ]] && (( gpu_total > 0 )); then
        gpu_identity="$gpu_identity · $(format_mib_as_gib "$gpu_total") GiB"
    fi
    gpu_freq=$(format_gpu_frequency "$gpu_min_mhz" "$gpu_max_mhz")
    [ "$gpu_freq" = '-' ] || gpu_identity="$gpu_identity · $gpu_freq"
    GPU_IDENTITY_LINES+=("$gpu_identity")
    add_field "GPU $gpu_index" "$gpu_identity" "$gpu_break"
    if [ "$gpu_metrics" = 1 ]; then
        add_field "GPU $gpu_index MEM" ''
        GPU_MEM_ROWS+=("$FIELD_INDEX")
        add_field "GPU $gpu_index UTIL" ''
        GPU_UTIL_ROWS+=("$FIELD_INDEX")
        GPU_RECORDS+=(
            "$gpu_used"$'\t'"$gpu_total"$'\t'"$gpu_util"
        )
    fi
    gpu_index=$((gpu_index + 1))
done < <(collect_gpu_rows)
if [ "$gpu_index" -eq 0 ]; then
    add_field 'GPU' '-' 1
fi
_profile_end

# 内存区：TOTAL 带健康状态，其余行在第二轮补百分比。
add_field 'MEM TOTAL'   "$total_display" 1
MEM_TOTAL_ROW=$FIELD_INDEX
add_field 'MEM USAGE'   ''              # 分段堆叠条在下面计算后填入
MEM_BAR_ROW=$FIELD_INDEX
add_field 'MEM USED'    "$used_display"
MEM_USED_ROW=$FIELD_INDEX
add_field 'BUFF/CACHE'  "$cache_display"
MEM_CACHE_ROW=$FIELD_INDEX
add_field 'MEM FREE'    "$free_display"
MEM_FREE_ROW=$FIELD_INDEX
add_field 'MEM SHARED'  "$shared_display"
MEM_SHARED_ROW=$FIELD_INDEX
add_field 'MEM AVAILABLE' "$available_display"
MEM_AVAILABLE_ROW=$FIELD_INDEX

# 磁盘区先收集原始记录，再统一计算三列宽度，避免每块磁盘各算一次。
DISK_BAR_ROWS=()
DISK_BAR_PCTS=()
DISK_DEVICE_ROWS=()
DISK_SPACE_ROWS=()
DISK_MOUNTS=()
DISK_PCTS=()
DISK_HEALTH=()
DISK_WEAR=()
DISK_ERR_LABELS=()
DISK_ERR_COUNTS=()
_profile_begin 'disk collect'
while IFS=$'\t' read -r disk_name disk_size disk_media disk_mounts \
    disk_pct disk_used disk_avail disk_format disk_health disk_wear \
    disk_err_label disk_err_count; do
    [ -n "$disk_name" ] || continue
    DISK_DEVICE_ROWS+=(
        "DISK $disk_name"$'\t'"TYPE $disk_media"$'\t'"FORMAT ${disk_format//,/, }"
    )
    DISK_SPACE_ROWS+=(
        "TOTAL $disk_size"$'\t'"USED $disk_used"$'\t'"AVAIL $disk_avail"
    )
    DISK_MOUNTS+=("${disk_mounts//,/, }")
    DISK_PCTS+=("$disk_pct")
    DISK_HEALTH+=("${disk_health:-N/A}")
    DISK_WEAR+=("${disk_wear:--}")
    DISK_ERR_LABELS+=("${disk_err_label:-INTEG}")
    DISK_ERR_COUNTS+=("${disk_err_count:--}")
done < <(physical_disk_rows)
_profile_end

# [TABLE] format_disk_columns C1 C2 C3 -> 使用 DISK_COL*_W 补齐后拼接。
# 用法：line=$(format_disk_columns "DISK $name" "TYPE $media" "FORMAT $fmt")
format_disk_columns() {
    printf '%s · %s · %s' \
        "$(pad_display "$1" "$DISK_COL1_W")" \
        "$(pad_display "$2" "$DISK_COL2_W")" \
        "$(pad_display "$3" "$DISK_COL3_W")"
}

# 三列宽度由 DEVICE 和 SPACE 两类记录共同决定，保证上下两行用同一组
# 分隔符位置。记录内部使用 TAB，因此挂载点或型号中的空格不会干扰分列。
_profile_begin 'disk layout'
if [ "${#DISK_DEVICE_ROWS[@]}" -gt 0 ]; then
    DISK_COL1_W=$(max_tsv_column_width 0 \
        "${DISK_DEVICE_ROWS[@]}" "${DISK_SPACE_ROWS[@]}")
    DISK_COL2_W=$(max_tsv_column_width 1 \
        "${DISK_DEVICE_ROWS[@]}" "${DISK_SPACE_ROWS[@]}")
    DISK_COL3_W=$(max_tsv_column_width 2 \
        "${DISK_DEVICE_ROWS[@]}" "${DISK_SPACE_ROWS[@]}")

    for i in "${!DISK_DEVICE_ROWS[@]}"; do
        IFS=$'\t' read -r dev_a dev_b dev_c <<<"${DISK_DEVICE_ROWS[i]}"
        IFS=$'\t' read -r sp_a sp_b sp_c <<<"${DISK_SPACE_ROWS[i]}"
        dev_line=$(format_disk_columns "$dev_a" "$dev_b" "$dev_c")
        space_line=$(format_disk_columns "$sp_a" "$sp_b" "$sp_c")
        disk_break=1
        [ "$i" -gt 0 ] && disk_break=2
        add_field 'DEVICE' \
            "$(color_kv_segments "$dev_line")" "$disk_break"
        add_field 'SPACE' \
            "$(color_kv_segments "$space_line")"
        if is_number "${DISK_PCTS[i]}"; then
            add_field 'DISK USAGE' ''
            DISK_BAR_ROWS+=("$FIELD_INDEX")
            DISK_BAR_PCTS+=("${DISK_PCTS[i]}")
        else
            add_field 'DISK USAGE' '-'
        fi
        add_field 'MOUNTS' "${DISK_MOUNTS[i]}"
        smart_wear=${DISK_WEAR[i]:--}
        case $smart_wear in
            ''|-) smart_wear='-' ;;
            *[!0-9]*) ;;
            *) smart_wear="${smart_wear}%" ;;
        esac
        smart_err_label=${DISK_ERR_LABELS[i]:-INTEG}
        smart_err_count=${DISK_ERR_COUNTS[i]:--}
        add_field 'SMART' "$(color_kv_segments \
            "HEALTH ${DISK_HEALTH[i]:-N/A} · WEAR $smart_wear · $smart_err_label $smart_err_count")"
    done
else
    add_field 'DEVICE' \
        "$(color_kv_segments 'DISK - · TYPE - · FORMAT -')" 1
    add_field 'SPACE' \
        "$(color_kv_segments 'TOTAL - · USED - · AVAIL -')"
    add_field 'MOUNTS' '-'
    add_field 'SMART' \
        "$(color_kv_segments 'HEALTH N/A · WEAR - · INTEG -')"
fi
_profile_end

# shellcheck shell=bash
# ── [TABLE] 布局测量 ───────────────────────────────────────────────────

# [TABLE] measure_fields -> 根据 FIELD_LABELS/FIELD_VALUES 计算 NAME_W/DATA_W。
# 需在静态字段全部 add_field 之后、条形图回填之前调用。
# 用法：measure_fields
# 注意：此时条形图值还是空串；条形图会主动使用 DATA_W，因此不会反过来
# 把数据列撑宽。
measure_fields() {
    NAME_W=$(max_display_width "${FIELD_LABELS[@]}")
    (( NAME_W < NAME_MIN )) && NAME_W=$NAME_MIN
    (( NAME_W > NAME_MAX )) && NAME_W=$NAME_MAX

    DATA_W=$(max_display_width "${FIELD_VALUES[@]}")
    (( DATA_W < DATA_MIN )) && DATA_W=$DATA_MIN
    (( DATA_W > DATA_MAX )) && DATA_W=$DATA_MAX
}

# [TABLE] ensure_centered_width TEXT -> 扩展 DATA_W 以完整容纳跨列文本。
# 两侧至少预留一个空格，避免文字贴住左右边框。
# 用法：ensure_centered_width "$server_display"
ensure_centered_width() {
    local text=$1 inner text_width required
    inner=$((NAME_W + DATA_W + 5))
    text_width=$(display_width "$text")
    required=$((text_width + 2))
    if (( required > inner )); then
        DATA_W=$((DATA_W + required - inner))
    fi
}

# [TABLE] ensure_data_width TEXT -> 保证指定值至少占 DATA_W 宽。
# 用于 GPU 型号/显存/频率等不允许截断的关键行。
# 用法：ensure_data_width "$gpu_identity"
ensure_data_width() {
    local text=$1 text_width
    text_width=$(display_width "$text")
    (( text_width > DATA_W )) && DATA_W=$text_width
}

# ── 表格绘制 ───────────────────────────────────────────────────────────

# [TABLE] print_divider LEFT MIDDLE RIGHT [CHAR] -> 两列之间的横线。
# 名字列和数据列各加一格内边距，宽度与字段行一致。
# 用法：print_divider "$MID_LEFT" "$MID_MID" "$MID_RIGHT"
print_divider() {
    local left=$1 middle=$2 right=$3
    local line_char=${4:-$HORIZONTAL}
    printf '%s%s%s%s%s\n' \
        "$left" \
        "$(repeat_char "$line_char" "$((NAME_W + 2))")" \
        "$middle" \
        "$(repeat_char "$line_char" "$((DATA_W + 2))")" \
        "$right"
}

# [TABLE] print_dashed_divider -> 两列之间的虚线分隔，用于磁盘之间。
# 用法：print_dashed_divider
print_dashed_divider() {
    print_divider \
        "$MID_LEFT" "$MID_MID" "$MID_RIGHT" "$DASHED_HORIZONTAL"
}

# [TABLE] print_header -> 输出无内部竖线的表格顶边。
# 用法：print_header
print_header() {
    print_merged_divider "$TOP_LEFT" "$TOP_RIGHT"
}

# [TABLE] print_merged_divider LEFT RIGHT -> 跨两列的连续横线。
# 用于标题区或页脚的合并行，不在中间插入 ┬/┴。
# 用法：print_merged_divider "$TOP_LEFT" "$TOP_RIGHT"
print_merged_divider() {
    local left=$1 right=$2
    printf '%s%s%s\n' \
        "$left" \
        "$(repeat_char "$HORIZONTAL" "$((NAME_W + DATA_W + 5))")" \
        "$right"
}

# [TABLE] _format_report_lines TEXT... -> 一次 Perl 输出全部渲染行。
# 记录以 NUL 分隔，开头 C 表示居中行、R 表示字段行。这样标题区和表格
# 共用一次 Perl 启动，同时分隔线仍由 Bash 控制。
_format_report_lines() {
    local inner=$((NAME_W + DATA_W + 5))
    local center_count=$#
    local row_count=${#FIELD_LABELS[@]}

    printf '%s\0' "$@" "${FIELD_LABELS[@]}" "${FIELD_VALUES[@]}" |
        TABLE_MODE=render-report \
            TABLE_INNER="$inner" \
            TABLE_CENTER_COUNT="$center_count" \
            TABLE_ROWS="$row_count" \
            TABLE_NAME_W="$NAME_W" \
            TABLE_DATA_W="$DATA_W" \
            perl -CS -e "$DISPLAY_WIDTH_PERL"
}

# [TABLE] bar USED TOTAL [WIDTH] -> 无颜色横向百分比条。
# 条形字符本身都是单列字符，所以这里可以直接用 repeat_char()；
# 普通十进制先转成定点整数计算块数；异常输入才回退 awk。
# 省略 WIDTH 时使用 DATA_W。
# 用法：graph=$(bar 42.5 100 20)
bar() {
    local used=${1-0} total=${2-0} width=${3:-${DATA_W:-0}}
    local blocks scaled_used scaled_total

    is_number "$used" || used=0
    is_number "$total" || total=0
    [[ $width =~ ^[0-9]+$ ]] || width=0

    if _number_to_scaled_into scaled_used "$used" 6 &&
        _number_to_scaled_into scaled_total "$total" 6; then
        if (( scaled_total <= 0 || width <= 0 || scaled_used <= 0 )); then
            blocks=0
        else
            blocks=$(((scaled_used * width) / scaled_total))
            (( blocks > width )) && blocks=$width
        fi
    else
        blocks=$(awk -v u="$used" -v t="$total" -v w="$width" 'BEGIN {
            if (t <= 0 || w <= 0) { print 0; exit }
            n = int(((u / t) * 100 / 100) * w)
            if (n < 0) n = 0
            if (n > w) n = w
            print n
        }')
    fi

    printf '%s%s' \
        "$(repeat_char '█' "$blocks")" \
        "$(repeat_char '░' "$((width - blocks))")"
}

# [TABLE] percent_bar_display VALUE TOTAL PERCENT -> 条形图 + 百分比文本。
# 用法：cell=$(percent_bar_display 42.5 100 42.5)
percent_bar_display() {
    local value=$1 total=$2 percent=$3 suffix graph_width
    suffix=$(format_percent_suffix "$percent")
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    printf '%s%s' "$(bar "$value" "$total" "$graph_width")" "$suffix"
}

# [FORMAT] disk_usage_display PERCENT -> 磁盘使用率条形图值列。
# 用法：cell=$(disk_usage_display 42.5)
disk_usage_display() {
    local percent=$1
    percent_bar_display "$percent" 100 "$percent"
}

# [FORMAT] gpu_memory_display USED_MIB TOTAL_MIB -> 显存条形图和 GiB 文本。
# 用法：cell=$(gpu_memory_display 64000 81920)
gpu_memory_display() {
    local used_mib=$1 total_mib=$2
    local percent used_gib total_gib suffix graph_width
    percent=$(percent_of "$used_mib" "$total_mib")
    used_gib=$(format_mib_as_gib "$used_mib")
    total_gib=$(format_mib_as_gib "$total_mib")
    printf -v suffix ' %s/%s GiB %s' \
        "$used_gib" "$total_gib" "$(format_percent_text "$percent")"
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    printf '%s%s' \
        "$(bar "$used_mib" "$total_mib" "$graph_width")" "$suffix"
}

# [FORMAT] gpu_util_display PERCENT -> GPU 利用率条形图值列。
# 用法：cell=$(gpu_util_display 91)
gpu_util_display() {
    local percent=$1
    percent_bar_display "$percent" 100 "$percent"
}

# [FORMAT] load_display LOAD CPU_COUNT -> 负载条、负载/核数和百分比。
# 用法：cell=$(load_display 25.60 128)
load_display() {
    local load=$1 cores=$2
    local percent load_text percent_text suffix
    local graph_width

    percent=$(percent_of "$load" "$cores")
    if is_number "$load"; then
        printf -v load_text '%5.2f' "$load"
    else
        load_text='    -'
    fi
    percent_text=$(format_percent_text "$percent")
    # 先拼出完整的右侧文字，再按实际长度扣减条形宽度，避免每加一个
    # 分隔符就要同步修改一个魔法数字。
    printf -v suffix ' %s/%s %s' "$load_text" "$cores" "$percent_text"
    graph_width=$((DATA_W - ${#suffix}))
    (( graph_width > 0 )) || graph_width=1
    printf '%s%s' "$(bar "$load" "$cores" "$graph_width")" "$suffix"
}

# [TABLE] stacked_bar TOTAL WIDTH VALUE CHAR COLOR ... -> 彩色分段堆叠条。
#
# 用法：
#   stacked_bar TOTAL WIDTH VALUE CHAR COLOR [VALUE CHAR COLOR ...]
#
# 例如内存条：
#   stacked_bar 16 32 3.2 '█' "$C_BAR_USED" \
#                      9.6 '▓' "$C_BAR_CACHE" \
#                      3.2 '░' "$C_BAR_FREE"
#
# 每个三元组是一段：数值、绘制字符、ANSI 颜色。各段按 VALUE / TOTAL
# 的比例分配列宽；不足 TOTAL 的空隙用暗色 ░ 补齐。块数用“最大余数法”
# 分配，保证所有段加背景严格等于 WIDTH，不会多一列或少一列。
#
# 字符用 █ / ▓ / ░ 区分，即使 NO_COLOR=1 或输出到日志文件，也能看出
# 三段结构；终端里则由颜色进一步区分 used、buff/cache 和 free。
stacked_bar() {
    local total=${1-0} width=${2-0}
    shift 2

    is_number "$total" || total=0
    [[ $width =~ ^[0-9]+$ ]] || width=0

    if (( $# % 3 != 0 )); then
        printf 'stacked_bar: 段参数必须按 VALUE CHAR COLOR 三元组传入\n' >&2
        return 2
    fi

    local -a values=()
    local -a chars=()
    local -a colors=()
    while (( $# >= 3 )); do
        values+=("$1")
        chars+=("$2")
        colors+=("$3")
        shift 3
    done

    if (( ${#values[@]} == 0 || width <= 0 )); then
        return 0
    fi

    # 先算每段占多少个字符格。这里按 total 而不是 sum 归一化：
    # 当 used + cache + free 小于 total 时，剩余部分会作为背景空格显示。
    local -a counts=()
    local count
    while IFS= read -r count; do
        counts+=("$count")
    done < <(
        printf '%s\n' "${values[@]}" |
            awk -v total="$total" -v width="$width" '
                {
                    value = $1 + 0
                    if (value < 0) value = 0
                    vals[++n] = value
                    sum += value
                }
                END {
                    if (width <= 0) exit
                    if (n == 0 || total <= 0 || sum <= 0) {
                        for (i = 1; i <= n; i++) print 0
                        exit
                    }

                    stack = int(width * sum / total + 0.5)
                    if (stack < 0) stack = 0
                    if (stack > width) stack = width

                    used = 0
                    for (i = 1; i <= n; i++) {
                        exact = stack * vals[i] / sum
                        blocks[i] = int(exact)
                        remain[i] = exact - blocks[i]
                        used += blocks[i]
                    }

                    # 把四舍五入留下的零散格子给余数最大的段。
                    left = stack - used
                    while (left > 0) {
                        best = 0
                        best_remain = -1
                        for (i = 1; i <= n; i++) {
                            if (remain[i] > best_remain) {
                                best = i
                                best_remain = remain[i]
                            }
                        }
                        blocks[best]++
                        remain[best] = -1
                        left--
                    }

                    for (i = 1; i <= n; i++) print blocks[i]
                }
            '
    )

    local i blocks_used=0
    for i in "${!values[@]}"; do
        count=${counts[i]:-0}
        if (( count > 0 )); then
            printf '%s%s%s' \
                "${colors[i]}" \
                "$(repeat_char "${chars[i]}" "$count")" \
                "$C_RESET"
            blocks_used=$((blocks_used + count))
        fi
    done

    # total 大于各段之和时，剩余部分用中性背景补齐，仍保持 WIDTH 列。
    if (( blocks_used < width )); then
        printf '%s%s%s' \
            "$C_BAR_EMPTY" \
            "$(repeat_char '░' "$((width - blocks_used))")" \
            "$C_RESET"
    fi
}

# shellcheck shell=bash
#
# ── [REPORT] 动态值回填 ────────────────────────────────────────────────

# 先测量纯数据，再生成与 DATA_W 等宽的条形图，填入对应的值槽位。
# 用 add_field 时记录下来的下标定位，不写死 6/8/10，后续增删字段更安全。
_profile_begin 'layout measure'
measure_fields
if (( ${#GPU_IDENTITY_LINES[@]} > 0 )); then
    for gpu_identity in "${GPU_IDENTITY_LINES[@]}"; do
        ensure_data_width "$gpu_identity"
    done
fi
ensure_centered_width "$server_display"
ensure_centered_width "$client_display"
_profile_end
_profile_begin 'format values'
FIELD_VALUES[MEM_USED_ROW]=$(align_mem_percent \
    "$used_display" "$mem_used_percent" "$C_BAR_USED")
FIELD_VALUES[MEM_CACHE_ROW]=$(align_mem_percent \
    "$cache_display" "$mem_cache_percent" "$C_BAR_CACHE")
FIELD_VALUES[MEM_FREE_ROW]=$(align_mem_percent \
    "$free_display" "$mem_free_percent" "$C_BAR_FREE")
FIELD_VALUES[MEM_SHARED_ROW]=$(align_mem_percent \
    "$shared_display" "$mem_shared_percent" "$C_MEM_SHARED")
FIELD_VALUES[MEM_AVAILABLE_ROW]=$(align_mem_percent \
    "$available_display" "$mem_available_percent" "$C_BAR_AVAILABLE")
FIELD_VALUES[LOAD_1M_ROW]=$(load_display "$load1" "$cpu_cores")
FIELD_VALUES[LOAD_5M_ROW]=$(load_display "$load5" "$cpu_cores")
FIELD_VALUES[LOAD_15M_ROW]=$(load_display "$load15" "$cpu_cores")
for i in "${!GPU_RECORDS[@]}"; do
    IFS=$'\t' read -r gpu_used gpu_total gpu_util <<<"${GPU_RECORDS[i]}"
    FIELD_VALUES[GPU_MEM_ROWS[i]]=$(gpu_memory_display \
        "$gpu_used" "$gpu_total")
    FIELD_VALUES[GPU_UTIL_ROWS[i]]=$(gpu_util_display "$gpu_util")
done
for i in "${!DISK_BAR_ROWS[@]}"; do
    FIELD_VALUES[DISK_BAR_ROWS[i]]=$(disk_usage_display "${DISK_BAR_PCTS[i]}")
done
MEM_PERCENT_SUFFIX=$(format_percent_suffix "$mem_used_percent")
MEM_BAR_WIDTH=$((DATA_W - ${#MEM_PERCENT_SUFFIX}))
(( MEM_BAR_WIDTH > 0 )) || MEM_BAR_WIDTH=1
FIELD_VALUES[MEM_BAR_ROW]=$(
    stacked_bar "$mem_total" "$MEM_BAR_WIDTH" \
        "$mem_used"  '█' "$C_BAR_USED" \
        "$mem_cache" '▓' "$C_BAR_CACHE" \
        "$mem_free"  '░' "$C_BAR_FREE"
)
FIELD_VALUES[MEM_BAR_ROW]+=$MEM_PERCENT_SUFFIX

FIELD_VALUES[MEM_TOTAL_ROW]=$(align_row_ends "$total_display" "$mem_status")
_profile_end

# ── [REPORT] 最终渲染 ──────────────────────────────────────────────────

# [REPORT] render_report -> 渲染标题、字段行和页脚。
# 前置条件：字段已组装、measure_fields 已执行、动态值已回填。
# 用法：render_report
render_report() {
    local title='服务器运行报告'
    local subtitle='PVE Platform'
    local environment='PRODUCTION'
    local line
    local -a centered_lines=()
    local -a field_lines=()
    local -a centered_texts=()

    centered_texts=(
        "${C_TITLE}${title}${C_RESET}"
        "${C_ACCENT}${subtitle}${C_RESET}"
        "${C_ENV}ENVIRONMENT · ${environment}${C_RESET}"
        "$server_display"
        "$client_display"
    )

    # 标题、页脚和所有字段行合并到一个 Perl 进程。
    while IFS= read -r -d '' line; do
        case ${line:0:1} in
            C) centered_lines+=("${line:1}") ;;
            R) field_lines+=("${line:1}") ;;
        esac
    done < <(_format_report_lines "${centered_texts[@]}")

    print_header
    printf '%s\n' "${centered_lines[0]}" "${centered_lines[1]}"
    print_divider "$MID_LEFT" "$TOP_MID" "$MID_RIGHT"

    for i in "${!FIELD_LABELS[@]}"; do
        if (( i > 0 )); then
            case ${FIELD_BREAK_BEFORE[i]} in
                1) print_divider "$MID_LEFT" "$MID_MID" "$MID_RIGHT" ;;
                2) print_dashed_divider ;;
            esac
        fi
        printf '%s\n' "${field_lines[i]}"
    done

    # 页脚跨两列：上方竖线用 ┴ 结束，底边使用连续横线。
    print_divider "$MID_LEFT" "$BOTTOM_MID" "$MID_RIGHT"
    printf '%s\n' \
        "${centered_lines[2]}" \
        "${centered_lines[3]}" \
        "${centered_lines[4]}"
    print_merged_divider "$BOTTOM_LEFT" "$BOTTOM_RIGHT"
}

_profile_begin 'render'
render_report
_profile_end
_profile_total
