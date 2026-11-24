# shellcheck shell=bash
# ── 显示宽度引擎 ───────────────────────────────────────────────────────
#
# 这段 Perl 从标准输入读取一个 UTF-8 字符串，由 TABLE_MODE 决定行为：
#   width：只输出该字符串的显示列数
#   fit  ：在 TABLE_LIMIT 列以内截断，并输出可以安全打印的字符串
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

my @tokens = tokenize($text);

if ($mode eq 'fit') {
    $limit = int($limit);
    if ($limit <= 0) {
        print '';
        exit;
    }

    my $total = 0;
    $total += $_->[1] for @tokens;
    if ($total <= $limit) {
        print $text;
        exit;
    }

    # 预留一列给省略号。最后一个完整字形簇之后可能还有颜色码，
    # 所以只在确实遇到过 ANSI 时补一个 reset，避免颜色泄漏到后续边框。
    my $budget = $limit - 1;
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
    print $out;
    exit;
}

my $width = 0;
$width += $_->[1] for @tokens;
print $width;
PERL

# [TABLE] display_width TEXT -> 输出终端显示列数。
# 使用管道而不是命令行参数，避免空格、引号、反斜杠或 ANSI 被二次解释。
# 用法：columns=$(display_width "$cell")
display_width() {
    local text=$1
    printf '%s' "$text" |
        TABLE_MODE=width perl -CS -e "$DISPLAY_WIDTH_PERL"
}

# [TABLE] fit_display TEXT MAX -> 按显示列数截断，超宽时以“…”结尾。
# 用法：fitted=$(fit_display "$long_text" 40)
fit_display() {
    local text=$1 max=$2
    printf '%s' "$text" |
        TABLE_MODE=fit TABLE_LIMIT="$max" \
            perl -CS -e "$DISPLAY_WIDTH_PERL"
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

# [TABLE] pad_display TEXT WIDTH -> 左对齐并用 ASCII 空格补齐。
# 用法：padded=$(pad_display "$text" 20)
pad_display() {
    local text=$1 width=$2 current
    current=$(display_width "$text")
    printf '%s' "$text"
    if (( current < width )); then
        printf '%*s' "$((width - current))" ''
    fi
}

# [TABLE] max_display_width VALUE... -> 返回最大显示列数。
# 传入数组时必须写成 "${array[@]}"，避免元素内空格被拆成新参数。
# 用法：width=$(max_display_width "${FIELD_LABELS[@]}")
max_display_width() {
    local value width max=0
    for value in "$@"; do
        width=$(display_width "$value")
        (( width > max )) && max=$width
    done
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
    for row in "$@"; do
        IFS=$'\t' read -r -a cells <<<"$row"
        width=$(display_width "${cells[column]:-}")
        (( width > max )) && max=$width
    done
    printf '%s' "$max"
}

