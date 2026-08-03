# Rclone Sync Module & Runner

English | [中文](README_zh-CN.md)

A strongly-typed, modular PowerShell automation solution for managing and executing `rclone` sync tasks with structured JSON logging, interactive task menus, fail-fast validation, and native pipeline support.

## Key Features

- **Class-Based Architecture**: Strongly-typed `SyncTaskConfig` configuration object with fail-fast path and parameter validation.
- **PowerShell Module & Pipeline Support**: Core functionality exported as reusable functions (`Get-RcloneSyncConfig`, `Invoke-RcloneSync`, `Show-RcloneSyncMenu`).
- **Interactive CLI Menu**: Auto-discovers `.json` task files in the `configs/` folder and root script directory for easy interactive selection.
- **Native WhatIf & Confirm Support**: Supports standard PowerShell `-WhatIf` and `-Confirm` switches for dry-run safety checks.
- **Structured JSON Logging & Auto-Cleanup**: 
  - Enforces `--use-json-log` for structured output.
  - Automatically deletes empty log files or logs indicating "nothing to transfer".
  - Retains log files up to the configured `maximumLogFiles` limit per task.

## Repository Structure

```text
├── configs/                # Storage directory for task JSON configuration files
├── config.json.example     # Configuration file template
├── RcloneSync.ps1         # CLI runner script
├── RcloneSync.psd1         # PowerShell Module Manifest
├── RcloneSync.psm1         # Core PowerShell Module Implementation
├── README.md               # English documentation
└── README_zh-CN.md         # Chinese documentation
```

## Prerequisites

1. **PowerShell**: Version 5.1 or higher (PowerShell Core 7+ recommended).
2. **Rclone**: Installed and added to system PATH, or specified explicitly via `-RclonePath`.

## Quick Start

### 1. Interactive Execution (Default)

Run the script without arguments to open the interactive configuration selection menu:

```powershell
.\RcloneSync.ps1
```

### 2. Run Specific Configuration File

Specify a JSON configuration file directly:

```powershell
.\RcloneSync.ps1 -ConfigFile "configs/my-backup.json"
```

### 3. Dry-Run / Safety Check (-WhatIf)

Test execution logic without making any filesystem changes:

```powershell
.\RcloneSync.ps1 -ConfigFile "configs/my-backup.json" -WhatIf
```

### 4. Custom Rclone Executable & Log Location

```powershell
.\RcloneSync.ps1 -ConfigFile "configs/my-backup.json" -RclonePath "C:\Tools\rclone.exe" -LogFolderPath "D:\Logs\rclone"
```

### 5. Advanced PowerShell Pipeline Usage

You can import the module directly and chain exported cmdlets:

```powershell
Import-Module .\RcloneSync.psd1

# Load configs and stream to sync engine via pipeline
Get-RcloneSyncConfig -Path "configs/my-backup.json" | Invoke-RcloneSync -RclonePath "rclone"
```

## Configuration File Schema

Configurations are stored as a JSON array of task objects. Refer to `config.json.example` for details:

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

### Parameter Reference

| Property | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `taskName` | `string` | `"Untitled"` | Descriptive task name, also used for log file prefix. |
| `localFolder` | `string` | *(Required)* | Local source path to sync. Validated on execution. |
| `destName` | `string` | *(Required)* | Name of the configured rclone remote endpoint. |
| `destFolder` | `string` | *(Required)* | Remote directory path. |
| `exclude` | `string[]` | `[]` | Array of exclude patterns passed as `--exclude` options. |
| `rcloneFlags` | `string` | `""` | Additional flags forwarded directly to `rclone`. |
| `showCommand` | `bool` | `true` | Print the generated `rclone` execution string before running. |
| `maximumLogFiles` | `int` | `15` | Maximum retained log files per task (`0` disables retention cleanup). |
| `enabled` | `bool` | `true` | Toggle task execution (`false` skips execution). |
