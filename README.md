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
- **Smart Default Log Path**: When `-LogFolderPath` is not specified, the module automatically selects:
  1. The legacy `$PSScriptRoot\logs` folder **only if** it exists and contains at least one `.log` file (backward compatibility);
  2. Otherwise, uses a user-level directory (Windows: `%APPDATA%\PS_RcloneSync\logs`; Unix: `~/.local/state/ps_rclonesync/logs`);
  3. If the user-level directory cannot be created, falls back to the system temp directory (`$env:TEMP\RcloneSyncLogs`) with a warning.

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

### Command-Line Parameters

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-ConfigFile` | `string` | *(none)* | Path to a single JSON configuration file. If omitted, interactive menu is launched. |
| `-ConfigsFolder` | `string` | `.\configs` | Folder scanned for JSON configurations in interactive mode. |
| `-RclonePath` | `string` | `rclone` | Path or command name of the rclone executable. |
| `-LogFolderPath` | `string` | *(determined by module)* | Directory for log output. If not specified, the module applies the "smart default log path" logic. |
| `-WhatIf` | `switch` | `false` | Simulate execution without making actual changes. |
| `-Confirm` | `switch` | `$false` | Prompt for confirmation before each action. |

> Tip: Use `-Verbose` to see the log path decision process and detailed runtime messages.

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

## Log Management

- Default log directory is automatically chosen by the module (see "Smart Default Log Path" above).
- Each sync run produces a separate log file named `<taskName>.<destName>.<timestamp>.log`.
- If sync results in "nothing to transfer", the log file is automatically removed to avoid clutter.
- Historical logs are capped by `maximumLogFiles`; older files are deleted (by last write time, keeping newest).
- Set `maximumLogFiles` to `0` to disable automatic cleanup.
- Use `-Verbose` to monitor the exact log file path being written.

## Troubleshooting

- **Execution failure (`Cannot bind argument to parameter 'Path'`)**: Usually caused by an incorrect `-ConfigFile` path. Verify the provided path.
- **No log generated**: Check write permissions for `-LogFolderPath`; if not specified, inspect the default path decision using `-Verbose`.
- **Permission errors**: If the module selects a user-level directory, ensure the current user has write permissions. If fallback to temp also fails, the task will abort; check temp directory writability.
