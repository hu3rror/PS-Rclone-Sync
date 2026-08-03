<#
.SYNOPSIS
    Integration test for Step 3: verifies $LASTEXITCODE handling in
    Invoke-RcloneSync.
.DESCRIPTION
    Uses a fake "rclone" (a plain PowerShell script) whose behavior is
    controlled via two environment variables so each test case can force
    a specific exit code and log content without needing a real rclone
    installation:

        FAKE_RCLONE_EXIT_CODE   - integer exit code the fake process returns
        FAKE_RCLONE_LOG_CONTENT - 'success' | 'nothing' | 'empty'
                                   controls what the fake process writes to
                                   the --log-file path it was given, mimicking
                                   real rclone's --use-json-log output.

    Run from the directory containing RcloneSync.psm1:
        .\Test-ExitCodeHandling.ps1
#>

param(
    [string]$ModulePath = (Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "RcloneSync.psm1")
)

if (-not (Test-Path -Path $ModulePath -PathType Leaf)) {
    throw "Module file not found: $ModulePath"
}

Import-Module -Name $ModulePath -Force

$failCount = 0
$passCount = 0

# --- Test harness setup -----------------------------------------------------

$workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("RcloneSyncExitTest-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

$localFolder = Join-Path -Path $workDir -ChildPath "local"
$logFolder   = Join-Path -Path $workDir -ChildPath "logs"
New-Item -Path $localFolder -ItemType Directory -Force | Out-Null
New-Item -Path $logFolder -ItemType Directory -Force | Out-Null

$fakeRclonePath = Join-Path -Path $workDir -ChildPath "fake-rclone.ps1"

@'
param()

$logFileArg = $args | Where-Object { $_ -like "--log-file=*" }
$logFilePath = $null
if ($logFileArg) {
    $logFilePath = $logFileArg.Substring(11)
}

if ($logFilePath) {
    switch ($env:FAKE_RCLONE_LOG_CONTENT) {
        "nothing" { Set-Content -Path $logFilePath -Value "{`"level`":`"info`",`"msg`":`"There was nothing to transfer`"}" -Encoding utf8 }
        "empty"   { New-Item -Path $logFilePath -ItemType File -Force | Out-Null }
        default   { Set-Content -Path $logFilePath -Value "{`"level`":`"info`",`"msg`":`"Transferred: 3 files`"}" -Encoding utf8 }
    }
}

$code = 0
if ($env:FAKE_RCLONE_EXIT_CODE) {
    $code = [int]$env:FAKE_RCLONE_EXIT_CODE
}
exit $code
'@ | Set-Content -Path $fakeRclonePath -Encoding utf8

function New-TaskConfig {
    param(
        [string]$TaskName,
        [string]$LocalFolder = $localFolder
    )

    return [PSCustomObject]@{
        taskName        = $TaskName
        localFolder     = $LocalFolder
        destName        = "FakeRemote"
        destFolder      = "/Backups/Test"
        exclude         = @()
        rcloneFlags     = ""
        showCommand     = $false
        maximumLogFiles = 5
        enabled         = $true
    }
}

function Get-LatestLogFile {
    param([string]$TaskName)
    Get-ChildItem -Path $logFolder -Filter "$TaskName.*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1
}

function Assert {
    param(
        [string]$Description,
        [bool]$Condition,
        [string]$Detail = ""
    )
    if ($Condition) {
        Write-Host "[PASS] $Description" -ForegroundColor Green
        $script:passCount++
    }
    else {
        Write-Host "[FAIL] $Description" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" }
        $script:failCount++
    }
}

Write-Host "=== Invoke-RcloneSync exit-code handling tests ===" -ForegroundColor Cyan

# --- Case A: exit 0 + "nothing to transfer" log -> log deleted (existing success path unchanged) ---
$env:FAKE_RCLONE_EXIT_CODE = "0"
$env:FAKE_RCLONE_LOG_CONTENT = "nothing"
$errOutput = $null
New-TaskConfig -TaskName "CaseA" | Invoke-RcloneSync -RclonePath $fakeRclonePath -LogFolderPath $logFolder -Confirm:$false -ErrorVariable errOutput -ErrorAction SilentlyContinue
$logFile = Get-LatestLogFile -TaskName "CaseA"
Assert -Description "Case A: exit 0, 'nothing to transfer' log gets cleaned up (success path unchanged)" `
    -Condition ($null -eq $logFile) `
    -Detail "Expected no log file to remain, found: $($logFile.FullName)"
Assert -Description "Case A: no error written on success" `
    -Condition ($errOutput.Count -eq 0)

# --- Case B: non-zero exit + "nothing to transfer" log -> log RETAINED despite matching keyword ---
$env:FAKE_RCLONE_EXIT_CODE = "5"
$env:FAKE_RCLONE_LOG_CONTENT = "nothing"
$errOutput = $null
New-TaskConfig -TaskName "CaseB" | Invoke-RcloneSync -RclonePath $fakeRclonePath -LogFolderPath $logFolder -Confirm:$false -ErrorVariable errOutput -ErrorAction SilentlyContinue
$logFile = Get-LatestLogFile -TaskName "CaseB"
Assert -Description "Case B: non-zero exit code -> log file retained even though content matches 'nothing to transfer'" `
    -Condition ($null -ne $logFile) `
    -Detail "Expected log file to be retained, but it was not found."
Assert -Description "Case B: error message mentions the exit code" `
    -Condition ($errOutput.Count -gt 0 -and ($errOutput -join " ") -match "exit(ed)? .*5|code 5")

# --- Case C: exit 0 + normal success log -> log retained (does not match cleanup keyword) ---
$env:FAKE_RCLONE_EXIT_CODE = "0"
$env:FAKE_RCLONE_LOG_CONTENT = "success"
New-TaskConfig -TaskName "CaseC" | Invoke-RcloneSync -RclonePath $fakeRclonePath -LogFolderPath $logFolder -Confirm:$false -ErrorAction SilentlyContinue
$logFile = Get-LatestLogFile -TaskName "CaseC"
Assert -Description "Case C: exit 0, ordinary success log is retained" `
    -Condition ($null -ne $logFile)

# --- Case D: batch continues after a failing task (non-terminating) ---
$env:FAKE_RCLONE_EXIT_CODE = "3"
$env:FAKE_RCLONE_LOG_CONTENT = "success"
$configs = @(
    (New-TaskConfig -TaskName "CaseD-First"),
    (New-TaskConfig -TaskName "CaseD-Second")
)
# First task fails (exit 3). Switch to exit 0 for the second task by using a
# per-object override: simplest way here is to run them separately and check
# both ran (i.e. Invoke-RcloneSync did not throw a terminating error that
# would have stopped the pipeline before reaching the second item).
$batchError = $null
$didThrow = $false
try {
    $configs | Invoke-RcloneSync -RclonePath $fakeRclonePath -LogFolderPath $logFolder -Confirm:$false -ErrorVariable batchError -ErrorAction SilentlyContinue
}
catch {
    $didThrow = $true
}
$secondLog = Get-LatestLogFile -TaskName "CaseD-Second"
Assert -Description "Case D: a failing task does not throw a terminating error" `
    -Condition (-not $didThrow)
Assert -Description "Case D: pipeline continues to the next task after a failure (second task's log exists)" `
    -Condition ($null -ne $secondLog) `
    -Detail "Expected CaseD-Second to have run and produced a log file."

Remove-Item Env:\FAKE_RCLONE_EXIT_CODE -ErrorAction SilentlyContinue
Remove-Item Env:\FAKE_RCLONE_LOG_CONTENT -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Result: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failCount -gt 0) {
    exit 1
}