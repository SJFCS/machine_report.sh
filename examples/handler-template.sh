# shellcheck shell=bash
#
# 自定义 handler 模板
#
# 用法：
#   cp examples/handler-template.sh src/handlers/70-mything.sh
#   ./build.sh
#
# 只要不调用框架内部函数，这里出现的就是全部 API。

# 第一个钩子：采集数据并添加字段。
handler_mything() {
    # 普通行：mr_field '标签' '值'
    mr_field 'EXAMPLE' 'hello'

    # 新分组：mr_field_break 会在上方画一条实线
    mr_field_break 'LAST BOOT' "$(date '+%Y-%m-%d %H:%M')"

    # 依赖列宽的行：先占位并记住行号
    mr_field 'EXAMPLE BAR' ''
    EXAMPLE_BAR_ROW=$FIELD_INDEX
}

# 第二个钩子（可选）：列宽确定后回填。此时 DATA_W 可用。
handler_mything_fill() {
    mr_update "$EXAMPLE_BAR_ROW" "$(mr_bar 42 100)"
}

# 注册；顺序就是渲染顺序。
mr_register mything
