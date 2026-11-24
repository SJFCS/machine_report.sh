# 服务器报告

`report.sh` 是由 `src/` 下的源码片段合并生成的单文件脚本，请勿直接修改
生成的 `report.sh`。

## 构建

```bash
./build.sh
```

构建脚本按文件名排序合并 `src/*.sh`，因此新增源码片段时应使用数字前缀，
并确保文件名顺序与依赖顺序一致。合并后会先运行 `bash -n` 检查语法，再
原子替换目标文件并设置可执行权限。

## 输出与依赖

报告固定使用中文、emoji、ANSI 颜色和 Unicode 对齐。Unicode/ANSI 显示
宽度由 Perl 计算，支持中文、emoji、组合符和 Nerd Font 图标。标题、页脚
和全部字段行会合并到单个 Perl 进程渲染，避免逐单元格启动解释器。

运行依赖 Bash、awk 和 Perl 5。终端中默认启用颜色；设置 `NO_COLOR=1`
可关闭颜色，设置 `FORCE_COLOR=1` 可强制启用颜色。

```bash
REPORT_MOCK_ENABLED=1 ./report.sh
NO_COLOR=1 ./report.sh
FORCE_COLOR=1 ./report.sh
REPORT_PROFILE=1 ./report.sh >/dev/null
REPORT_GPU_ENABLED=0 ./report.sh
REPORT_GPU_TIMEOUT=5 ./report.sh
```

`REPORT_PROFILE=1` 会把操作系统、CPU、负载、内存、平台、网络、GPU、
磁盘、排版和最终渲染的耗时逐行写入 stderr，不改变报告正文。正常运行时
该开关关闭，不产生额外输出。

GPU 采集默认在 `nvidia-smi` 运行 1 秒时发送终止信号；超时后该轮按无
GPU 数据继续。可用 `REPORT_GPU_TIMEOUT` 调整秒数，设为 `0` 可取消限制。
如果驱动处于不可中断等待，终止信号也可能延迟生效；需要稳定速度时
应直接使用 `REPORT_GPU_ENABLED=0`。

## 源码结构

- `00-header.sh`：脚本说明、运行参数、颜色与边框常量
- `10-display-width.sh`：Unicode/ANSI 显示宽度计算与截断
- `15-format-core.sh`：无外部进程的定点数值与比例换算
- `20-system-collect.sh`：mock 数据与系统基础指标采集
- `30-platform-collect.sh`：平台、身份、Locale 与网卡采集
- `40-format.sh`：通用数值格式化
- `50-gpu-disk.sh`：GPU 与磁盘数据采集和格式化
- `60-memory-table.sh`：内存指标格式化与字段注册
- `70-report-fields.sh`：报告字段组装
- `80-layout.sh`：列宽、边框与条形图布局
- `90-render.sh`：动态值回填与最终渲染

数值换算优先使用 Bash 内建定点运算；只有无法用整数精度安全表达或需要
解析整段文本时才回退到 awk。标题、页脚和字段行合并为一次 Perl 渲染，
避免按单元格或按行启动解释器。
