<#
.SYNOPSIS
    Runs rclone sync tasks defined in a JSON configuration file.
.DESCRIPTION
    Reads backup configuration settings from a JSON file, executes rclone sync commands,
    manages log files, and automatically cleans up empty logs and old historical log files.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFile = "config.json",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RclonePath = "rclone",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogFolderPath = (Join-Path -Path $PSScriptRoot -ChildPath "logs")
)

function Invoke-RcloneSyncTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalFolder,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestFolder,

        [Parameter()]
        [string]$TaskName = "Untitled",

        [Parameter()]
        [string[]]$Exclude = @(),

        [Parameter()]
        [string]$RcloneFlags = "",

        [Parameter()]
        [switch]$ShowCommand,

        [Parameter()]
        [int]$MaximumLogFiles = 15,

        [Parameter(Mandatory = $true)]
        [string]$RclonePath,

        [Parameter(Mandatory = $true)]
        [string]$LogFolderPath
    )

    $timeStamp = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'
    $logFileName = "${TaskName}.${DestName}.${timeStamp}.log"
    $logFile = Join-Path -Path $LogFolderPath -ChildPath $logFileName

    # Construct arguments list safely without Invoke-Expression
    $cmdArgs = [System.Collections.Generic.List[string]]::new()
    $cmdArgs.Add("sync")
    $cmdArgs.Add($LocalFolder)
    $cmdArgs.Add("${DestName}:${DestFolder}")

    foreach ($ex in $Exclude) {
        if (-not [string]::IsNullOrWhiteSpace($ex)) {
            $cmdArgs.Add("--exclude")
            $cmdArgs.Add($ex)
        }
    }

    $cmdArgs.Add("--log-file=$logFile")

    if (-not [string]::IsNullOrWhiteSpace($RcloneFlags)) {
        $flagTokens = $RcloneFlags -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($token in $flagTokens) {
            $cmdArgs.Add($token)
        }
    }

    if ($ShowCommand) {
        $displayArgs = $cmdArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }
        Write-Host "$RclonePath $($displayArgs -join ' ')"
    }

    # Execute rclone safely using the call operator
    try {
        & $RclonePath @cmdArgs
    }
    catch {
        Write-Error "Failed to execute rclone for task '${TaskName}': $_"
        return
    }

    # Remove empty or zero-transfer log files safely
    if (Test-Path -Path $logFile -PathType Leaf) {
        $fileItem = Get-Item -Path $logFile -ErrorAction SilentlyContinue
        if ($fileItem) {
            if ($fileItem.Length -eq 0) {
                Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
            }
            else {
                # Force array conversion to ensure line-level indexing
                $logLines = @(Get-Content -Path $logFile -ErrorAction SilentlyContinue)
                if ($logLines.Count -gt 0 -and $logLines[0] -like "*INFO  : There was nothing to transfer*") {
                    Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # Retention cleanup for log files
    if ($MaximumLogFiles -gt 0) {
        $logFilter = "${TaskName}.${DestName}.*.log"
        Get-ChildItem -Path $LogFolderPath -Filter $logFilter -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime |
            Select-Object -SkipLast $MaximumLogFiles |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ------ Main Execution Flow ------
try {
    # Check if rclone executable exists
    if (-not (Get-Command -Name $RclonePath -ErrorAction SilentlyContinue)) {
        throw "rclone executable not found at path: '$RclonePath'. Please ensure rclone is installed."
    }

    # Ensure log directory exists
    if (-not (Test-Path -Path $LogFolderPath -PathType Container)) {
        New-Item -Path $LogFolderPath -ItemType Directory -Force | Out-Null
    }

    # Verify configuration file path
    if (-not (Test-Path -Path $ConfigFile -PathType Leaf)) {
        throw "Sync configuration file not found: '$ConfigFile'."
    }

    # Load and parse configuration file
    $rawJson = Get-Content -Path $ConfigFile -Raw -ErrorAction Stop
    $syncConfig = $rawJson | ConvertFrom-Json -ErrorAction Stop

    # Process each enabled sync task
    foreach ($config in $syncConfig) {
        if ($config.enabled) {
            $taskNameParam = if ([string]::IsNullOrWhiteSpace($config.taskName)) { "Untitled" } else { $config.taskName }

            Invoke-RcloneSyncTask `
                -LocalFolder $config.localFolder `
                -DestName $config.destName `
                -DestFolder $config.destFolder `
                -TaskName $taskNameParam `
                -Exclude $config.exclude `
                -RcloneFlags $config.rcloneFlags `
                -ShowCommand:([bool]$config.showCommand) `
                -MaximumLogFiles ([int]$config.maximumLogFiles) `
                -RclonePath $RclonePath `
                -LogFolderPath $LogFolderPath
        }
    }
}
catch {
    Write-Error "Script execution failed: $_"
}