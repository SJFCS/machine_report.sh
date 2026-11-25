#!/usr/bin/env bash
set -euo pipefail

VERSION=0.1.1
ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR="$ROOT_DIR/src"
OUTPUT=${1:-"$ROOT_DIR/machine_report.sh"}
OUTPUT_DIR=$(dirname -- "$OUTPUT")
BUILD_DATE=$(date '+%Y-%m-%d')

# 构建顺序固定为：框架内核 → 数据源 → handlers → 入口。
# 目录名和文件名都带排序，所以用 glob 展开即可保持稳定顺序。
shopt -s nullglob
sources=(
    "$SRC_DIR"/core/*.sh
    "$SRC_DIR"/sources/*.sh
    "$SRC_DIR"/handlers/*.sh
    "$SRC_DIR"/main.sh
)

if (( ${#sources[@]} == 0 )); then
    printf 'No source files found in %s\n' "$SRC_DIR" >&2
    exit 1
fi

mkdir -p -- "$OUTPUT_DIR"
tmp=$(mktemp "$OUTPUT_DIR/.report-build.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM

# src 里每个片段都带自己的 shellcheck 指令（shell=bash、片段级 disable），
# 这些只服务于编辑器单文件检查。合并产物有 shebang，也不该被片段级
# disable 静音，所以构建时统一删掉，保留完整检查。
grep -h -v -E '^# shellcheck ' \
    "${sources[@]}" |
    sed \
        -e "s/^# Date    : BUILD_TIME$/# Date    : $BUILD_DATE/" \
        -e "s/^# Version : BUILD_VERSION$/# Version : $VERSION/" >"$tmp"
bash -n "$tmp"
chmod 755 "$tmp"
mv -f -- "$tmp" "$OUTPUT"

trap - EXIT HUP INT TERM
printf 'Built %s from %d source files\n' "$OUTPUT" "${#sources[@]}"
