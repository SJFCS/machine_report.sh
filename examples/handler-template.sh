# shellcheck shell=bash
#
# 自定义 handler 模板
#
# 用法：
#   cp examples/handler-template.sh src/handlers/70-mything.sh
#   ./build.sh
#
# 只要不调用框架内部函数，这里出现的就是全部 API。
# 想改标题/页脚而不加字段，见 src/handlers/00-cover.sh。
#
# 本文件绘制的行：EXAMPLE / EXAMPLE 2 / EXAMPLE BAR

handler_mything() {
    # 新分组的第一行：实线分隔
    mr_field_break 'EXAMPLE' 'hello'

    # 同一组的后续条目：虚线分隔
    mr_field_dashed 'EXAMPLE 2' "$(date '+%Y-%m-%d %H:%M:%S')"

    # 依赖列宽的行：先占位并记住行号
    mr_field 'EXAMPLE BAR' ''
    EXAMPLE_BAR_ROW=$FIELD_INDEX
}

# 可选钩子：列宽确定后回填。此时 DATA_W 可用。
handler_mything_fill() {
    mr_update "$EXAMPLE_BAR_ROW" "$(mr_bar 42 100)"
}

# 注册；顺序就是渲染顺序。
mr_register mything
