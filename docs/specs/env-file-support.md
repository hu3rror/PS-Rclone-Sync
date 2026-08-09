# Spec: `.env` File Support for RcloneSync

## Problem Statement

Users who use rclone with an **encrypted configuration file** (`rclone.conf` encrypted with a password) must currently enter the config password interactively every time rclone starts. This breaks unattended/automated sync runs. Rclone supports the `RCLONE_CONFIG_PASS` environment variable to decrypt the config automatically, but the module provides no way to load it from a convenient, project-local source.

Without this feature, users either:
- Hardcode the password in their profile/session startup, which is brittle and machine-specific.
- Use Windows Task Scheduler with stored credentials, adding operational overhead.
- Forego encrypted configs entirely, weakening security.

## Solution

Add a general-purpose `.env` file parser (`Invoke-EnvFile`) to the RcloneSync module, exported as a public cmdlet. The runner script (`RcloneSync.ps1`) calls it before the sync pipeline to load environment variables from a `.env` file in the script directory. After all sync tasks complete, the runner cleans up the injected variables.

The `.env` file is optional — if absent, the module silently skips (only verbose output reports it). The file is git-ignored to prevent accidental credential commits.

## User Stories

1. As a user with an encrypted rclone config, I want to place `RCLONE_CONFIG_PASS` in a `.env` file in the script root, so that rclone can decrypt my config automatically during sync runs.

2. As a user running multiple config files in batch, I want the `.env` file to be loaded once before all tasks, so that all sync tasks share the same environment variable context.

3. As a user who wants environment variables to be cleaned up after sync, I want the runner to remove all injected variables after the pipeline completes, so that credentials don't leak to subsequent commands in the same session.

4. As a user who runs `-Verbose`, I want to see which variables were loaded from `.env` without their values being printed to the console, so that I can debug the loading process without exposing secrets.

5. As a user running with `-WhatIf`, I want `Invoke-EnvFile` to report which variables it would set without actually modifying the environment, so that I can preview the effect.

6. As a user transitioning from another `.env`-aware tool, I want the parser to support the `export` prefix convention (`export KEY=VALUE`), so that I don't need to edit my existing `.env` files.

7. As a user with a non-UTF-8 `.env` file, I want the module to consistently read the file as UTF-8, so that special characters are handled correctly across PowerShell 5.1 and 7+.

8. As a user who accidentally puts a malformed line (no `=` sign) in `.env`, I want the parser to skip that line with a verbose message instead of aborting the entire sync.

9. As a user who wants `.env` to always override session-level variables, I want the module to overwrite any existing env var with the value from the file, so that the project environment is authoritative.

10. As a user who duplicates a key in `.env` (e.g., `RCLONE_CONFIG_PASS` appears twice), I want the last occurrence to win, so that I can override values at the bottom of the file without editing earlier lines.

11. As a developer who wants to write tests for the parsing logic, I want `Invoke-EnvFile` to be a standalone exported function with no hidden state, so that it can be tested in isolation.

12. As a user who uses the module directly (not via the runner script), I want to be able to call `Invoke-EnvFile` myself with a custom path, so that I can use it in my own scripts.

## Implementation Decisions

### New Function: `Invoke-EnvFile`

- **Cmdlet name**: `Invoke-EnvFile`
- **Scope**: Exported module function, registered in `RcloneSync.psd1` under `FunctionsToExport`.
- **Parameters**:
  - `-Path` (Mandatory, string): Path to the `.env` file.
  - `-Verbose` (inherited from `[CmdletBinding()]`): Prints loaded key names (but not values).
  - `-WhatIf` (inherited from `SupportsShouldProcess`): Prints which variables would be set without modifying the environment.
- **Returns**: `[string[]]` — the list of keys that were successfully loaded from the file. An empty array means no variables were loaded (file missing, empty, or all lines were comments/blanks).
- **Naming convention**: `Invoke-EnvFile` follows the module's existing verb-noun pattern (`Get-RcloneSyncConfig`, `Invoke-RcloneSync`, `Show-RcloneSyncMenu`).

### Parsing Format (Level 1 + `export` prefix)

Line format: `KEY=VALUE`

| Rule | Behavior |
|------|----------|
| `#` at start of line | Comment — skip entirely, no verbose output |
| Blank/whitespace-only lines | Skip silently |
| `KEY=VALUE` | Trim whitespace from both key and value. Set `$env:KEY = VALUE` |
| `  KEY  =  VALUE  ` | Trimmed to `KEY`, `VALUE` |
| `KEY=` (empty value) | Set `$env:KEY = ""` |
| `export KEY=VALUE` | Strip `export ` prefix, then parse as normal |
| Line without `=` | Skip, verbose message: "Skipping malformed line: ..." |
| Duplicate keys | Last occurrence wins (overwrites previous) |
| UTF-8 encoding | Explicit `-Encoding UTF8` on `Get-Content` |

### Precedence

`.env` always **overwrites** any existing value of the same environment variable in the current session. This is by design — the project `.env` is the authoritative source. If a user wants to override it temporarily, they can remove the line from `.env` or rename the file.

### Runner Script Integration (`RcloneSync.ps1`)

The runner script is modified to call `Invoke-EnvFile` and clean up after the pipeline:

```
1. Import-Module
2. Invoke-EnvFile -Path $PSScriptRoot\.env -Verbose   → $envKeys
3. Verify rclone executable
4. Resolve config files (menu or -ConfigFile)
5. try {
       foreach ($cfgFile in $targetConfigFiles) {
           Get-RcloneSyncConfig | Invoke-RcloneSync ...
       }
   } finally {
       foreach ($key in $envKeys) {
           Remove-Item "Env:\$key" -ErrorAction SilentlyContinue
       }
   }
```

The `finally` block ensures cleanup even if the sync pipeline throws a terminating error. The cleanup only removes keys that were actually injected by `Invoke-EnvFile` (not all env vars).

### Security

- `.env` must be added to `.gitignore` to prevent accidental commits.
- `-Verbose` output lists **key names only**, never values.
- `-WhatIf` output shows which keys would be set, also without values.
- The `showCommand` functionality in `Invoke-RcloneSync` prints the rclone command line only (env vars are inherited, not passed as arguments), so no password exposure there.
- After the sync pipeline completes, all injected variables are removed from the environment.

### Idempotency

`Invoke-EnvFile` is stateless — each call re-reads the file and sets all variables. It does not track whether it was called before. The runner script calls it exactly once.

### Encoding

Explicitly use `-Encoding UTF8` on `Get-Content` for consistency with the existing `Get-RcloneSyncConfig` which already specifies UTF-8 encoding.

## Testing Decisions

### What makes a good test

Tests should verify **external behavior** of `Invoke-EnvFile`:
- What keys it returns.
- Whether `$env:` variables are set (or not set) with the correct values.
- Whether it throws on the expected error conditions.
- Whether `-WhatIf` suppresses side effects.
- Whether cleanup (removing the injected keys) restores the environment.

Tests should **not** test implementation details like internal variable names, the order of processing, or the exact text of verbose messages.

### Test seam

**One seam**: A new test file `tests/Test-EnvFile.ps1` that tests the exported `Invoke-EnvFile` function directly (no module-scope trick needed, since it's a public API).

### Prior art

The test follows the pattern established by `Test-ArgTokenizer.ps1`:
- `Import-Module -Force` at the top.
- Per-test `Assert` helper function.
- PASS/FAIL output with summary.
- Exit code 1 on any failure.
- Cleanup after temporary files.

Unlike `Test-ArgTokenizer.ps1`, `Invoke-EnvFile` is **exported**, so the test can call it directly as `Invoke-EnvFile` without the `& $module { ... }` scope trick.

### Test cases to cover

| # | Scenario | Verifies |
|---|----------|----------|
| 1 | Basic `KEY=VALUE` | Returns `@("KEY")`, `$env:KEY` is set to `VALUE` |
| 2 | Multiple keys | Returns all keys, each env var set correctly |
| 3 | `#` comments skipped | Comment lines ignored, not in returned keys |
| 4 | Blank lines skipped | No effect on output |
| 5 | `KEY=` empty value | `$env:KEY` is set to `""` |
| 6 | ` KEY = VALUE ` with spaces | Trimmed correctly: `KEY` → `VALUE` |
| 7 | `export KEY=VALUE` prefix | Stripped, treated as `KEY=VALUE` |
| 8 | Duplicate key, last wins | Returns key once, value is from last occurrence |
| 9 | Missing `.env` file | Returns empty array, no error |
| 10 | Empty `.env` file | Returns empty array |
| 11 | Malformed line (no `=`) | Skipped, not in returned keys, no error |
| 12 | `-WhatIf` suppresses side effects | `$env:` not modified, keys listed in message |
| 13 | UTF-8 encoded file with non-ASCII characters | Correctly parsed |
| 14 | Cleanup after invoke | `Remove-Item Env:\KEY` removes the variable |

## Out of Scope

- **Quoted value support** (e.g., `KEY="value with spaces"` or `KEY='value with spaces'`). Level 1 parsing does not handle quotes — values with spaces are not supported. If this becomes a need, the parser can be upgraded.
- **Inline comments** (e.g., `KEY=VALUE # comment`). The `#` is treated as part of the value. Only lines starting with `#` are comments.
- **Escaped characters** or variable interpolation inside values.
- **Multi-line values** (backslash continuation).
- **Environment variable expansion** (e.g., `KEY=$OTHER_VAR`).
- **Validation** of the value of `RCLONE_CONFIG_PASS` or any other specific variable. The parser is general-purpose and does not validate any key's value.
- **Pre-flight check** that rclone can actually decrypt the config with the given password. This is rclone's responsibility.

## Further Notes

- The `.env` file is expected to be in the **script root directory** (where `RcloneSync.ps1` lives), not the module directory. The runner script passes `Join-Path $PSScriptRoot '.env'` as the `-Path` argument.
- The `-Verbose` flag on `Invoke-EnvFile` is the only way to see which keys were loaded. Without it, the function is silent.
- If `Invoke-EnvFile` is called from a non-interactive context (e.g., Task Scheduler), the `-Verbose` output will go to the PowerShell information stream, which can be captured by standard logging.
- This spec does not prescribe a specific file path layout — the implementation should follow the existing module structure.