# 服务器报告

`machine_report.sh` 是由 `src/` 下的源码片段合并生成的单文件脚本，请勿
直接修改生成文件。

## 构建

```bash
./build.sh
```

构建脚本按文件名排序合并 `src/*.sh`，因此新增源码片段时应使用数字前缀，
并确保文件名顺序与依赖顺序一致。合并后会先运行 `bash -n` 检查语法，再
原子替换目标文件并设置可执行权限。构建日期由 `build.sh` 每次自动写入
文件头，版本号则在 `build.sh` 的 `VERSION` 变量中维护。

## 安装

从 GitHub Raw 安装到当前用户，并注册 `mreport` 快捷命令：

```bash
curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh | bash
```

默认安装位置：

- 报告：`~/.local/share/machine_report/machine_report.sh`
- 命令：`~/.local/bin/mreport`
- 启动配置：`~/.bashrc`、`~/.zshrc`

安装器会在交互式终端启动时自动展示一次报告。临时关闭自动展示可设置
`MREPORT_AUTORUN=0`；安装时使用 `--no-autostart` 可永久关闭。

安装给所有用户，并注册到系统级 bash/zsh 启动配置：

```bash
curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh | sudo bash -s -- --system
```

所有用户共用以下路径：

- 报告：`/usr/local/lib/machine_report/machine_report.sh`
- 命令：`/usr/local/bin/mreport`
- 启动配置：`/etc/profile.d/machine_report.sh`，以及系统已有的
  `/etc/zsh/zshrc` 或 `/etc/zshrc`

也可以从本地安装：

```bash
sudo ./install.sh --system
```

从本地构建产物安装：

```bash
./install.sh --source ./machine_report.sh
```

安装后也可以随时手动执行：

```bash
mreport
```

## 卸载

卸载当前用户的安装：

```bash
curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh | bash -s -- --uninstall
```

卸载所有用户的安装：

```bash
curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh | sudo bash -s -- --system --uninstall
```

在本地仓库中也可以直接卸载：

```bash
./install.sh --uninstall
sudo ./install.sh --system --uninstall
```

卸载会删除 `mreport` 命令、报告文件和安装器写入的启动配置块，不会改动
shell 配置中的其他内容。`--system --uninstall`

## 输出与依赖

报告固定使用中文、emoji、ANSI 颜色和 Unicode 对齐。Unicode/ANSI 显示
宽度由 Perl 计算，支持中文、emoji、组合符和 Nerd Font 图标。标题、页脚
和全部字段行会合并到单个 Perl 进程渲染，避免逐单元格启动解释器。

运行依赖 Bash、awk 和 Perl 5。终端中默认启用颜色；设置 `NO_COLOR=1`
可关闭颜色，设置 `FORCE_COLOR=1` 可强制启用颜色。

```bash
REPORT_MOCK_ENABLED=1 ./machine_report.sh
NO_COLOR=1 ./machine_report.sh
FORCE_COLOR=1 ./machine_report.sh
REPORT_PROFILE=1 ./machine_report.sh >/dev/null
REPORT_GPU_ENABLED=0 ./machine_report.sh
REPORT_GPU_TIMEOUT=5 ./machine_report.sh
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

## 常用变量

```bash
# 耗时统计
REPORT_PROFILE=1 
# 关闭gpu查询
REPORT_GPU_ENABLED=0
```
