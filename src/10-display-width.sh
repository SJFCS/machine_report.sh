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
TABLE_ASCII_RE='^[ -~]*$'
TABLE_CSI_RE=$'\e\\[[0-?]*[ -/]*[@-~]'
TABLE_OSC_RE=$'\e\\][^\a]*(\a|\e\\\\)'

# [TABLE] _strip_ansi_into VAR TEXT -> 去掉 CSI/OSC 控制序列。
_strip_ansi_into() {
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
    if [[ $text =~ $TABLE_ASCII_RE ]]; then
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

    if [[ $__fit_text =~ $TABLE_ASCII_RE ]]; then
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

    if [[ $__pad_text =~ $TABLE_ASCII_RE ]]; then
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
        if [[ $text =~ $TABLE_ASCII_RE ]]; then
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

