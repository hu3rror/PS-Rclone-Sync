<#
.SYNOPSIS
    Runs rclone sync tasks defined in JSON configuration files with interactive file selection.
.DESCRIPTION
    Scans a 'configs' folder, presents an interactive console menu to choose configuration files,
    validates task settings using strongly-typed classes, executes rclone sync with structured JSON logs,
    and safely manages log cleanup based on JSON entries.
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

# -----------------------------------------------------------------------------
# 1. 强类型模型与 Fail-Fast 校验规则 (PowerShell Class)
# 参考官方文档: about_Classes
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

    # 构造函数
    SyncTaskConfig() {}

    # 从 PSCustomObject 安全转换并初始化对象
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

    # 前置断言校验 (Fail-Fast Validation)
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
# 2. 交互式配置文件选择函数
# -----------------------------------------------------------------------------
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
# 3. 任务执行与结构化日志解析函数
# -----------------------------------------------------------------------------
function Invoke-RcloneSyncTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [SyncTaskConfig]$TaskConfig,

        [Parameter(Mandatory = $true)]
        [string]$RclonePath,

        [Parameter(Mandatory = $true)]
        [string]$LogFolderPath
    )

    # 1. 强类型前置校验
    $TaskConfig.Validate()

    $timeStamp = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'
    $logFileName = "$($TaskConfig.taskName).$($TaskConfig.destName).${timeStamp}.log"
    $logFile = Join-Path -Path $LogFolderPath -ChildPath $logFileName

    # 2. 构建 rclone 参数
    $cmdArgs = [System.Collections.Generic.List[string]]::new()
    $cmdArgs.Add("sync")
    $cmdArgs.Add($TaskConfig.localFolder)
    $cmdArgs.Add("$($TaskConfig.destName):$($TaskConfig.destFolder)")

    foreach ($ex in $TaskConfig.exclude) {
        if (-not [string]::IsNullOrWhiteSpace($ex)) {
            $cmdArgs.Add("--exclude")
            $cmdArgs.Add($ex)
        }
    }

    # 强制启用结构化 JSON 日志记录以支持精确解析
    $cmdArgs.Add("--use-json-log")
    $cmdArgs.Add("--log-file=$logFile")

    if (-not [string]::IsNullOrWhiteSpace($TaskConfig.rcloneFlags)) {
        $flagTokens = $TaskConfig.rcloneFlags -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($token in $flagTokens) {
            # 防止重复叠加 --use-json-log
            if ($token -ne "--use-json-log") {
                $cmdArgs.Add($token)
            }
        }
    }

    if ($TaskConfig.showCommand) {
        $displayArgs = $cmdArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }
        Write-Host "$RclonePath $($displayArgs -join ' ')"
    }

    # 3. 安全调用进程
    try {
        & $RclonePath @cmdArgs
    }
    catch {
        Write-Error "Failed to execute rclone for task '$($TaskConfig.taskName)': $_"
        return
    }

    # 4. 结构化日志解析与清理 (取代易受干扰的纯文本匹配)
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
                        # 解析每行 JSON 日志对象 (Microsoft.PowerShell.Utility/ConvertFrom-Json)
                        $jsonEntry = $line | ConvertFrom-Json -ErrorAction Stop
                        if ($jsonEntry.msg -like "*There was nothing to transfer*") {
                            $isNothingToTransfer = $true
                            break
                        }
                    }
                    catch {
                        # 兜底纯文本检查
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

    # 5. 基于保留限制清理历史日志
    if ($TaskConfig.maximumLogFiles -gt 0) {
        $logFilter = "$($TaskConfig.taskName).$($TaskConfig.destName).*.log"
        Get-ChildItem -Path $LogFolderPath -Filter $logFilter -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime |
            Select-Object -SkipLast $TaskConfig.maximumLogFiles |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# 主执行流程
# -----------------------------------------------------------------------------
try {
    # 验证 rclone 可执行文件是否存在
    if (-not (Get-Command -Name $RclonePath -ErrorAction SilentlyContinue)) {
        throw "rclone executable not found at path: '$RclonePath'. Please ensure rclone is installed."
    }

    # 确保日志文件夹存在
    if (-not (Test-Path -Path $LogFolderPath -PathType Container)) {
        New-Item -Path $LogFolderPath -ItemType Directory -Force | Out-Null
    }

    # 获取目标配置文件
    $targetConfigFiles = @()

    if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
        if (-not (Test-Path -Path $ConfigFile -PathType Leaf)) {
            throw "Specified configuration file not found: '$ConfigFile'."
        }
        $targetConfigFiles += (Get-Item -Path $ConfigFile).FullName
    }
    else {
        $targetConfigFiles = Select-ConfigFile -FolderPath $ConfigsFolder
        if (-not $targetConfigFiles -or $targetConfigFiles.Count -eq 0) {
            return
        }
    }

    # 解析并执行任务
    foreach ($cfgFile in $targetConfigFiles) {
        Write-Host ">>> Processing Config: $cfgFile" -ForegroundColor Green

        $rawJson = Get-Content -Path $cfgFile -Raw -ErrorAction Stop
        $syncConfigObjects = $rawJson | ConvertFrom-Json -ErrorAction Stop

        foreach ($rawConfig in $syncConfigObjects) {
            # 将 PSCustomObject 映射为强类型 SyncTaskConfig
            $taskConfig = [SyncTaskConfig]::FromPSCustomObject($rawConfig)

            if ($taskConfig.enabled) {
                # 执行强类型任务（内部将触发 Fail-Fast 校验与结构化日志记录）
                Invoke-RcloneSyncTask `
                    -TaskConfig $taskConfig `
                    -RclonePath $RclonePath `
                    -LogFolderPath $LogFolderPath
            }
        }
    }
}
catch {
    Write-Error "Script execution failed: $_"
}