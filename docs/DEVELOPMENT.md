# 开发文档

面向要改这个脚本的人：加一行、加一个分组、加一个数据源，或者调整整体排版。
只写 handler 的话，看完「快速开始」和「API」就够了。

## 目录

## 一分钟了解架构

```md
src/
  core/       框架内核：宽度、数字、表格、布局、渲染、mr_* API
  sources/    纯数据采集：只输出文本或 TSV
  handlers/   展示层：一个文件一个 handler，决定“显示哪些行、长什么样”
  main.sh     执行入口：采集 → 跑 handler → 测宽 → 回填 → 渲染
build.sh      按 core → sources → handlers → main 合并成 machine_report.sh
```

分层规则：

- `sources/` 不认识 UI，只 `printf` 数据；不要在里面画线、加颜色。
- `handlers/` 认识 `mr_*`，负责把数据变成字段行。
  分隔线只声明“这一行上面要一条线”（`BREAK` 0/1/2 或 `mr_field_break`），
  具体画 `─` 还是 `┄`、画多长由 core 决定，handler 里不出现画线字符。
  整表列宽由 core 统一测量；局部多列对齐（如磁盘的 DEVICE/SPACE 三列）
  可以调用 core 的测量工具，但不要把画线逻辑搬进 handler。
- `core/` 只提供能力和最终渲染，不包含具体业务字段。

渲染流程：

```md
collect_shared_scalars()                              # OS/CPU/负载/内存等共享标量
collect_platform_session()                            # 厂商/型号/UUID/locale/时区/登录信息/NTP
for h in "${MR_HANDLERS[@]}"; do handler_$h; done     # 追加字段行
measure_fields()                                      # 计算 NAME_W / DATA_W
handler_xxx_measure()                                 # 可选：撑宽 DATA_W
handler_xxx_fill()                                    # 可选：回填条形图等依赖宽度的值
render_report()                                       # 画边框、居中、输出
```

## 构建与产物

```bash
./build.sh              # 生成 ./machine_report.sh
./build.sh /tmp/x.sh    # 输出到指定路径
```

- `build.sh` 里的 `VERSION` 是唯一版本号来源；构建时写入产物头部。
- `Date` 使用构建当天日期。
- 合并后会跑一次 `bash -n`，语法错误直接失败，不会写出半成品。
- `src/` 里的 `# shellcheck shell=bash`、片段级 `disable=SC2034/SC2154`
  只服务编辑器单文件检查，合并时统一删除；产物按完整规则检查。

改了 `src/` 之后一定要重新 `./build.sh` 并把 `machine_report.sh` 一起提交，
`install.sh` 安装的是构建产物，不是 `src/`。


## 速查表

### handler 骨架

```bash
handler_xxx()         { ... }                 # 必需：采集 + mr_field 加行
handler_xxx_measure() { ... }                 # 可选：撑宽 DATA_W
handler_xxx_fill()    { ... }                 # 可选：回填条形图/百分比
mr_register xxx                               # 注册；顺序即渲染顺序
```

### 字段与封面

| 函数                           | 说明                                |
| ------------------------------ | ----------------------------------- |
| `mr_field LABEL VALUE [BREAK]` | 追加一行；`BREAK` 0/1/2             |
| `mr_field_break LABEL VALUE`   | 追加一行并在上方画实线              |
| `mr_field_dashed LABEL VALUE`  | 追加一行并在上方画虚线              |
| `mr_update INDEX VALUE`        | 回填第 `INDEX` 行（`$FIELD_INDEX`） |
| `mr_cover_line TEXT`           | 表格上方加一行居中文字              |
| `mr_footer_line TEXT`          | 表格下方加一行居中文字              |

### 文本与图形

| 函数                                 | 说明                                 |
| ------------------------------------ | ------------------------------------ |
| `mr_width TEXT`                      | 显示列数（中文/ANSI 安全）           |
| `mr_pad TEXT WIDTH`                  | 右补空格到指定显示宽度               |
| `mr_fit TEXT WIDTH`                  | 超宽截断并以 `…` 结尾                |
| `mr_bar VALUE TOTAL [WIDTH]`         | 百分比条；省略 `WIDTH` 时用 `DATA_W` |
| `mr_percent_bar VALUE TOTAL PERCENT` | 百分比条 + 右侧百分比文本            |

### 分隔线

| 写法                      | 效果                 | 场景             |
| ------------------------- | -------------------- | ---------------- |
| `mr_field 'A' 'v'`        | 无分隔线             | 接在上一组里     |
| `mr_field_break 'A' 'v'`  | 上方实线             | 新的一组         |
| `mr_field_dashed 'A' 'v'` | 上方虚线             | 同一组里的下一条 |
| `mr_field 'A' 'v' 1`      | 同 `mr_field_break`  | 少写一行时用     |
| `mr_field 'A' 'v' 2`      | 同 `mr_field_dashed` | 少写一行时用     |

### 常用命令

```bash
./build.sh                                  # 构建 ./machine_report.sh
./build.sh /tmp/x.sh                        # 构建到临时路径（调试）
REPORT_MOCK_ENABLED=1 ./machine_report.sh   # 演示数据，输出可复现
REPORT_PROFILE=1 ./machine_report.sh >/dev/null   # 分阶段耗时（stderr）
REPORT_NTP_ENABLED=0 ./machine_report.sh    # 跳过 NTP 查询
./install.sh --source ./machine_report.sh   # 安装到 ~/.local，注册 mreport
```

## 快速开始：加一个 handler

新建 `src/handlers/70-mything.sh`：

```bash
# shellcheck shell=bash
#
# 本文件绘制的行：EXAMPLE / EXAMPLE BAR

handler_mything() {
    mr_field_break 'EXAMPLE' 'hello'   # 实线：从这里开始新的一组

    mr_field 'EXAMPLE BAR' ''
    MY_BAR_ROW=$FIELD_INDEX            # 先占位，等列宽确定
}

handler_mything_fill() {
    mr_update "$MY_BAR_ROW" "$(mr_bar 42 100)"
}

mr_register mything
```

然后 `./build.sh`，报告末尾会出现：

```text
├───────────────┼─────────────────────────────────┤
│ EXAMPLE       │ hello                           │
│ EXAMPLE BAR   │ ████████████████░░░░░░░░░░░░░░░ │
├───────────────┴─────────────────────────────────┤
```

- 文件顺序决定位置：`70-` 排在磁盘之后；想放中间就改名，例如 `25-mything.sh`。
- 不想显示某一行：注释掉对应的 `mr_field`。
- 不想显示整组：注释掉文件末尾的 `mr_register`。

## 例子

### 1. 独立区块：第一条用实线

```bash
handler_backup() {
    mr_field_break 'BACKUP' 'rsync · nightly'
    mr_field 'LAST RUN' '2026-11-25 03:00'
}

mr_register backup
```

效果：

```text
├───────────────┼──────────────────┤
│ BACKUP        │ rsync · nightly  │
│ LAST RUN      │ 2026-11-25 03:00 │
```

### 2. 接在别人的区块里：不画线

```bash
handler_misc() {
    mr_field 'SHELL' "${SHELL##*/}"
    mr_field 'TERM' "${TERM:-unknown}"
}

mr_register misc
```

第一行用 `mr_field`（`BREAK` 默认 0），所以直接接在上一组末尾，
不会出现分隔线。适合给自己加几行补充信息。

### 3. 一组多条目：条目之间用虚线

像磁盘那样“每块盘一组”，第一条实线、后面条条虚线：

```bash
handler_ports() {
    local line first=1
    while IFS=$'\t' read -r name state; do
        if (( first )); then
            mr_field_break "PORT $name" "$state"
            first=0
        else
            mr_field_dashed "PORT $name" "$state"
        fi
    done < <(printf '22\tlisten\n80\tlisten\n443\tlisten\n')
}

mr_register ports
```

效果：

```text
├───────────────┼─────────────────────────────────────────────────┤
│ PORT 22       │ listen                                          │
├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┼┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┤
│ PORT 80       │ listen                                          │
├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┼┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┤
│ PORT 443      │ listen                                          │
├───────────────┴─────────────────────────────────────────────────┤
```

`mr_field 'LABEL' 'VALUE' 2` 和 `mr_field_dashed 'LABEL' 'VALUE'` 完全等价。

### 4. 条形图 / 百分比：占位 + 回填

列宽要等所有行加完才知道，所以依赖 `DATA_W` 的内容分两步：

```bash
handler_diskfree() {
    mr_field_break 'DISK FREE' ''
    DISK_FREE_ROW=$FIELD_INDEX
}

handler_diskfree_fill() {
    local free=58 total=100
    mr_update "$DISK_FREE_ROW" "$(mr_bar "$free" "$total")"          # 占满 DATA_W
    # 也可以固定宽度：mr_bar "$free" "$total" 20
}

mr_register diskfree
```

百分比条 + 右侧百分比文字：

```bash
handler_diskfree_fill() {
    mr_update "$DISK_FREE_ROW" "$(mr_percent_bar 58 100 58.0)"
}
```

### 5. 完全自定义：命令、颜色、截断

```bash
handler_extras() {
    local uptime_text
    uptime_text=$(uptime 2>/dev/null)

    mr_field_break 'UPTIME RAW' "$(mr_fit "$uptime_text" 40)"
    mr_field 'STATUS' "${C_OK}OK${C_RESET}"
    mr_field 'WIDTH' "1 个中文 = $(mr_width 中) 列"
}

mr_register extras
```

- `mr_fit` 按**显示宽度**截断（中文算 2 列），超宽补 `…`。
- `${C_OK}` / `${C_RESET}` 是现成颜色，见 `core/00-bootstrap.sh`。
- 想右补空格对齐，用 `mr_pad 'text' 20`。

### 6. 只想改样式，不想加行

- 分隔线视觉：`mr_field`（无线）↔ `mr_field_break`（实线）↔ `mr_field_dashed`（虚线）
- 抬头/页脚：`src/handlers/00-cover.sh`，注释一行就隐藏一行
- 颜色：`src/core/00-bootstrap.sh` 的 `C_*`
- 列宽上下限：`src/core/00-bootstrap.sh` 的 `NAME_MIN/MAX`、`DATA_MIN/MAX`

分隔线怎么选，见上面的[速查表](#速查表)。

## handler 契约

每个 handler 最多三个函数，命名固定：

| 函数                       | 必需 | 时机                                  | 用途                        |
| -------------------------- | ---- | ------------------------------------- | --------------------------- |
| `handler_<name>()`         | 是   | 所有 handler 依次执行                 | 采集数据、`mr_field` 追加行 |
| `handler_<name>_measure()` | 否   | `measure_fields` 之后、所有 fill 之前 | 撑宽 `DATA_W`               |
| `handler_<name>_fill()`    | 否   | 所有 measure 之后                     | 回填条形图/百分比           |

`mr_register <name>` 决定注册顺序，也就是渲染顺序。文件名只影响注册顺序，
可以用 `00-`、`10-` 这类前缀调整。

分隔线（`BREAK`）：`0` 不画，`1` 实线，`2` 虚线。`DEVICE`/`SPACE` 这类
同一块内容的第二行用虚线，不同块之间用实线，是现有报告的惯例。

## 公开 API

实现在 `src/core/45-api.sh`。`mr_` 开头是对外契约，其余函数都可能变。

### 字段

| 函数                           | 说明                                        |
| ------------------------------ | ------------------------------------------- |
| `mr_field LABEL VALUE [BREAK]` | 追加一行                                    |
| `mr_field_break LABEL VALUE`   | 追加一行并在上方画实线                      |
| `mr_field_dashed LABEL VALUE`  | 追加一行并在上方画虚线                      |
| `mr_update INDEX VALUE`        | 回填第 `INDEX` 行（用 `$FIELD_INDEX` 记住） |

值里可以带 ANSI 颜色和中文，宽度由框架计算。

### 标题与页脚

| 函数                  | 说明                   |
| --------------------- | ---------------------- |
| `mr_cover_line TEXT`  | 表格上方加一行居中文字 |
| `mr_footer_line TEXT` | 表格下方加一行居中文字 |

可以调用任意多次，写几行显示几行，注释掉就隐藏；文字超过表格宽度时
表格自动变宽。

### 文本工具

| 函数                                 | 说明                                 |
| ------------------------------------ | ------------------------------------ |
| `mr_width TEXT`                      | 终端显示列数（中文/ANSI 安全）       |
| `mr_pad TEXT WIDTH`                  | 右补空格到指定显示宽度               |
| `mr_fit TEXT WIDTH`                  | 超宽时截断并以 `…` 结尾              |
| `mr_bar VALUE TOTAL [WIDTH]`         | 百分比条；省略 `WIDTH` 时用 `DATA_W` |
| `mr_percent_bar VALUE TOTAL PERCENT` | 百分比条 + 右侧百分比文本            |

## 数据流与生命周期

1. **加载期**：`core/*` 定义函数和常量；`sources/*` 顶部会执行少量
   环境探测（如 `uname -s`）；`handlers/*` 只做 `mr_register`（`00-cover.sh`
   例外，它在加载期注册标题行）。
2. **采集期**：`main.sh` 依次调度 `collect_shared_scalars` 和
   `collect_platform_session`；具体实现位于 `sources/`，把共享变量准备好。
3. **handler 期**：按注册顺序调用 `handler_*`，把行追加到字段数组。
4. **测量期**：`measure_fields` 批量算出 `NAME_W` / `DATA_W`（复杂文本只启动一次 Perl），
   再用 `measure_cover_lines` 保证标题不被截断，最后跑各 `_measure`。
5. **回填期**：跑各 `_fill`，此时 `DATA_W` 是最终值。
6. **渲染期**：`render_report` 一次性把标题、字段行和页脚居中排版后输出。

原则：**先占位、后回填**。任何依赖最终列宽的文本都不要在 handler 阶段写死宽度。

## 常用全局量

| 变量                                                                                     | 含义                                          |
| ---------------------------------------------------------------------------------------- | --------------------------------------------- |
| `FIELD_LABELS` / `FIELD_VALUES` / `FIELD_BREAK_BEFORE`                                   | 字段数组                                      |
| `FIELD_INDEX`                                                                            | 最近一次 `mr_field` 的行号                    |
| `NAME_W` / `DATA_W`                                                                      | 左右两列内容宽度（`measure_fields` 之后有效） |
| `DATA_MAX` / `NAME_MAX`                                                                  | 列宽上限，超长字段名会被截断                  |
| `C_*`                                                                                    | ANSI 颜色，见 `core/00-bootstrap.sh`          |
| `HORIZONTAL` / `DASHED_HORIZONTAL` / `TOP_LEFT` …                                        | 边框字符                                      |
| `REPORT_MOCK_ENABLED` / `REPORT_PROFILE` / `REPORT_GPU_ENABLED` / `REPORT_SMART_ENABLED` / `REPORT_NTP_ENABLED` | 运行开关 |
| `REPORT_GPU_TIMEOUT` / `REPORT_SMART_TIMEOUT` / `REPORT_NTP_TIMEOUT` | 外部命令超时秒数；`0` 表示不限时 |

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

| 文件          | 提供                                                 |
| ------------- | ---------------------------------------------------- |
| `system.sh`   | mock 标量、OS、CPU、负载、运行时间、内存             |
| `platform.sh` | 厂商/型号/UUID、locale/时区/登录用户、网卡、DNS、NTP |
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

NTP 采集由 `collect_ntp_info` 输出
`STATUS<TAB>SERVER<TAB>OFFSET`，状态取 `SYNCED`、`UNSYNCED`、
`DISABLED` 或 `UNKNOWN`；偏移已格式化为毫秒文本。
`collect_platform_session` 将其读入 `ntp_status`、`ntp_server`、
`ntp_offset`。Linux 依次尝试 `chronyc`、`timedatectl`、`ntpq`、
`ntpstat`，最后回退到配置文件与 `timedatectl` 同步标志；macOS 使用
`systemsetup` 和 `sntp`。新增来源时必须保留该 TSV 契约，并让缺失工具
降级为 `UNKNOWN` 或 `-`，不能中断报告。

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
