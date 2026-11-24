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

## 源码结构

- `00-header.sh`：脚本说明、运行参数、颜色与边框常量
- `10-display-width.sh`：Unicode/ANSI 显示宽度计算与截断
- `20-system-collect.sh`：mock 数据与系统基础指标采集
- `30-platform-collect.sh`：平台、身份、Locale 与网卡采集
- `40-format.sh`：通用数值格式化
- `50-gpu-disk.sh`：GPU 与磁盘数据采集和格式化
- `60-memory-table.sh`：内存指标格式化与字段注册
- `70-report-fields.sh`：报告字段组装
- `80-layout.sh`：列宽、边框与条形图布局
- `90-render.sh`：动态值回填与最终渲染
