# 服务器报告

`machine_report.sh` 是由 `src/` 下的源码片段合并生成的单文件脚本，请勿
直接修改生成文件。

## 依赖

### 运行时必需

| 依赖         | 要求                                                                                                       | 用途                                                 |
| ------------ | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| Bash         | 3.2 或更高；已在 3.2.57、5.3 测试                                                                          | 执行报告。登录 shell 是 zsh 时也需要可用的 Bash      |
| awk          | POSIX awk；macOS awk、gawk、mawk 均可                                                                      | GPU、磁盘和内存文本解析，条形图兜底计算              |
| Perl         | Perl 5，建议 5.14 或更高                                                                                   | UTF-8/ANSI 显示宽度计算和表格批量渲染                |
| 基础系统工具 | 通常由系统提供：`sed`、`tr`、`head`、`date`、`uname`、`hostname`、`who`、`df`、`getconf`、`id`、`readlink` | 系统信息采集、时间处理和安装配置；缺失时对应字段降级 |

脚本只使用 Perl 核心模块，不需要安装 CPAN 包。ANSI 正则内部固定使用
`C` locale，不需要为了脚本修改系统的 `LANG` 或 `LC_ALL`。

### 平台工具

Linux 完整采集通常还需要：

- `/proc` 和 `/sys`：CPU、内存、负载、运行时间和 DMI 的主要数据源。
- util-linux：`lsblk`、`lscpu`，用于磁盘和 CPU 信息。
- iproute2：`ip`，用于读取非回环 IPv4 网卡。
- coreutils：`df`、`nproc`、`date`、`timeout` 等基础命令。

macOS 自带 `sysctl`、`vm_stat`、`sw_vers`、`scutil`、`ioreg`、
`system_profiler`、`mount`、`df`、awk 和 Perl，系统默认环境即可运行。
Apple Silicon 的 GPU 型号、核心数、统一内存占用和利用率来自 `ioreg`；
本地 APFS/HFS 卷（启动卷和 `/Volumes`）通过 `df` 与 `mount` 展示。

### 可选工具

| 工具                  | 启用内容                               | 缺失时的行为                                       |
| --------------------- | -------------------------------------- | -------------------------------------------------- |
| `nvidia-smi`          | NVIDIA GPU 型号、显存和利用率          | 显示 `GPU -`，可用 `REPORT_GPU_ENABLED=0` 跳过采集 |
| `lsblk`               | Linux 物理磁盘、分区、文件系统与挂载点 | 不输出物理磁盘行                                   |
| `ip`                  | IPv4 网卡与主 IP                       | 不输出网卡行                                       |
| `lscpu`               | Linux CPU 型号与频率                   | 回退读取 `/proc/cpuinfo`，频率可能显示为 `-`       |
| `dmidecode`           | sysfs 不可用时的 DMI 厂商、型号和 UUID | 对应字段显示 `UNKNOWN`；通常需要 root              |
| `systemd-detect-virt` | 虚拟化类型                             | 回退 DMI 信息，可能显示 `BARE METAL`               |
| `timedatectl`         | IANA 时区名称                          | 回退 `/etc/timezone` 或 `/etc/localtime`           |
| `timeout`             | 限制 `nvidia-smi` 运行时间             | 回退使用 Perl `alarm` 实现超时                     |
| `resolvectl`          | 系统中配置的上游 DNS                   | 回退读取 `/etc/resolv.conf`                        |
| `smartctl`            | 磁盘 SMART 健康、磨损程度和 CRC/INTEG 错误数 | 对应项显示 `N/A`；可用 `REPORT_SMART_ENABLED=0` 跳过 |

SMART 采集依赖 smartmontools。Linux 通常需要 root 才能读取磁盘的
SMART 数据，普通用户运行时对应项显示 `N/A`；USB 转接的磁盘可能还需要
为 `smartctl` 指定 `-d sat` 等设备类型。单块磁盘默认最多等待 2 秒，
可用 `REPORT_SMART_TIMEOUT` 调整，设为 `0` 可取消限制。NVMe 通常不暴露
CRC 错误计数，此时改用 `Media and Data Integrity Errors`，展示为简写
`INTEG`；SATA/SAS 仍显示 `CRC`。

### SMART 字段说明

报告中的 SMART 行形如：

```text
SMART  │ HEALTH PASSED · WEAR 4% · INTEG 0
SMART  │ HEALTH PASSED · WEAR 4% · CRC 0
```

| 字段          | 含义                                                                 | 数据来源                                                       |
| ------------- | -------------------------------------------------------------------- | -------------------------------------------------------------- |
| `HEALTH`      | 磁盘整体健康自检结果；`PASSED`/`OK` 正常，`FAILED` 表示厂商预测可能故障 | `smartctl` 的 overall-health 或 SMART Health Status            |
| `WEAR`        | 已消耗寿命百分比，数值越低越好；`4%` 表示约剩 96% 寿命                | NVMe `Percentage Used`；SATA 用规范化剩余寿命换算              |
| `INTEG`       | NVMe 的介质/数据完整性错误数，不是 CRC；`0` 为正常，持续增长需关注；也是错误计数不可用时的默认标签 | NVMe `Media and Data Integrity Errors`                         |
| `CRC`         | SATA/SAS 链路传输 CRC 错误数；`0` 为正常，增长常见于线材、背板或接口问题 | `UDMA_CRC_Error_Count` 等 SMART 属性或 SAS `CRC errors`        |

`WEAR`、`INTEG`、`CRC` 为 `-` 表示该项不可用，不一定表示磁盘故障。
HDD 通常没有磨损百分比，因此 `WEAR` 会显示 `-`。

`INTEG` 既是 NVMe `Media and Data Integrity Errors` 的简写，也是无法识别
错误计数类型时的默认标签：`HEALTH N/A · WEAR - · INTEG -` 表示没有拿到
可用的 SMART 健康或错误数据。
即使 `HEALTH` 有结果，只要设备没有暴露 CRC 或 `Media and Data Integrity
Errors`，也会显示类似 `HEALTH PASSED · WEAR - · INTEG -`。
常见原因是未安装 `smartctl`、普通用户没有读取权限、磁盘处于待机/超时、
USB 转接盒不支持直通 SMART，或虚拟磁盘本身不提供 SMART。macOS 对内置
Apple NVMe 也可能拒绝 `smartctl` 访问，此时显示
`HEALTH N/A · WEAR - · INTEG -`。`INTEG -` 只表示数据不可用，不代表
磁盘一定有故障。

设置 `REPORT_MOCK_ENABLED=1` 时，GPU、磁盘和部分标量使用内置演示数据，
不要求 `nvidia-smi` 或 `lsblk`。脚本和安装器不需要 Python、Node.js、
`jq` 或任何第三方 Perl 模块。

### 安装器依赖

远程安装需要 `curl` 或 `wget`。安装到当前用户只需要普通写权限；
`--all-users` 需要 `sudo` 或 root。

### 常见发行版安装

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install bash gawk perl util-linux iproute2 coreutils curl smartmontools

# Fedora / RHEL
sudo dnf install bash gawk perl util-linux iproute coreutils curl smartmontools

# Arch Linux
sudo pacman -S bash gawk perl util-linux iproute2 coreutils curl smartmontools

# macOS
# Bash、awk、Perl 已随系统提供；可选安装新版 Bash 和 smartmontools
brew install bash smartmontools
```

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
- 启动配置：见下方 bash/zsh 表格

当前用户和 root 系统安装写入的位置不同：

| shell | 当前用户安装 | root 系统安装 |
| ----- | ------------ | ------------- |
| bash  | `~/.bashrc`（交互式），以及 `~/.bash_profile`、`~/.bash_login`、`~/.profile` 中 bash 登录时实际读取的第一个文件 | `/etc/profile` |
| zsh   | `~/.zshrc`（交互式，登录 zsh 也会读取） | 已有的 `/etc/zprofile` 或 `/etc/zsh/zprofile` |

当前用户安装会在每次打开交互式 bash/zsh 时自动展示一次报告；root 系统
安装会在登录时自动展示。临时关闭自动展示可设置 `MREPORT_AUTORUN=0`；
安装时使用 `--no-autostart` 可永久关闭。

安装给所有用户（需要 root），写入系统登录 profile：

```bash
curl -fsSL https://raw.githubusercontent.com/SJFCS/machine_report.sh/main/install.sh | sudo bash -s -- --system
```

`--all-users` 是 `--system` 的别名。

所有用户共用以下路径：

- 报告：`/usr/local/lib/machine_report/machine_report.sh`
- 命令：`/usr/local/bin/mreport`
- 启动配置：bash 写入 `/etc/profile`；zsh 写入已有的
  `/etc/zprofile` 或 `/etc/zsh/zprofile`

root 系统安装只写登录 profile，不遍历每个用户的 `.bashrc`/`.zshrc`。
所有配置都放在带 `machine_report` 标记的托管块中：重复安装会替换旧块，
不会重复追加；卸载也只删除这个块。

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
shell 配置中的其他内容。

### `--no-autostart` 后仍然自动展示

`--no-autostart` 只清理当前安装范围。当前用户安装无法修改 `/etc`，因此
以前用 root 安装过的系统级启动块仍会执行。安装器会提示类似：

```text
提示：检测到系统级自动展示配置：/etc/zprofile
如需关闭，请运行：sudo ./install.sh --system --no-autostart
```

保留系统级 `mreport` 命令但关闭自动展示：

```bash
sudo ./install.sh --system --no-autostart
```

如果连系统级安装一起移除：

```bash
sudo ./install.sh --system --uninstall
```

## 输出与颜色

报告固定使用中文、emoji、ANSI 颜色和 Unicode 对齐。Unicode/ANSI 显示
宽度由 Perl 计算，支持中文、emoji、组合符和 Nerd Font 图标。标题、页脚
和全部字段行会合并到单个 Perl 进程渲染，避免逐单元格启动解释器。

建议使用支持 UTF-8 和 ANSI 颜色的等宽终端。终端中默认启用颜色；设置
`NO_COLOR=1` 可关闭颜色，设置 `FORCE_COLOR=1` 可强制启用颜色。

```bash
REPORT_MOCK_ENABLED=1 ./machine_report.sh
NO_COLOR=1 ./machine_report.sh
FORCE_COLOR=1 ./machine_report.sh
REPORT_PROFILE=1 ./machine_report.sh >/dev/null
REPORT_GPU_ENABLED=0 ./machine_report.sh
REPORT_GPU_TIMEOUT=5 ./machine_report.sh
REPORT_SMART_ENABLED=0 ./machine_report.sh
REPORT_SMART_TIMEOUT=5 ./machine_report.sh
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
