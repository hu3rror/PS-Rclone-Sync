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

    # Load the optional .env file from the script root and inject its
    # KEY=VALUE pairs into the process environment (e.g. RCLONE_CONFIG_PASS
    # for decrypting an encrypted rclone config). This is optional and
    # non-fatal - a missing .env file is silently skipped.
    $envFileKeys = Invoke-EnvFile -Path (Join-Path $PSScriptRoot '.env')

    # Execute sync via PowerShell Pipeline chaining.
    try {
        foreach ($cfgFile in $targetConfigFiles) {
            Write-Host ">>> Processing Config: $cfgFile" -ForegroundColor Green

            # Pipeline: Get-RcloneSyncConfig | Invoke-RcloneSync
            Get-RcloneSyncConfig -Path $cfgFile |
                Invoke-RcloneSync -RclonePath $RclonePath -LogFolderPath $LogFolderPath
        }
    }
    finally {
        # Remove every environment variable injected from .env so that
        # credentials (e.g. RCLONE_CONFIG_PASS) do not leak to subsequent
        # commands in this session after the sync pipeline completes.
        # The finally block guarantees cleanup even if a task throws.
        foreach ($envKey in $envFileKeys) {
            Remove-Item "Env:\$envKey" -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Error "Script execution failed: $_"
}