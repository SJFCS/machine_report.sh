# 开发文档

面向要改这个脚本的人：加一行、加一个分组、加一个数据源，或者调整整体排版。
只写 handler 的话，看完「快速开始」和「API」就够了。

## 目录

- [一分钟了解架构](#一分钟了解架构)
- [构建与产物](#构建与产物)
- [快速开始：加一个 handler](#快速开始加一个-handler)
- [handler 契约](#handler-契约)
- [公开 API](#公开-api)
- [数据流与生命周期](#数据流与生命周期)
- [常用全局量](#常用全局量)
- [改标题与页脚](#改标题与页脚)
- [数据源（sources）](#数据源sources)
- [编码约定](#编码约定)
- [常见坑](#常见坑)
- [性能](#性能)
- [测试与自检](#测试与自检)

## 一分钟了解架构

```
src/
  core/       框架内核：宽度、数字、表格、布局、渲染、mr_* API
  sources/    纯数据采集：只输出文本或 TSV
  handlers/   展示层：一个文件一个 handler，决定“显示哪些行、长什么样”
  main.sh     执行入口：采集 → 跑 handler → 测宽 → 回填 → 渲染
build.sh      按 core → sources → handlers → main 合并成 machine_report.sh
```

分层规则：

- `sources/` 不认识 UI，只 `printf` 数据；不要在里面画线、加颜色。
- `handlers/` 认识 `mr_*`，负责把数据变成字段行；不要写画线、测量逻辑。
- `core/` 只提供能力和最终渲染，不包含具体业务字段。

渲染流程：

```
collect_shared_scalars()      # OS/CPU/负载/内存等共享标量
collect_platform_session()    # 厂商/型号/UUID/locale/时区/登录信息
for h in "${MR_HANDLERS[@]}"; do handler_$h; done     # 追加字段行
measure_fields()              # 计算 NAME_W / DATA_W
handler_xxx_measure()         # 可选：撑宽 DATA_W
handler_xxx_fill()            # 可选：回填条形图等依赖宽度的值
render_report()               # 画边框、居中、输出
```

## 构建与产物

```bash
./build.sh              # 生成 ./machine_report.sh
./build.sh /tmp/x.sh    # 输出到指定路径（调试用）
```

- `build.sh` 里的 `VERSION` 是唯一版本号来源；构建时写入产物头部。
- `Date` 使用构建当天日期。
- 合并后会跑一次 `bash -n`，语法错误直接失败，不会写出半成品。
- `src/` 里的 `# shellcheck shell=bash`、片段级 `disable=SC2034/SC2154`
  只服务编辑器单文件检查，合并时统一删除；产物按完整规则检查。

改了 `src/` 之后一定要重新 `./build.sh` 并把 `machine_report.sh` 一起提交，
`install.sh` 安装的是构建产物，不是 `src/`。

## 快速开始：加一个 handler

1. 新建 `src/handlers/70-mything.sh`：

```bash
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
```

2. `./build.sh`

3. 新的分组会自动出现在磁盘之后（文件顺序即注册顺序）。
   不想显示某一行：注释掉对应的 `mr_field`。
   不想显示整组：注释掉文件末尾的 `mr_register`。

也可以直接复制 `examples/handler-template.sh` 改名使用。

## handler 契约

每个 handler 最多三个函数，命名固定：

| 函数 | 必需 | 时机 | 用途 |
| --- | --- | --- | --- |
| `handler_<name>()` | 是 | 所有 handler 依次执行 | 采集数据、`mr_field` 追加行 |
| `handler_<name>_measure()` | 否 | `measure_fields` 之后、所有 fill 之前 | 撑宽 `DATA_W` |
| `handler_<name>_fill()` | 否 | 所有 measure 之后 | 回填条形图/百分比 |

`mr_register <name>` 决定注册顺序，也就是渲染顺序。文件名只影响注册顺序，
可以用 `00-`、`10-` 这类前缀调整。

分隔线（`BREAK`）：`0` 不画，`1` 实线，`2` 虚线。`DEVICE`/`SPACE` 这类
同一块内容的第二行用虚线，不同块之间用实线，是现有报告的惯例。

## 公开 API

实现在 `src/core/45-api.sh`。`mr_` 开头是对外契约，其余函数都可能变。

### 字段

| 函数 | 说明 |
| --- | --- |
| `mr_field LABEL VALUE [BREAK]` | 追加一行 |
| `mr_field_break LABEL VALUE` | 追加一行并在上方画实线 |
| `mr_field_dashed LABEL VALUE` | 追加一行并在上方画虚线 |
| `mr_update INDEX VALUE` | 回填第 `INDEX` 行（用 `$FIELD_INDEX` 记住） |

值里可以带 ANSI 颜色和中文，宽度由框架计算。

### 标题与页脚

| 函数 | 说明 |
| --- | --- |
| `mr_cover_line TEXT` | 表格上方加一行居中文字 |
| `mr_footer_line TEXT` | 表格下方加一行居中文字 |

可以调用任意多次，写几行显示几行，注释掉就隐藏；文字超过表格宽度时
表格自动变宽。

### 文本工具

| 函数 | 说明 |
| --- | --- |
| `mr_width TEXT` | 终端显示列数（中文/ANSI 安全） |
| `mr_pad TEXT WIDTH` | 右补空格到指定显示宽度 |
| `mr_fit TEXT WIDTH` | 超宽时截断并以 `…` 结尾 |
| `mr_bar VALUE TOTAL [WIDTH]` | 百分比条；省略 `WIDTH` 时用 `DATA_W` |
| `mr_percent_bar VALUE TOTAL PERCENT` | 百分比条 + 右侧百分比文本 |

## 数据流与生命周期

1. **加载期**：`core/*` 定义函数和常量；`sources/*` 顶部会执行少量
   环境探测（如 `uname -s`）；`handlers/*` 只做 `mr_register`（`00-cover.sh`
   例外，它在加载期注册标题行）。
2. **采集期**：`main.sh` 调 `collect_shared_scalars` 和
   `collect_platform_session`，把共享变量准备好。
3. **handler 期**：按注册顺序调用 `handler_*`，把行追加到字段数组。
4. **测量期**：`measure_fields` 批量算出 `NAME_W` / `DATA_W`（复杂文本只启动一次 Perl），
   再用 `measure_cover_lines` 保证标题不被截断，最后跑各 `_measure`。
5. **回填期**：跑各 `_fill`，此时 `DATA_W` 是最终值。
6. **渲染期**：`render_report` 一次性把标题、字段行和页脚居中排版后输出。

原则：**先占位、后回填**。任何依赖最终列宽的文本都不要在 handler 阶段写死宽度。

## 常用全局量

| 变量 | 含义 |
| --- | --- |
| `FIELD_LABELS` / `FIELD_VALUES` / `FIELD_BREAK_BEFORE` | 字段数组 |
| `FIELD_INDEX` | 最近一次 `mr_field` 的行号 |
| `NAME_W` / `DATA_W` | 左右两列内容宽度（`measure_fields` 之后有效） |
| `DATA_MAX` / `NAME_MAX` | 列宽上限，超长字段名会被截断 |
| `C_*` | ANSI 颜色，见 `core/00-bootstrap.sh` |
| `HORIZONTAL` / `DASHED_HORIZONTAL` / `TOP_LEFT` … | 边框字符 |
| `REPORT_MOCK_ENABLED` / `REPORT_PROFILE` / `REPORT_GPU_ENABLED` / `REPORT_SMART_ENABLED` | 运行开关 |

## 改标题与页脚

全部在 `src/handlers/00-cover.sh`：

```bash
REPORT_TITLE=${REPORT_TITLE-'服务器运行报告'}
REPORT_SUBTITLE=${REPORT_SUBTITLE-'PVE Platform'}
REPORT_ENVIRONMENT=${REPORT_ENVIRONMENT-'PRODUCTION'}

mr_cover_line "${C_TITLE}${REPORT_TITLE}${C_RESET}"
```

- 改字符串即可自定义。
- 注释掉 `mr_cover_line` 那一行就不显示。
- 想加一行：照抄一行 `mr_cover_line`。
- 环境变量可覆盖：`REPORT_TITLE='我的机器' ./machine_report.sh`，
  传空串（`REPORT_TITLE=''`）表示不显示该行。

页脚的 `SERVER` / `CLIENT` 在 `src/handlers/20-network.sh`，因为它们依赖主 IP。

## 数据源（sources）

| 文件 | 提供 |
| --- | --- |
| `system.sh` | mock 标量、OS、CPU、负载、运行时间、内存 |
| `platform.sh` | 厂商/型号/UUID、locale/时区/登录用户、网卡、DNS |
| `gpu-disk.sh` | `collect_gpu_rows`、`physical_disk_rows`、SMART 解析 |

约定：

- 输出纯文本或 TAB 分隔的 TSV，字段契约写在函数上方注释里。
- 所有外部命令都做失败兜底，出错返回空或占位符，不要 `exit`。
- mock 开启时必须先走演示数据，不能再查硬件：

```bash
physical_disk_rows() {
    if (( REPORT_MOCK_ENABLED == 1 )); then
        demo_disk_rows
        return 0
    fi
    ...
}
```

新增数据源时，建议单独成文件、函数名用 `collect_*` / `detect_*`，
handler 里直接调用，例如 `rows=$(collect_xxx)`。

## 编码约定

- **Bash 3.2 兼容**：macOS 自带 `/bin/bash` 是 3.2。不能用关联数组、
  `mapfile`、`local -n`、`${var@Q}` 等 4.x 特性。
- **宽度一律走 `mr_width` / `display_width`**，不能用 `${#text}` 计算中文宽度。
- **少起子进程**：能用 Bash 内建就不 `awk`/`sed`/`cut`；循环里尤其避免
  `$(...)`，优先用现成的 `_xxx_into VAR` 版本。
- **函数命名**：`collect_*` 采集、`detect_*` 探测、`format_*` 纯格式化、
  `_*_into` 写入变量的内部工具、`mr_*` 对外 API。
- **注释**：写“为什么”和字段契约，不写“这行赋值给谁”。
- **不要加跨次缓存**：每次运行重新采集；SMART 并行用的临时目录在采集结束
  立即删除。

## 常见坑

### 1. `set -u` + bash 3.2 的空数组

```bash
arr=()
copy=("${arr[@]}")     # bash 3.2 直接报 unbound variable
```

用下标循环，或先判断长度：

```bash
(( ${#arr[@]} > 0 )) && copy+=("${arr[@]}")
for ((i = 0; i < ${#arr[@]}; i++)); do echo "${arr[i]}"; done
```

### 2. `local` 是动态作用域

```bash
_set_into() {
    local out        # 如果调用方也传了 out，这个 local 会挡住写入
    printf -v out '%s' "$1"
}
```

所有 `_xxx_into` 的内部变量都用不会和调用方重名的前缀（如 `__var`、`__pct`），
否则外层拿不到值。

### 3. 宽度和颜色

带 ANSI 的字符串直接用 `${#s}` 会算错；中文、emoji、Nerd Font 也不能按字符数算。
统一用 `mr_width` / `pad_display` / `fit_display`。

### 4. `REPORT_PROFILE=1` 在 bash 3.2 下会变慢

3.2 没有 `EPOCHREALTIME`，打点会退化成每次启动 `perl`，profile 数字偏大。
测性能请用 bash 5（`/opt/homebrew/bin/bash`）。

### 5. mock 与真实数据

mock 是“整块替换”，不是“补空”。新写的采集函数如果也要支持 mock，
要在函数开头处理，否则 mock 打开后仍会查硬件。

## 性能

本脚本目标是“登录时跑一次”，不是每秒轮询，避免为了几毫秒引入复杂度。

现状（M4 Mac，含 3 块盘）：

- 总耗时约 `0.36–0.40s`
- `disk collect` 约 `170ms`，其中两块 USB 盘各 `130ms` 左右，
  已经是并行查询，墙钟取决于最慢的那块
- 其余阶段多为系统命令自身耗时（`ioreg`、`sw_vers`、`ifconfig`）

优化手段（按收益排序）：

1. 合并调用：`sw_vers`、`sysctl`、`who`、`df`、`mount` 都只跑一次。
2. 批量带宽测量：`_display_widths_batch` 一次 Perl 处理多串。
3. 避免子 shell：用 `_xxx_into` 版本写入变量。
4. 磁盘 SMART 按物理盘并行。

不要做的事：加跨次结果缓存（数据会过期）、为几十毫秒拆散可读性。

## 测试与自检

提交前跑一遍：

```bash
./build.sh
bash -n machine_report.sh

# 合并后的完整 shellcheck（片段里的 disable 不参与）
tmp=$(mktemp /tmp/report-lint.XXXXXX)
{ printf '#!/usr/bin/env bash\nset -u\n'
  for f in src/core/*.sh src/sources/*.sh src/handlers/*.sh src/main.sh; do
      printf '# shellcheck source=%s\n. %q\n' "$f" "$f"
  done; } >"$tmp"
shellcheck -x -a "$tmp"

# 演示数据必须完全可复现
REPORT_MOCK_ENABLED=1 ./machine_report.sh > /tmp/mock-new.out

# 真实模式 + 关掉可选数据源
./machine_report.sh
REPORT_SMART_ENABLED=0 ./machine_report.sh
REPORT_GPU_ENABLED=0 ./machine_report.sh

# macOS 自带 bash 3.2 也要能跑
/bin/bash ./machine_report.sh

# 分阶段耗时
REPORT_PROFILE=1 ./machine_report.sh >/dev/null
```

改 UI 时的判定标准：`REPORT_MOCK_ENABLED=1` 的输出与改动前逐字节一致
（除非你确实改了展示内容），真实模式只允许时间、负载、内存这类实时值变化。
