# shellcheck shell=bash
#
# ── 执行入口 ───────────────────────────────────────────────────────────
#
# 想加自己的内容，不需要改这个文件：
#   1. 在 src/handlers/ 下新建一个 .sh（照抄任意一个 handler）
#   2. 里面定义 handler_<名字>()，用 mr_field / mr_bar 等 mr_ 函数排版
#   3. 文件末尾写 mr_register <名字>
# 注册顺序就是渲染顺序；文件名只决定注册顺序。

# [STAGE] collect_shared_scalars -> 标量与元数据（OS/CPU/负载/运行时间/内存）。
collect_shared_scalars() {
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
}

# [STAGE] collect_platform_session -> 厂商/型号/UUID 与 locale/时区/登录信息。
collect_platform_session() {
    _profile_begin 'platform'
    if [ "$platform_name" = Darwin ]; then
        # 厂商、型号和 UUID 都会读同一份 IOPlatformExpertDevice；先取一次，
        # 后续 darwin_field 直接复用，避免每个字段都启动一次 ioreg。
        DARWIN_PLATFORM_RAW=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null)
    fi
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
}

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
