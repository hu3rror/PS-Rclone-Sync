<#
.SYNOPSIS
    Runs rclone sync tasks defined in JSON configuration files with interactive file selection.
.DESCRIPTION
    Scans a 'configs' folder, presents an interactive console menu to choose configuration files,
    reads task settings, executes rclone sync, and manages logs safely.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigsFolder = (Join-Path -Path $PSScriptRoot -ChildPath "configs"),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RclonePath = "rclone",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogFolderPath = (Join-Path -Path $PSScriptRoot -ChildPath "logs")
)

# Interactive configuration selector
function Select-ConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    $files = @()
    if (Test-Path -Path $FolderPath -PathType Container) {
        $files = @(Get-ChildItem -Path $FolderPath -Filter "*.json" -File -ErrorAction SilentlyContinue)
    }

    # Include root config.json if present
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

# Task Execution Processor
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

    # Execute rclone command safely
    try {
        & $RclonePath @cmdArgs
    }
    catch {
        Write-Error "Failed to execute rclone for task '${TaskName}': $_"
        return
    }

    # Clean up empty or no-transfer log files
    if (Test-Path -Path $logFile -PathType Leaf) {
        $fileItem = Get-Item -Path $logFile -ErrorAction SilentlyContinue
        if ($fileItem) {
            if ($fileItem.Length -eq 0) {
                Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
            }
            else {
                $logLines = @(Get-Content -Path $logFile -ErrorAction SilentlyContinue)
                if ($logLines.Count -gt 0 -and $logLines[0] -like "*INFO  : There was nothing to transfer*") {
                    Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # Clean up old log files based on retention limit
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
    # Verify rclone executable
    if (-not (Get-Command -Name $RclonePath -ErrorAction SilentlyContinue)) {
        throw "rclone executable not found at path: '$RclonePath'. Please ensure rclone is installed."
    }

    # Ensure log directory exists
    if (-not (Test-Path -Path $LogFolderPath -PathType Container)) {
        New-Item -Path $LogFolderPath -ItemType Directory -Force | Out-Null
    }

    # Resolve target configuration files
    $targetConfigFiles = @()

    if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
        # Explicit non-interactive CLI mode
        if (-not (Test-Path -Path $ConfigFile -PathType Leaf)) {
            throw "Specified configuration file not found: '$ConfigFile'."
        }
        $targetConfigFiles += (Get-Item -Path $ConfigFile).FullName
    }
    else {
        # Interactive selection mode
        $targetConfigFiles = Select-ConfigFile -FolderPath $ConfigsFolder
        if (-not $targetConfigFiles -or $targetConfigFiles.Count -eq 0) {
            return
        }
    }

    # Process tasks in selected configuration files
    foreach ($cfgFile in $targetConfigFiles) {
        Write-Host ">>> Processing Config: $cfgFile" -ForegroundColor Green

        $rawJson = Get-Content -Path $cfgFile -Raw -ErrorAction Stop
        $syncConfig = $rawJson | ConvertFrom-Json -ErrorAction Stop

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
}
catch {
    Write-Error "Script execution failed: $_"
}