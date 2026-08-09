@{
    # Module manifest for RcloneSync
    RootModule = 'RcloneSync.psm1'
    ModuleVersion = '2.0.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'Developer'
    CompanyName = 'Custom'
    Copyright = '(c) All rights reserved.'
    Description = 'PowerShell module for managing and executing rclone sync tasks with JSON configs.'
    PowerShellVersion = '5.1'

    # Functions to export from this module
    FunctionsToExport = @('Invoke-EnvFile', 'Get-RcloneSyncConfig', 'Invoke-RcloneSync', 'Show-RcloneSyncMenu')

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = '*'

    # Aliases to export from this module
    AliasesToExport = @()
}