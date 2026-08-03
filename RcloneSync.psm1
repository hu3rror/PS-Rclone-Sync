# =============================================================================
# RcloneSync PowerShell Module
# =============================================================================

# -----------------------------------------------------------------------------
# Class: SyncTaskConfig
# Represents a strongly-typed sync task configuration with fail-fast validation.
# -----------------------------------------------------------------------------
class SyncTaskConfig {
    [string]$taskName = "Untitled"
    [string]$localFolder
    [string]$destName
    [string]$destFolder
    [string[]]$exclude = @()
    [string]$rcloneFlags = ""
    [bool]$showCommand = $true
    [int]$maximumLogFiles = 15
    [bool]$enabled = $true

    SyncTaskConfig() {}

    # Converts PSCustomObject (from ConvertFrom-Json) to strongly-typed SyncTaskConfig
    static [SyncTaskConfig] FromPSCustomObject([PSCustomObject]$obj) {
        $config = [SyncTaskConfig]::new()

        if ($null -ne $obj.taskName -and -not [string]::IsNullOrWhiteSpace($obj.taskName)) {
            $config.taskName = $obj.taskName
        }
        if ($null -ne $obj.localFolder) { $config.localFolder = $obj.localFolder }
        if ($null -ne $obj.destName)    { $config.destName = $obj.destName }
        if ($null -ne $obj.destFolder)  { $config.destFolder = $obj.destFolder }
        if ($null -ne $obj.exclude)     { $config.exclude = [string[]]$obj.exclude }
        if ($null -ne $obj.rcloneFlags) { $config.rcloneFlags = $obj.rcloneFlags }
        if ($null -ne $obj.showCommand) { $config.showCommand = [bool]$obj.showCommand }
        if ($null -ne $obj.maximumLogFiles) { $config.maximumLogFiles = [int]$obj.maximumLogFiles }
        if ($null -ne $obj.enabled)     { $config.enabled = [bool]$obj.enabled }

        return $config
    }

    # Performs assertion and validates essential configuration parameters
    [void] Validate() {
        if ([string]::IsNullOrWhiteSpace($this.localFolder)) {
            throw "Task '$($this.taskName)': Parameter 'localFolder' cannot be empty."
        }
        if (-not (Test-Path -Path $this.localFolder)) {
            throw "Task '$($this.taskName)': Local path '$($this.localFolder)' does not exist."
        }
        if ([string]::IsNullOrWhiteSpace($this.destName)) {
            throw "Task '$($this.taskName)': Parameter 'destName' cannot be empty."
        }
        if ([string]::IsNullOrWhiteSpace($this.destFolder)) {
            throw "Task '$($this.taskName)': Parameter 'destFolder' cannot be empty."
        }
        if ($this.maximumLogFiles -lt 0) {
            throw "Task '$($this.taskName)': Parameter 'maximumLogFiles' must be greater than or equal to 0."
        }
    }
}

# -----------------------------------------------------------------------------
# Private helper: ConvertTo-ArgTokens
# Quote-aware tokenizer for the rcloneFlags string. Splits on unquoted
# whitespace while preserving the contents of single- or double-quoted
# spans (quote characters themselves are stripped from the output).
#
# This is a "deep module": the public surface is a single input string in,
# a single string[] out, with no side effects and no dependency on module
# state. All complexity (quote tracking, malformed-input detection) is
# hidden inside. It is intentionally NOT exported — it is an internal
# implementation detail of Invoke-RcloneSync's flag parsing, not part of
# the module's public contract.
#
# Supported:
#   - Paired double quotes:  --exclude "file with space"
#   - Paired single quotes:  --include 'a b c'
#   - Quotes after '=':      --include="a b c"  ->  --include=a b c
#
# Not supported (by design, see spec Non-goals):
#   - Escaped quote characters inside a quoted span (e.g. \")
#   - Mixed/nested quoting (e.g. "it's a test")
#
# Throws on unmatched/unterminated quotes rather than silently guessing,
# so a malformed config fails loudly instead of producing a subtly wrong
# rclone command line.
# -----------------------------------------------------------------------------
function ConvertTo-ArgTokens {
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputString
    )

    $tokens = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($InputString)) {
        return , $tokens.ToArray()
    }

    $current = [System.Text.StringBuilder]::new()
    $quoteChar = $null      # $null when outside a quoted span; '"' or "'" while inside one
    $tokenHasContent = $false

    for ($i = 0; $i -lt $InputString.Length; $i++) {
        $ch = $InputString[$i]

        if ($null -ne $quoteChar) {
            # Inside a quoted span: everything is literal until the matching quote.
            if ($ch -eq $quoteChar) {
                $quoteChar = $null
            }
            else {
                [void]$current.Append($ch)
            }
            continue
        }

        if ($ch -eq '"' -or $ch -eq "'") {
            # Enter a quoted span. Marks the token as having content even if
            # the quoted span turns out to be empty (e.g. --exclude "").
            $quoteChar = $ch
            $tokenHasContent = $true
            continue
        }

        if ([char]::IsWhiteSpace($ch)) {
            if ($tokenHasContent) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
                $tokenHasContent = $false
            }
            continue
        }

        [void]$current.Append($ch)
        $tokenHasContent = $true
    }

    if ($null -ne $quoteChar) {
        throw "Unmatched quote in rcloneFlags: '$InputString'"
    }

    if ($tokenHasContent) {
        $tokens.Add($current.ToString())
    }

    # The unary comma prevents PowerShell from unrolling a single/empty
    # array back into scalars/nothing across the function-return boundary.
    return , $tokens.ToArray()
}

# -----------------------------------------------------------------------------
# Cmdlet: Get-RcloneSyncConfig
# Loads JSON configuration files and emits SyncTaskConfig objects to the pipeline.
# -----------------------------------------------------------------------------
function Get-RcloneSyncConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias("FullName")]
        [string[]]$Path
    )

    process {
        foreach ($filePath in $Path) {
            if (-not (Test-Path -Path $filePath -PathType Leaf)) {
                Write-Error "Configuration file not found: '$filePath'."
                continue
            }

            try {
                $rawJson = Get-Content -Path $filePath -Raw -Encoding UTF8 -ErrorAction Stop
                $objects = $rawJson | ConvertFrom-Json -ErrorAction Stop

                foreach ($obj in $objects) {
                    $taskConfig = [SyncTaskConfig]::FromPSCustomObject($obj)
                    Write-Output $taskConfig
                }
            }
            catch {
                Write-Error "Failed to parse JSON file '$filePath': $_"
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Cmdlet: Invoke-RcloneSync
# Executes rclone sync task. Native support for -WhatIf and pipeline input.
#
# NOTE (step 3 of 4): after invoking rclone, $LASTEXITCODE is now checked.
# A non-zero exit code is treated as a per-task failure: Write-Error +
# return (non-terminating - the pipeline continues to the next task), and
# the log-cleanup logic below is skipped entirely so the log file is
# unconditionally retained for troubleshooting. This is layered on top of
# the step 2 tokenizer change; log-cleanup behavior on the success path
# (exit code 0) is unchanged.
# -----------------------------------------------------------------------------
function Invoke-RcloneSync {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [psobject]$TaskConfig,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RclonePath = "rclone",

        [Parameter(Mandatory = $false)]
        [string]$LogFolderPath
    )

    process {
        # Resolve default log folder if not specified
        if ([string]::IsNullOrWhiteSpace($LogFolderPath)) {
            $LogFolderPath = Get-DefaultLogFolderPath
            Write-Verbose "Using default log folder: $LogFolderPath"
        }
        # Normalize input pipeline object to SyncTaskConfig
        [SyncTaskConfig]$config = $null
        if ($TaskConfig -is [SyncTaskConfig]) {
            $config = $TaskConfig
        }
        else {
            $config = [SyncTaskConfig]::FromPSCustomObject($TaskConfig)
        }

        # Skip disabled tasks
        if (-not $config.enabled) {
            Write-Verbose "Task '$($config.taskName)' is disabled. Skipping."
            return
        }

        # Fail-fast validation
        $config.Validate()

        $targetStr = "$($config.destName):$($config.destFolder)"
        $actionStr = "Synchronize local folder '$($config.localFolder)' to remote '$targetStr'"

        # Native PowerShell -WhatIf and -Confirm guard check
        if (-not $PSCmdlet.ShouldProcess($targetStr, $actionStr)) {
            return
        }

        # Ensure log directory exists, with fallback to temp directory on failure
        try {
            if (-not (Test-Path -Path $LogFolderPath -PathType Container)) {
                New-Item -Path $LogFolderPath -ItemType Directory -Force | Out-Null
            }
        }
        catch {
            $fallbackPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "RcloneSyncLogs"
            Write-Warning "Failed to create log directory '$LogFolderPath': $_ . Falling back to temporary directory '$fallbackPath'."
            $LogFolderPath = $fallbackPath
            # Attempt to create fallback directory
            try {
                if (-not (Test-Path -Path $LogFolderPath -PathType Container)) {
                    New-Item -Path $LogFolderPath -ItemType Directory -Force | Out-Null
                }
            }
            catch {
                Write-Error "Cannot create fallback log directory '$LogFolderPath': $_ . Logging will be disabled."
                # Instead of throwing, we could set LogFolderPath to $null and skip logging,
                # but spec says we should fail hard if even temp is unusable.
                throw "Unable to create log directory. Aborting task."
            }
        }

        $timeStamp = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'
        $logFileName = "$($config.taskName).$($config.destName).${timeStamp}.log"
        $logFile = Join-Path -Path $LogFolderPath -ChildPath $logFileName
        Write-Verbose "Log file will be written to: $logFile"

        # Build rclone execution arguments
        $cmdArgs = [System.Collections.Generic.List[string]]::new()
        $cmdArgs.Add("sync")
        $cmdArgs.Add($config.localFolder)
        $cmdArgs.Add($targetStr)

        foreach ($ex in $config.exclude) {
            if (-not [string]::IsNullOrWhiteSpace($ex)) {
                $cmdArgs.Add("--exclude")
                $cmdArgs.Add($ex)
            }
        }

        # Enforce structured JSON log output
        $cmdArgs.Add("--use-json-log")
        $cmdArgs.Add("--log-file=$logFile")

        if (-not [string]::IsNullOrWhiteSpace($config.rcloneFlags)) {
            $flagTokens = ConvertTo-ArgTokens -InputString $config.rcloneFlags
            foreach ($token in $flagTokens) {
                if ($token -ne "--use-json-log") {
                    $cmdArgs.Add($token)
                }
            }
        }

        if ($config.showCommand) {
            $displayArgs = $cmdArgs | ForEach-Object {
                if ($_ -match '\s') { "`"$_`"" } else { $_ }
            }
            Write-Host "$RclonePath $($displayArgs -join ' ')"
        }

        # Execute process safely
        try {
            & $RclonePath @cmdArgs
            # Capture $LASTEXITCODE immediately, inside the same try block and
            # right after invocation, before any other statement has a chance
            # to silently overwrite this automatic variable.
            $rcloneExitCode = $LASTEXITCODE
        }
        catch {
            # This branch only fires when the invocation itself could not
            # start (e.g. executable not found) - a distinct failure mode
            # from "process ran and returned a non-zero exit code" below.
            Write-Error "Failed to execute rclone for task '$($config.taskName)': $_"
            return
        }

        # A non-zero exit code means rclone ran but reported failure. Treat
        # every non-zero code uniformly as failure (no severity tiering).
        # This is non-terminating: log the error and move on to the next
        # pipeline item rather than aborting the whole batch. The log file
        # is deliberately left in place (log cleanup below is skipped
        # entirely) so it remains available for troubleshooting.
        if ($rcloneExitCode -ne 0) {
            Write-Error "Task '$($config.taskName)' failed: rclone exited with code $rcloneExitCode. Log file retained for troubleshooting at '$logFile'."
            return
        }

        # Process structured JSON log file
        if (Test-Path -Path $logFile -PathType Leaf) {
            $fileItem = Get-Item -Path $logFile -ErrorAction SilentlyContinue
            if ($fileItem) {
                if ($fileItem.Length -eq 0) {
                    Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
                }
                else {
                    $isNothingToTransfer = $false
                    $rawLogLines = @(Get-Content -Path $logFile -Encoding UTF8 -ErrorAction SilentlyContinue)

                    foreach ($line in $rawLogLines) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        try {
                            $jsonEntry = $line | ConvertFrom-Json -ErrorAction Stop
                            if ($jsonEntry.msg -like "*There was nothing to transfer*") {
                                $isNothingToTransfer = $true
                                break
                            }
                        }
                        catch {
                            if ($line -like "*There was nothing to transfer*") {
                                $isNothingToTransfer = $true
                                break
                            }
                        }
                    }

                    if ($isNothingToTransfer) {
                        Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        # Retain maximum log files limit
        if ($config.maximumLogFiles -gt 0) {
            $logFilter = "$($config.taskName).$($config.destName).*.log"
            Get-ChildItem -Path $LogFolderPath -Filter $logFilter -File -ErrorAction SilentlyContinue |
                Sort-Object -Property LastWriteTime |
                Select-Object -SkipLast $config.maximumLogFiles |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# Function: Show-RcloneSyncMenu
# Displays interactive menu for configuration selection.
# -----------------------------------------------------------------------------
function Show-RcloneSyncMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$FolderPath
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        $FolderPath = Join-Path -Path $PSScriptRoot -ChildPath "configs"
    }

    $files = @()
    if (Test-Path -Path $FolderPath -PathType Container) {
        $files = @(Get-ChildItem -Path $FolderPath -Filter "*.json" -File -ErrorAction SilentlyContinue)
    }

    $rootConfig = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
    if (Test-Path -Path $rootConfig -PathType Leaf) {
        $rootItem = Get-Item -Path $rootConfig
        if ($files.FullName -notcontains $rootItem.FullName) {
            $files += $rootItem
        }
    }

    if ($files.Count -eq 0) {
        throw "No JSON configuration files found in folder '$FolderPath' or script root."
    }

    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " Available Sync Configuration Files"        -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host " [$($i + 1)] $($files[$i].Name)"
    }
    Write-Host " [A] Run ALL Configuration Files"          -ForegroundColor Yellow
    Write-Host " [Q] Quit"                                 -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Cyan

    while ($true) {
        $selection = Read-Host -Prompt "Select an option (1-$($files.Count), A, Q)"
        if ([string]::IsNullOrWhiteSpace($selection)) { continue }
        $selection = $selection.Trim()

        if ($selection -eq 'Q' -or $selection -eq 'q') {
            Write-Host "Operation cancelled by user." -ForegroundColor Yellow
            return $null
        }

        if ($selection -eq 'A' -or $selection -eq 'a') {
            return $files.FullName
        }

        $index = 0
        if ([int]::TryParse($selection, [ref]$index) -and $index -ge 1 -and $index -le $files.Count) {
            return @($files[$index - 1].FullName)
        }

        Write-Host "Invalid selection '$selection'. Please enter a valid index, 'A', or 'Q'." -ForegroundColor Red
    }
}

# -----------------------------------------------------------------------------
# Private helper: Get-DefaultLogFolderPath
# Resolves the default log folder path for Invoke-RcloneSync.
# -----------------------------------------------------------------------------
function Get-DefaultLogFolderPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $scriptRoot = $PSScriptRoot
    $oldLogPath = Join-Path -Path $scriptRoot -ChildPath "logs"

    if (Test-Path -Path $oldLogPath -PathType Container) {
        $logFiles = Get-ChildItem -Path $oldLogPath -Filter "*.log" -File -ErrorAction SilentlyContinue
        if ($logFiles.Count -gt 0) {
            return $oldLogPath
        }
    }

    $isWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    if ($isWindows) {
        $base = [Environment]::GetFolderPath('ApplicationData')
        $userLogPath = Join-Path -Path $base -ChildPath "PS_RcloneSync\logs"
    } else {
        $home = [Environment]::GetEnvironmentVariable('HOME')
        $userLogPath = Join-Path -Path $home -ChildPath ".local/state/ps_rclonesync/logs"
    }

    return $userLogPath
}

# Export public module cmdlets
# ConvertTo-ArgTokens is intentionally NOT exported - it is a private
# implementation detail, not part of the module's public contract.
Export-ModuleMember -Function Get-RcloneSyncConfig, Invoke-RcloneSync, Show-RcloneSyncMenu