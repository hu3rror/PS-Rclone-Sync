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
                $rawJson = Get-Content -Path $filePath -Raw -ErrorAction Stop
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
        if ([string]::IsNullOrWhiteSpace($LogFolderPath)) {
            $LogFolderPath = Join-Path -Path $PSScriptRoot -ChildPath "logs"
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

        # Ensure log directory exists
        if (-not (Test-Path -Path $LogFolderPath -PathType Container)) {
            New-Item -Path $LogFolderPath -ItemType Directory -Force | Out-Null
        }

        $timeStamp = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'
        $logFileName = "$($config.taskName).$($config.destName).${timeStamp}.log"
        $logFile = Join-Path -Path $LogFolderPath -ChildPath $logFileName

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
            $flagTokens = $config.rcloneFlags -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
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
        }
        catch {
            Write-Error "Failed to execute rclone for task '$($config.taskName)': $_"
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
                    $rawLogLines = @(Get-Content -Path $logFile -ErrorAction SilentlyContinue)

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

# Export public module cmdlets
Export-ModuleMember -Function Get-RcloneSyncConfig, Invoke-RcloneSync, Show-RcloneSyncMenu