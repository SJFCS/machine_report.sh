# shellcheck shell=bash
#
# 本文件绘制的行：EXAMPLE / EXAMPLE BAR

handler_mything() {
    mr_field 'EXAMPLE' 'hello'

    mr_field 'EXAMPLE BAR' ''
    MY_BAR_ROW=$FIELD_INDEX      # 先占位，等列宽确定
}

handler_mything_fill() {
    mr_update "$MY_BAR_ROW" "$(mr_bar 42 100)"
}

mr_register mything