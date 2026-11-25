# shellcheck shell=bash
# shellcheck disable=SC2154
# shellcheck disable=SC2034
#
# ── 执行入口 ───────────────────────────────────────────────────────────
#
# 本文件只负责阶段调度；共享数据与平台信息的采集实现位于 src/sources/。
#
# 想加自己的内容，不需要改这个文件：
#   1. 在 src/handlers/ 下新建一个 .sh（照抄任意一个 handler）
#   2. 里面定义 handler_<名字>()，用 mr_field / mr_bar 等 mr_ 函数排版
#   3. 文件末尾写 mr_register <名字>
# 注册顺序就是渲染顺序；文件名只决定注册顺序。

# 1) 采集共享数据
collect_shared_scalars
collect_platform_session

# 2) 运行 handlers（顺序由 mr_register 决定）
for __mr_name in "${MR_HANDLERS[@]}"; do
    "handler_$__mr_name"
done

# 3) 列宽测量：先统一测量，再让 handler 微调、回填依赖宽度的值。
_profile_begin 'layout measure'
measure_fields
measure_cover_lines
for __mr_name in "${MR_HANDLERS[@]}"; do
    if declare -F "handler_${__mr_name}_measure" >/dev/null 2>&1; then
        "handler_${__mr_name}_measure"
    fi
done
_profile_end

_profile_begin 'format values'
for __mr_name in "${MR_HANDLERS[@]}"; do
    if declare -F "handler_${__mr_name}_fill" >/dev/null 2>&1; then
        "handler_${__mr_name}_fill"
    fi
done
_profile_end

# 4) 渲染
_profile_begin 'render'
render_report
_profile_end
_profile_total
