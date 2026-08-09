# Rclone Sync Module & Runner

English | [中文](README_zh-CN.md)

A strongly-typed, modular PowerShell automation solution for managing and executing `rclone` sync tasks with structured JSON logging, interactive task menus, fail-fast validation, and native pipeline support.

## Key Features

- **Class-Based Architecture**: Strongly-typed `SyncTaskConfig` configuration object with fail-fast path and parameter validation.
- **PowerShell Module & Pipeline Support**: Core functionality exported as reusable functions (`Invoke-EnvFile`, `Get-RcloneSyncConfig`, `Invoke-RcloneSync`, `Show-RcloneSyncMenu`).
- **`.env` File Support**: Loads environment variables (e.g. `RCLONE_CONFIG_PASS` for decrypting an encrypted rclone config) from an optional `.env` file in the script root. Variables are injected before sync and cleaned up automatically afterward.
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

## Environment File (.env)

An optional `.env` file in the **script root directory** (next to `RcloneSync.ps1`) is loaded automatically before sync runs. Each `KEY=VALUE` line is injected into the PowerShell process environment, making it available to every rclone invocation in the run.

This is especially useful for **encrypted rclone configs**: set `RCLONE_CONFIG_PASS` in `.env` so rclone can decrypt `rclone.conf` without prompting for the password interactively.

```text
# .env  (script root)
RCLONE_CONFIG_PASS=your-config-encryption-password
RCLONE_VERBOSE=1
```

### `.env` Parsing Rules

- Lines follow `KEY=VALUE`; both key and value are trimmed of surrounding whitespace.
- Lines starting with `#` and blank lines are ignored.
- Values may contain `=` (only the first `=` splits the line).
- A `KEY=` entry sets the variable to an empty string.
- A Bash-style `export KEY=VALUE` prefix is accepted and stripped.
- Duplicate keys resolve to the **last** occurrence.
- The file is read as UTF-8.

### Behavior & Security

- A missing `.env` file is **not an error** — it is silently skipped (visible only with `-Verbose`).
- Injected variables are removed from the environment **after** the sync pipeline completes (even if a task throws).
- `.env` values **override** any existing variable of the same name in the current session.
- The `.env` file is added to `.gitignore` to prevent accidental credential commits.
- `-Verbose` output lists only environment variable **names**, never their values, so secrets are not printed to the console.

### Using `Invoke-EnvFile` Directly

`Invoke-EnvFile` is also exported as a public cmdlet for use in your own scripts:

```powershell
Import-Module .\RcloneSync.psd1

# Load a .env file and inject its variables; returns the list of keys set
$keys = Invoke-EnvFile -Path "C:\path\to\.env" -Verbose

# ... run tasks ...

# Clean up the injected variables
foreach ($k in $keys) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
```

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
