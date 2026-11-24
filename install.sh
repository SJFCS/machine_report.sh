#!/usr/bin/env bash

set -euo pipefail

RAW_BASE=${MREPORT_RAW_BASE:-https://raw.githubusercontent.com/SJFCS/machine_report.sh/main}
REPORT_NAME=machine_report.sh
COMMAND_NAME=mreport
START_MARKER='# >>> machine_report >>>'
END_MARKER='# <<< machine_report <<<'

usage() {
    cat <<'EOF'
用法：install.sh [选项]

安装范围：
  --user           安装到当前用户（默认）
  --system         安装给所有用户，需要 root 或 sudo

安装行为：
  --no-autostart   安装 mreport，但关闭当前范围的自动展示
  --uninstall      卸载当前安装范围
  --source PATH    使用本地报告文件，不从 GitHub 下载
  -h, --help       显示帮助

示例：
  bash <(curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh)
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh) --system  
  ./install.sh --source ./machine_report.sh
  sudo ./install.sh --system --no-autostart
EOF
}

die() {
    printf '安装失败：%s\n' "$*" >&2
    exit 1
}

scope=user
autostart=1
uninstall=0
source_file=${MREPORT_SOURCE:-}

while (( $# > 0 )); do
    case $1 in
        --user) scope=user ;;
        --system) scope=system ;;
        --no-autostart) autostart=0 ;;
        --uninstall) uninstall=1 ;;
        --source)
            (( $# >= 2 )) || die '--source 缺少路径'
            source_file=$2
            shift
            ;;
        --source=*) source_file=${1#*=} ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "未知选项：$1"
            ;;
    esac
    shift
done


if [ "$scope" = system ]; then
    (( EUID == 0 )) || die '--system 需要 root，请使用 sudo 运行'

    INSTALL_DIR=/usr/local/lib/machine_report
    BIN_DIR=/usr/local/bin
    STARTUP_FILES=("/etc/profile")
else
    INSTALL_DIR=${XDG_DATA_HOME:-"$HOME/.local/share"}/machine_report
    BIN_DIR="$HOME/.local/bin"
    STARTUP_FILES=("$HOME/.zshrc" "$HOME/.bashrc")
fi

REPORT_PATH="$INSTALL_DIR/$REPORT_NAME"
COMMAND_PATH="$BIN_DIR/$COMMAND_NAME"

# 启动配置可能是普通文件、缺失、悬空链接或目录。缺失时允许创建；
# 其他非普通文件只警告并跳过，避免一个坏路径中断整个安装/卸载。
rc_file_usable() {
    local file=$1

    if [ -L "$file" ] && [ ! -e "$file" ]; then
        printf '警告：启动配置是悬空链接，已跳过：%s\n' "$file" >&2
        return 1
    fi
    if [ -e "$file" ] && [ ! -f "$file" ]; then
        printf '警告：启动配置不是普通文件，已跳过：%s\n' "$file" >&2
        return 1
    fi
    return 0
}

# 删除托管块，同时保留块外的所有内容。
strip_managed_block() {
    local file=$1

    [ -f "$file" ] || return 0

    if [ "$(uname)" = Darwin ]; then
        sed -i '' "/^${START_MARKER}$/,/^${END_MARKER}$/d" "$file" || {
            printf '警告：无法清理启动配置：%s\n' "$file" >&2
            return 1
        }
    else
        sed -i "/^${START_MARKER}$/,/^${END_MARKER}$/d" "$file" || {
            printf '警告：无法清理启动配置：%s\n' "$file" >&2
            return 1
        }
    fi
}

# 写入托管块：先清理旧块，再追加新块，因此重复安装是幂等的。
write_rc_block() {
    local file=$1

    rc_file_usable "$file" || return 1
    if [ -e "$file" ] && [ ! -w "$file" ]; then
        printf '警告：启动配置不可写，已跳过：%s\n' "$file" >&2
        return 1
    fi
    if ! mkdir -p -- "$(dirname -- "$file")"; then
        printf '警告：无法创建启动配置目录：%s\n' "$(dirname -- "$file")" >&2
        return 1
    fi
    if ! strip_managed_block "$file"; then
        printf '警告：无法清理旧配置块，已跳过：%s\n' "$file" >&2
        return 1
    fi

    if ! {
        printf '%s\n' "$START_MARKER"

        # 当前用户安装时，~/.local/bin 通常不在 PATH 中，需要补上。
        # 系统安装使用 /usr/local/bin，它通常已经是标准 PATH。
        if [ "$scope" = user ]; then
            cat <<'EOF'
# 把当前用户的 ~/.local/bin 加入 PATH
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
        fi

        # 自动展示只在交互式终端执行，并用 MREPORT_AUTORUN_DONE 防止
        # bash 启动 zsh、或父 shell 继承环境时重复打印报告。
        if (( autostart == 1 )); then
            cat <<'EOF'
# 同一终端环境只自动展示一次；MREPORT_AUTORUN=0 可临时关闭
if [ "${MREPORT_AUTORUN:-1}" != "0" ] &&
   [ -z "${MREPORT_AUTORUN_DONE:-}" ] &&
   [ -t 1 ] &&
   command -v mreport >/dev/null 2>&1; then
    MREPORT_AUTORUN_DONE=1
    export MREPORT_AUTORUN_DONE
    mreport || true
fi
EOF
        fi

        printf '%s\n' "$END_MARKER"
    } >>"$file"; then
        printf '警告：无法写入启动配置，已跳过：%s\n' "$file" >&2
        return 1
    fi
}


# 只删除指向本次报告文件的 mreport 链接，避免误删用户自己的命令。
remove_command_link() {
    local target

    if [ ! -L "$COMMAND_PATH" ]; then
        [ -e "$COMMAND_PATH" ] &&
            printf '警告：%s 不是本次安装创建的链接，未删除。\n' \
                "$COMMAND_PATH" >&2
        return 0
    fi

    target=$(readlink "$COMMAND_PATH")
    if [ "$target" = "$REPORT_PATH" ]; then
        rm -f -- "$COMMAND_PATH"
    else
        printf '警告：%s 指向 %s，未删除。\n' \
            "$COMMAND_PATH" "$target" >&2
    fi
}

if (( uninstall == 1 )); then
    for file in "${STARTUP_FILES[@]}"; do
        strip_managed_block "$file" || true
    done
    remove_command_link
    rm -f -- "$REPORT_PATH"
    rmdir -- "$INSTALL_DIR" 2>/dev/null || true

    if [ "$scope" = system ]; then
        printf '已卸载 machine_report（所有用户）。\n'
    else
        printf '已卸载 machine_report（当前用户）。\n'
    fi
    exit 0
fi

# 如果命令路径已被其他程序占用，直接报错，不覆盖用户文件。
if { [ -e "$COMMAND_PATH" ] || [ -L "$COMMAND_PATH" ]; } &&
   { [ ! -L "$COMMAND_PATH" ] ||
        [ "$(readlink "$COMMAND_PATH")" != "$REPORT_PATH" ]; }; then
    die "命令路径已存在且不是本次安装的链接：$COMMAND_PATH"
fi

mkdir -p -- "$INSTALL_DIR" "$BIN_DIR"
report_tmp=$(mktemp "$INSTALL_DIR/.machine_report.XXXXXX")
trap 'rm -f -- "$report_tmp"' EXIT HUP INT TERM

# 优先使用 --source 指定的本地文件；其次尝试使用安装器旁边的
# machine_report.sh；都没有时再从 GitHub 下载。
if [ -z "$source_file" ]; then
    script_path=${BASH_SOURCE[0]:-}
    if [ -n "$script_path" ] && [ -f "$script_path" ]; then
        script_dir=$(CDPATH='' cd -- "$(dirname -- "$script_path")" && pwd)
        if [ -f "$script_dir/$REPORT_NAME" ]; then
            source_file="$script_dir/$REPORT_NAME"
        fi
    fi
fi

if [ -n "$source_file" ]; then
    [ -f "$source_file" ] || die "找不到本地报告文件：$source_file"
    cp -- "$source_file" "$report_tmp"
else
    report_url=${MREPORT_REPORT_URL:-"$RAW_BASE/$REPORT_NAME"}
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 10 "$report_url" -o "$report_tmp" ||
            die "下载失败：$report_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$report_tmp" "$report_url" ||
            die "下载失败：$report_url"
    else
        die '需要 curl 或 wget 下载报告'
    fi
fi

[ -s "$report_tmp" ] || die '报告文件为空'
bash -n "$report_tmp" || die '报告文件语法检查失败'
chmod 755 "$report_tmp"
mv -f -- "$report_tmp" "$REPORT_PATH"
trap - EXIT HUP INT TERM

ln -sfn -- "$REPORT_PATH" "$COMMAND_PATH"

# 无论安装还是关闭自动展示，都先清理当前范围的所有旧块。
# 用户范围随后写入 PATH 块；系统范围仅在 autostart=1 时写登录 profile。
for file in "${STARTUP_FILES[@]}"; do
    strip_managed_block "$file" || true
done
if [ "$scope" = user ] || (( autostart == 1 )); then
    rc_written_files=''
    rc_failure_count=0
    for file in "${STARTUP_FILES[@]}"; do
        if write_rc_block "$file"; then
            rc_written_files="${rc_written_files}${file}"$'\n'
        else
            rc_failure_count=$((rc_failure_count + 1))
        fi
    done
else
    rc_written_files=''
    rc_failure_count=0
fi

printf '已安装：%s\n' "$REPORT_PATH"
printf '快捷命令：%s\n' "$COMMAND_NAME"

if (( autostart == 1 )); then
    if [ -n "$rc_written_files" ]; then
        printf '启动配置：\n'
        while IFS= read -r file; do
            [ -n "$file" ] && printf '  - %s\n' "$file"
        done <<<"$rc_written_files"
        if [ "$scope" = system ]; then
            printf 'bash/zsh 登录时会自动展示报告。\n'
        else
            printf '打开交互式 bash/zsh 时会自动展示报告。\n'
        fi
    fi
else
    printf '已关闭自动展示，可随时运行 %s。\n' "$COMMAND_NAME"
fi

if [ "$scope" = user ] && [ -n "$rc_written_files" ]; then
    printf '重新打开终端，或执行：source ~/.bashrc 或 source ~/.zshrc\n'
fi

if (( rc_failure_count > 0 )); then
    printf '警告：%s 个启动配置未写入；对应 shell 的自动展示或 PATH 配置不会生效，mreport 已安装，可直接运行或手动加入 PATH。\n' \
        "$rc_failure_count" >&2
fi
