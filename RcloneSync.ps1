<#
.SYNOPSIS
    CLI Runner script leveraging the RcloneSync PowerShell Module.
.DESCRIPTION
    Loads RcloneSync module, resolves JSON configs, and pipes sync configurations to Invoke-RcloneSync.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$ConfigsFolder,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RclonePath = "rclone",

    [Parameter(Mandatory = $false)]
    [string]$LogFolderPath
)

try {
    # Resolve default paths inside script body for PowerShell 5.1 compatibility
    if ([string]::IsNullOrWhiteSpace($ConfigsFolder)) {
        $ConfigsFolder = Join-Path -Path $PSScriptRoot -ChildPath "configs"
    }

    if ([string]::IsNullOrWhiteSpace($LogFolderPath)) {
        $LogFolderPath = Join-Path -Path $PSScriptRoot -ChildPath "logs"
    }

    # Import local RcloneSync module
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "RcloneSync.psm1"
    Import-Module -Name $modulePath -Force

    # Verify rclone executable
    if (-not (Get-Command -Name $RclonePath -ErrorAction SilentlyContinue)) {
        throw "rclone executable not found at path: '$RclonePath'. Please ensure rclone is installed."
    }

    # Resolve configuration files
    $targetConfigFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
        if (-not (Test-Path -Path $ConfigFile -PathType Leaf)) {
            throw "Specified configuration file not found: '$ConfigFile'."
        }
        $targetConfigFiles += (Get-Item -Path $ConfigFile).FullName
    }
    else {
        $targetConfigFiles = Show-RcloneSyncMenu -FolderPath $ConfigsFolder
        if (-not $targetConfigFiles -or $targetConfigFiles.Count -eq 0) {
            return
        }
    }

    # Execute sync via PowerShell Pipeline chaining
    foreach ($cfgFile in $targetConfigFiles) {
        Write-Host ">>> Processing Config: $cfgFile" -ForegroundColor Green

        # Pipeline: Get-RcloneSyncConfig | Invoke-RcloneSync
        Get-RcloneSyncConfig -Path $cfgFile |
            Invoke-RcloneSync -RclonePath $RclonePath -LogFolderPath $LogFolderPath
    }
}
catch {
    Write-Error "Script execution failed: $_"
}