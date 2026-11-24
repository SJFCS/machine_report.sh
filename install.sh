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

选项：
  --user           安装到当前用户（默认）
  --system         安装给所有用户，需要 root
  --no-autostart   不自动展示报告，只安装 mreport 命令
  --uninstall      卸载当前范围
  --source PATH    使用本地报告文件，而不是从 GitHub 下载
  -h, --help       显示帮助

示例：
  curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh | sudo bash -s -- --system
  ./install.sh --source ./machine_report.sh
  sudo ./install.sh --system
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
    PROFILE_FILE=/etc/profile.d/machine_report.sh
    SYSTEM_ZSH_RC=
    for candidate in /etc/zsh/zshrc /etc/zshrc; do
        if [ -f "$candidate" ]; then
            SYSTEM_ZSH_RC=$candidate
            break
        fi
    done
else
    INSTALL_DIR=${XDG_DATA_HOME:-"$HOME/.local/share"}/machine_report
    BIN_DIR="$HOME/.local/bin"
    PROFILE_FILE=
    SYSTEM_ZSH_RC=
fi

REPORT_PATH="$INSTALL_DIR/$REPORT_NAME"
COMMAND_PATH="$BIN_DIR/$COMMAND_NAME"

strip_managed_block() {
    local file=$1 tmp

    [ -f "$file" ] || return 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/mreport-rc.XXXXXX")
    awk -v start="$START_MARKER" -v end="$END_MARKER" '
        $0 == start { skipping = 1; next }
        $0 == end { skipping = 0; next }
        !skipping { print }
    ' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f -- "$tmp"
}

write_rc_block() {
    local file=$1 tmp

    mkdir -p -- "$(dirname -- "$file")"
    tmp=$(mktemp "${TMPDIR:-/tmp}/mreport-rc.XXXXXX")
    if [ -f "$file" ]; then
        awk -v start="$START_MARKER" -v end="$END_MARKER" '
            $0 == start { skipping = 1; next }
            $0 == end { skipping = 0; next }
            !skipping { print }
        ' "$file" >"$tmp"
    fi

    {
        cat "$tmp"
        printf '%s\n' "$START_MARKER"
        if [ "$scope" = user ]; then
            cat <<'EOF'
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
        fi
        if (( autostart == 1 )); then
            cat <<'EOF'
# 新TTY终端执行，已有环境启动zsh会集成MREPORT_AUTORUN_DONE=1所以不会执行
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
    } >"$file"
    rm -f -- "$tmp"
}

remove_command_link() {
    local target

    [ -L "$COMMAND_PATH" ] || {
        [ -e "$COMMAND_PATH" ] &&
            printf '警告：%s 不是本次安装创建的链接，未删除。\n' "$COMMAND_PATH" >&2
        return 0
    }
    target=$(readlink "$COMMAND_PATH")
    if [ "$target" = "$REPORT_PATH" ]; then
        rm -f -- "$COMMAND_PATH"
    else
        printf '警告：%s 指向 %s，未删除。\n' "$COMMAND_PATH" "$target" >&2
    fi
}

if (( uninstall == 1 )); then
    if [ "$scope" = system ]; then
        rm -f -- "$PROFILE_FILE"
        if [ -n "$SYSTEM_ZSH_RC" ]; then
            strip_managed_block "$SYSTEM_ZSH_RC"
        fi
    else
        strip_managed_block "$HOME/.bashrc"
        strip_managed_block "$HOME/.zshrc"
    fi
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

if { [ -e "$COMMAND_PATH" ] || [ -L "$COMMAND_PATH" ]; } &&
   { [ ! -L "$COMMAND_PATH" ] || [ "$(readlink "$COMMAND_PATH")" != "$REPORT_PATH" ]; }; then
    die "命令路径已存在且不是本次安装的链接：$COMMAND_PATH"
fi

mkdir -p -- "$INSTALL_DIR" "$BIN_DIR"
tmp=$(mktemp "$INSTALL_DIR/.machine_report.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM

if [ -z "$source_file" ]; then
    script_source=${BASH_SOURCE[0]:-}
    if [ -n "$script_source" ] && [ -f "$script_source" ]; then
        script_dir=$(CDPATH='' cd -- "$(dirname -- "$script_source")" && pwd)
        if [ -f "$script_dir/$REPORT_NAME" ]; then
            source_file="$script_dir/$REPORT_NAME"
        fi
    fi
fi

if [ -n "$source_file" ]; then
    [ -f "$source_file" ] || die "找不到本地报告文件：$source_file"
    cp -- "$source_file" "$tmp"
else
    report_url=${MREPORT_REPORT_URL:-"$RAW_BASE/$REPORT_NAME"}
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 10 "$report_url" -o "$tmp" ||
            die "下载失败：$report_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" "$report_url" ||
            die "下载失败：$report_url"
    else
        die '需要 curl 或 wget 下载报告'
    fi
fi

[ -s "$tmp" ] || die '报告文件为空'
bash -n "$tmp" || die '报告文件语法检查失败'
chmod 755 "$tmp"
mv -f -- "$tmp" "$REPORT_PATH"
trap - EXIT HUP INT TERM

ln -sfn -- "$REPORT_PATH" "$COMMAND_PATH"

if [ "$scope" = system ]; then
    if (( autostart == 1 )); then
        write_rc_block "$PROFILE_FILE"
        if [ -n "$SYSTEM_ZSH_RC" ]; then
            write_rc_block "$SYSTEM_ZSH_RC"
        fi
    else
        rm -f -- "$PROFILE_FILE"
        if [ -n "$SYSTEM_ZSH_RC" ]; then
            strip_managed_block "$SYSTEM_ZSH_RC"
        fi
    fi
else
    write_rc_block "$HOME/.bashrc"
    write_rc_block "$HOME/.zshrc"
fi

printf '已安装：%s\n' "$REPORT_PATH"
printf '快捷命令：%s\n' "$COMMAND_NAME"
if (( autostart == 1 )); then
    printf '交互式终端启动时将自动展示报告。\n'
else
    printf '已关闭自动展示，可随时运行 %s。\n' "$COMMAND_NAME"
fi
if [ "$scope" = user ]; then
    printf '如当前终端找不到命令，请重新登录或执行：source ~/.zshrc\n'
fi
