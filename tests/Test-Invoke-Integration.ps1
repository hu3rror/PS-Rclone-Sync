<#
.SYNOPSIS
    Integration test for Step 2: verifies that Invoke-RcloneSync now builds
    the rclone argument list using the quote-aware ConvertTo-ArgTokens
    tokenizer instead of the old `-split '\s+'` logic.
.DESCRIPTION
    Uses a fake "rclone" (a plain PowerShell script) in place of the real
    rclone executable. The fake script just dumps the arguments it received
    to a file, so we can assert on the exact argument list that
    Invoke-RcloneSync constructed - no real rclone installation required.

    Run from the directory containing RcloneSync.psm1:
        .\Test-Invoke-Integration.ps1
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

$workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("RcloneSyncTest-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

$localFolder = Join-Path -Path $workDir -ChildPath "local"
$logFolder   = Join-Path -Path $workDir -ChildPath "logs"
New-Item -Path $localFolder -ItemType Directory -Force | Out-Null

# Fake rclone: writes every argument it receives (one per line) to a
# capture file next to it, then exits 0.
$fakeRclonePath = Join-Path -Path $workDir -ChildPath "fake-rclone.ps1"
$captureFile    = Join-Path -Path $workDir -ChildPath "captured-args.txt"

@'
param()
$args | Out-File -FilePath "__CAPTURE_FILE__" -Encoding utf8
exit 0
'@.Replace("__CAPTURE_FILE__", $captureFile) | Set-Content -Path $fakeRclonePath -Encoding utf8

function Invoke-CaptureTest {
    param(
        [string]$Description,
        [string]$RcloneFlags,
        [string[]]$ExpectedTrailingArgs
    )

    if (Test-Path -Path $captureFile) {
        Remove-Item -Path $captureFile -Force
    }

    $taskConfig = [PSCustomObject]@{
        taskName        = "IntegrationTest"
        localFolder     = $localFolder
        destName        = "FakeRemote"
        destFolder      = "/Backups/Test"
        exclude         = @()
        rcloneFlags     = $RcloneFlags
        showCommand     = $false
        maximumLogFiles = 5
        enabled         = $true
    }

    try {
        $taskConfig | Invoke-RcloneSync -RclonePath $fakeRclonePath -LogFolderPath $logFolder -Confirm:$false

        if (-not (Test-Path -Path $captureFile)) {
            Write-Host "[FAIL] $Description (fake rclone was not invoked - capture file missing)" -ForegroundColor Red
            $script:failCount++
            return
        }

        $capturedArgs = @(Get-Content -Path $captureFile)

        # The first 3 args are always: sync, <localFolder>, <destName>:<destFolder>
        # followed by --use-json-log and --log-file=..., then the parsed
        # rcloneFlags tokens. We only assert on the trailing tokens that
        # came from rcloneFlags parsing, which is what Step 2 changed.
        $trailing = @($capturedArgs | Select-Object -Skip 5)

        $isEqual = $trailing.Count -eq $ExpectedTrailingArgs.Count
        if ($isEqual) {
            for ($i = 0; $i -lt $trailing.Count; $i++) {
                if ($trailing[$i] -cne $ExpectedTrailingArgs[$i]) { $isEqual = $false; break }
            }
        }

        if ($isEqual) {
            Write-Host "[PASS] $Description" -ForegroundColor Green
            $script:passCount++
        }
        else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            Write-Host "       Full captured args: [$($capturedArgs -join ' | ')]"
            Write-Host "       Expected trailing:   [$($ExpectedTrailingArgs -join ' | ')]"
            Write-Host "       Actual trailing:     [$($trailing -join ' | ')]"
            $script:failCount++
        }
    }
    catch {
        Write-Host "[FAIL] $Description (unexpected exception)" -ForegroundColor Red
        Write-Host "       $_"
        $script:failCount++
    }
}

Write-Host "=== Invoke-RcloneSync / ConvertTo-ArgTokens integration tests ===" -ForegroundColor Cyan

# 1. No-quote flags: must match the same tokens as the old -split '\s+' behavior.
#    This is the backward-compatibility check for existing config.json.example entries.
Invoke-CaptureTest -Description "No-quote flags behave the same as before" `
    -RcloneFlags "--dry-run --progress --fast-list --transfers=8 --max-backlog=-1 --log-level=NOTICE" `
    -ExpectedTrailingArgs @('--dry-run', '--progress', '--fast-list', '--transfers=8', '--max-backlog=-1', '--log-level=NOTICE')

# 2. Quoted value containing a space is preserved as ONE argument.
Invoke-CaptureTest -Description "Quoted value with space stays as a single arg" `
    -RcloneFlags '--dry-run --exclude "my folder/*.tmp" --fast-list' `
    -ExpectedTrailingArgs @('--dry-run', '--exclude', 'my folder/*.tmp', '--fast-list')

# 3. --use-json-log supplied by the user is still filtered out (existing de-dup behavior preserved).
Invoke-CaptureTest -Description "User-supplied --use-json-log is still filtered" `
    -RcloneFlags '--dry-run --use-json-log --progress' `
    -ExpectedTrailingArgs @('--dry-run', '--progress')

# 4. Equals-form with quoted value.
Invoke-CaptureTest -Description "Equals-form with quoted value" `
    -RcloneFlags '--exclude="a b c" --dry-run' `
    -ExpectedTrailingArgs @('--exclude=a b c', '--dry-run')

Write-Host ""
Write-Host "=== Result: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failCount -gt 0) {
    exit 1
}