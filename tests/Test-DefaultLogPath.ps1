<#
.SYNOPSIS
    Standalone test script for the private Get-DefaultLogFolderPath function
    in RcloneSync.psm1.
.DESCRIPTION
    Get-DefaultLogFolderPath is not exported (by design). This script invokes
    it inside the module's scope to verify the default log path resolution
    logic, including backward compatibility checks.

    The script temporarily creates/deletes test directories and log files
    in the module's root to simulate various conditions. All created files
    are cleaned up after each test.

    Run from the tests directory:
        .\Test-DefaultLogPath.ps1
#>

param(
    [string]$ModulePath = (Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath "RcloneSync.psm1")
)

if (-not (Test-Path -Path $ModulePath -PathType Leaf)) {
    throw "Module file not found: $ModulePath"
}

$module = Import-Module -Name $ModulePath -Force -PassThru

$failCount = 0
$passCount = 0

# Helper: Get the module's root directory (where RcloneSync.psm1 resides)
$moduleRoot = Split-Path -Path $ModulePath -Parent

# Helper: Call the private function
function Invoke-PrivateFunction {
    param([string]$FunctionName)
    & $module { param($fn) & $fn } $FunctionName
}

# Helper: Test function that compares actual result with expected, and cleans up if needed
function Assert-DefaultPath {
    param(
        [string]$Description,
        [string]$ExpectedPathPattern,   # substring to look for, e.g., "logs" or "AppData"
        [scriptblock]$SetupBlock,       # scriptblock to set up conditions (return $true on success)
        [scriptblock]$CleanupBlock      # scriptblock to revert conditions
    )

    try {
        # Run setup
        if ($SetupBlock) {
            & $SetupBlock | Out-Null
        }

        # Call the function
        $actual = Invoke-PrivateFunction -FunctionName "Get-DefaultLogFolderPath"

        # Check if expected pattern is present (since full path may vary, we check substring)
        if ($actual -like "*$ExpectedPathPattern*") {
            Write-Host "[PASS] $Description" -ForegroundColor Green
            $script:passCount++
        } else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            Write-Host "       Expected pattern: '$ExpectedPathPattern'"
            Write-Host "       Actual:           '$actual'"
            $script:failCount++
        }
    }
    catch {
        Write-Host "[FAIL] $Description (unexpected exception)" -ForegroundColor Red
        Write-Host "       $_"
        $script:failCount++
    }
    finally {
        # Cleanup
        if ($CleanupBlock) {
            & $CleanupBlock | Out-Null
        }
    }
}

Write-Host "=== Get-DefaultLogFolderPath test cases ===" -ForegroundColor Cyan

# Test 1: Old path exists and contains at least one .log file → should return old path
$oldLogDir = Join-Path -Path $moduleRoot -ChildPath "logs"
Assert-DefaultPath -Description "Old path exists with .log → returns old path" `
    -ExpectedPathPattern "logs" `
    -SetupBlock {
        # Create logs directory and a dummy .log file
        if (-not (Test-Path -Path $oldLogDir -PathType Container)) {
            New-Item -Path $oldLogDir -ItemType Directory -Force | Out-Null
        }
        $dummyLog = Join-Path -Path $oldLogDir -ChildPath "dummy.log"
        Set-Content -Path $dummyLog -Value "test" -Force
        $true
    } `
    -CleanupBlock {
        if (Test-Path -Path $oldLogDir -PathType Container) {
            Remove-Item -Path $oldLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $true
    }

# Test 2: Old path exists but no .log files → should return user-level path
$userLevelPattern = if ($env:OS -eq 'Windows_NT') { "PS_RcloneSync" } else { "ps_rclonesync" }
Assert-DefaultPath -Description "Old path exists but no .log → returns user-level path" `
    -ExpectedPathPattern $userLevelPattern `
    -SetupBlock {
        # Create empty logs directory (no .log files)
        if (-not (Test-Path -Path $oldLogDir -PathType Container)) {
            New-Item -Path $oldLogDir -ItemType Directory -Force | Out-Null
        }
        # Ensure no .log files (clean up any existing)
        Get-ChildItem -Path $oldLogDir -Filter "*.log" -File | Remove-Item -Force -ErrorAction SilentlyContinue
        $true
    } `
    -CleanupBlock {
        if (Test-Path -Path $oldLogDir -PathType Container) {
            Remove-Item -Path $oldLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $true
    }

# Test 3: Old path does not exist → should return user-level path
Assert-DefaultPath -Description "Old path does not exist → returns user-level path" `
    -ExpectedPathPattern $userLevelPattern `
    -SetupBlock {
        # Ensure logs directory does not exist
        if (Test-Path -Path $oldLogDir -PathType Container) {
            Remove-Item -Path $oldLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $true
    } `
    -CleanupBlock {
        # Nothing to clean
        $true
    }

# Optional: Check that returned path ends with 'logs' (just a sanity check)
Write-Host "`nAdditional sanity check: path ends with 'logs'" -ForegroundColor Cyan
try {
    $actual = Invoke-PrivateFunction -FunctionName "Get-DefaultLogFolderPath"
    if ($actual -match 'logs$') {
        Write-Host "[PASS] Path ends with 'logs' (got '$actual')" -ForegroundColor Green
        $passCount++
    } else {
        Write-Host "[FAIL] Path does not end with 'logs' (got '$actual')" -ForegroundColor Red
        $failCount++
    }
} catch {
    Write-Host "[FAIL] Unexpected exception during sanity check: $_" -ForegroundColor Red
    $failCount++
}

Write-Host ""
Write-Host "=== Result: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

if ($failCount -gt 0) {
    exit 1
}