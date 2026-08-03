# Rclone 同步模块与执行脚本

[English](README.md) | 中文

基于 PowerShell 的强类型模块化 `rclone` 文件同步自动化解决方案，支持 JSON 结构化日志、交互式任务菜单、快速失败校验及原生管道流控制。

## 核心特性

- **面向对象架构**：基于强类型 `SyncTaskConfig` 类实现，支持路径与参数的快速失败（Fail-Fast）校验。
- **PowerShell 模块与管道支持**：核心功能导出为标准函数（`Get-RcloneSyncConfig`、`Invoke-RcloneSync`、`Show-RcloneSyncMenu`），全面支持管道操作。
- **交互式 CLI 菜单**：自动扫描 `configs/` 目录及脚本根目录下的 `.json` 配置，支持交互式单选或批量执行。
- **原生 WhatIf 与 Confirm**：原生集成 PowerShell `-WhatIf` 与 `-Confirm` 开关，支持预检（Dry-Run）操作。
- **结构化日志与清理机制**：
  - 强制采用 `--use-json-log` 生成结构化日志。
  - 自动清理空日志文件或提示 "nothing to transfer" 的无变更日志。
  - 根据 `maximumLogFiles` 自动清理超期的历史日志。
- **智能默认日志路径**：未指定 `-LogFolderPath` 时，模块自动选择：
  1. 若 `$PSScriptRoot\logs` 存在且包含至少一个 `.log` 文件，则沿用此旧路径（向后兼容）；
  2. 否则，使用用户级目录（Windows: `%APPDATA%\PS_RcloneSync\logs`；Unix: `~/.local/state/ps_rclonesync/logs`）；
  3. 若用户目录创建失败，自动回退至临时目录（`$env:TEMP\RcloneSyncLogs`）并输出警告。

## 项目结构

```text
├── configs/                # JSON 任务配置文件存放目录
├── config.json.example     # 任务配置模板文件
├── RcloneSync.ps1         # CLI 运行入口脚本
├── RcloneSync.psd1         # PowerShell 模块清单
├── RcloneSync.psm1         # 模块核心逻辑实现
├── README.md               # 英文文档
└── README_zh-CN.md         # 中文文档
```

## 环境准备

1. **PowerShell**：5.1 或更高版本（推荐 PowerShell Core 7+）。
2. **Rclone**：已安装并配置至系统环境变量 PATH，或通过 `-RclonePath` 参数指定可执行文件路径。

## 使用指南

### 命令行参数

| 参数 | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `-ConfigFile` | `string` | *(无)* | 指定单个 JSON 配置文件路径（若未指定，则进入交互菜单）。 |
| `-ConfigsFolder` | `string` | `.\configs` | 交互菜单扫描的配置文件夹路径。 |
| `-RclonePath` | `string` | `rclone` | rclone 可执行文件的路径或命令名。 |
| `-LogFolderPath` | `string` | *(由模块决定)* | 日志输出目录。若不指定，模块将按“智能默认日志路径”规则自动选择。 |
| `-WhatIf` | `switch` | `false` | 模拟执行，不产生实际文件变更。 |
| `-Confirm` | `switch` | `$false` | 在执行前请求确认。 |

> 提示：使用 `-Verbose` 可查看日志路径决策过程及详细运行信息。

### 1. 交互模式（默认）

直接运行脚本启动交互式菜单选单：

```powershell
.\RcloneSync.ps1
```

### 2. 指定配置文件运行

通过 `-ConfigFile` 显式指定需要执行的 JSON 配置文件：

```powershell
.\RcloneSync.ps1 -ConfigFile "configs/my-backup.json"
```

### 3. 预检模式（-WhatIf）

在不产生实际文件变更的情况下验证调度逻辑：

```powershell
.\RcloneSync.ps1 -ConfigFile "configs/my-backup.json" -WhatIf
```

### 4. 自定义 Rclone 路径与日志路径

```powershell
.\RcloneSync.ps1 -ConfigFile "configs/my-backup.json" -RclonePath "C:\Tools\rclone.exe" -LogFolderPath "D:\Logs\rclone"
```

### 5. 模块的高级管道用法

可直接导入 `.psd1` 模块并在自定义脚本中使用 Cmdlet：

```powershell
Import-Module .\RcloneSync.psd1

# 读取配置并通过管道传入同步引擎
Get-RcloneSyncConfig -Path "configs/my-backup.json" | Invoke-RcloneSync -RclonePath "rclone"
```

## 配置文件说明

任务配置以 JSON 数组形式存储，字段定义参见 `config.json.example`：

```json
[
    {
        "taskName": "Books",
        "localFolder": "C:\\Users\\username\\Books",
        "destName": "MyOneDrive",
        "destFolder": "/Backups/Books",
        "exclude": [
            "/*.txt",
            "/.git/"
        ],
        "rcloneFlags": "--dry-run --progress --fast-list --transfers=8 --max-backlog=-1 --log-level=NOTICE",
        "showCommand": true,
        "maximumLogFiles": 15,
        "enabled": true
    }
]
```

### 参数详细说明

| 属性字段 | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `taskName` | `string` | `"Untitled"` | 任务标识名称，用于输出与日志文件名前缀。 |
| `localFolder` | `string` | *(必填)* | 本地源路径。执行前会自动校验路径是否存在。 |
| `destName` | `string` | *(必填)* | 已在 `rclone config` 中配置的远端 Endpoint 名称。 |
| `destFolder` | `string` | *(必填)* | 远端目标目录路径。 |
| `exclude` | `string[]` | `[]` | 排除规则数组，自动转换为 `--exclude` 标志。 |
| `rcloneFlags` | `string` | `""` | 附加的 `rclone` 命令行参数。 |
| `showCommand` | `bool` | `true` | 执行前是否在控制台打印生成的完整 `rclone` 命令。 |
| `maximumLogFiles` | `int` | `15` | 每个任务保留的最大日志文件数量（`0` 表示不清理历史日志）。 |
| `enabled` | `bool` | `true` | 任务开关（`false` 时跳过该任务）。 |

## 日志管理

- 默认日志目录由模块自动选择（参见“智能默认日志路径”）。
- 每次同步产生一个独立日志文件，文件名格式：`<taskName>.<destName>.<时间戳>.log`。
- 若同步无任何传输（即 rclone 输出 "There was nothing to transfer"），该日志文件会被自动删除，避免产生大量无意义文件。
- 历史日志数量受 `maximumLogFiles` 控制，超出部分自动删除（按最后修改时间排序，保留最新文件）。
- 若需永久保留日志，可将 `maximumLogFiles` 设为 `0`。
- 通过 `-Verbose` 可实时查看日志文件写入路径。

## 故障排除

- **执行失败（`Cannot bind argument to parameter 'Path'`）**：通常因配置文件路径未正确传递，请检查 `-ConfigFile` 参数是否正确。
- **日志未生成**：检查 `-LogFolderPath` 指定目录是否可写；若未指定，查看模块默认路径决策过程（使用 `-Verbose`）。
- **权限错误**：若模块自动选择用户级目录，确保当前用户对该目录有写入权限；回退至临时目录后仍失败，会抛出终止异常，请检查临时目录可写性。