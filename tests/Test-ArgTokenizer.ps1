<#
.SYNOPSIS
    Standalone test script for the private ConvertTo-ArgTokens function in
    RcloneSync.psm1.
.DESCRIPTION
    ConvertTo-ArgTokens is not exported via Export-ModuleMember (by design -
    it is an internal implementation detail). This script invokes it by
    running a script block inside the module's own scope, so no change to
    the module's public contract is needed.

    Run from the directory containing RcloneSync.psm1:
        .\Test-ArgTokenizer.ps1
#>

param(
    [string]$ModulePath = (Join-Path -Path $PSScriptRoot -ChildPath "RcloneSync.psm1")
)

if (-not (Test-Path -Path $ModulePath -PathType Leaf)) {
    throw "Module file not found: $ModulePath"
}

$module = Import-Module -Name $ModulePath -Force -PassThru

$failCount = 0
$passCount = 0

function Assert-TokensEqual {
    param(
        [string]$Description,
        [string]$InputString,
        [string[]]$Expected
    )

    try {
        $actual = & $module { param($s) ConvertTo-ArgTokens -InputString $s } $InputString

        $actualArr = @($actual)
        $expectedArr = @($Expected)

        $isEqual = $actualArr.Count -eq $expectedArr.Count
        if ($isEqual) {
            for ($i = 0; $i -lt $actualArr.Count; $i++) {
                if ($actualArr[$i] -cne $expectedArr[$i]) { $isEqual = $false; break }
            }
        }

        if ($isEqual) {
            Write-Host "[PASS] $Description" -ForegroundColor Green
            $script:passCount++
        }
        else {
            Write-Host "[FAIL] $Description" -ForegroundColor Red
            Write-Host "       Input:    '$InputString'"
            Write-Host "       Expected: [$($expectedArr -join ' | ')]"
            Write-Host "       Actual:   [$($actualArr -join ' | ')]"
            $script:failCount++
        }
    }
    catch {
        Write-Host "[FAIL] $Description (unexpected exception)" -ForegroundColor Red
        Write-Host "       $_"
        $script:failCount++
    }
}

function Assert-Throws {
    param(
        [string]$Description,
        [string]$InputString
    )

    $threw = $false
    try {
        & $module { param($s) ConvertTo-ArgTokens -InputString $s } $InputString | Out-Null
    }
    catch {
        $threw = $true
    }

    if ($threw) {
        Write-Host "[PASS] $Description" -ForegroundColor Green
        $script:passCount++
    }
    else {
        Write-Host "[FAIL] $Description (expected an exception, none was thrown)" -ForegroundColor Red
        $script:failCount++
    }
}

Write-Host "=== ConvertTo-ArgTokens test cases ===" -ForegroundColor Cyan

# 1. No quotes - must match the old -split '\s+' behavior.
Assert-TokensEqual -Description "No quotes - equivalent to old -split behavior" `
    -InputString '--dry-run --progress --transfers=8' `
    -Expected @('--dry-run', '--progress', '--transfers=8')

# 2. Double quotes wrapping a value with a space.
Assert-TokensEqual -Description "Double-quoted value with space" `
    -InputString '--exclude "file with space" --fast-list' `
    -Expected @('--exclude', 'file with space', '--fast-list')

# 3. Equals-form + single quotes.
Assert-TokensEqual -Description "Equals-form with single quotes" `
    -InputString "--include='a b c' --progress" `
    -Expected @('--include=a b c', '--progress')

# 4. Unmatched quote must throw.
Assert-Throws -Description "Unmatched quote should throw" `
    -InputString '--exclude "unclosed'

# 5. Empty string returns an empty array.
Assert-TokensEqual -Description "Empty string returns empty array" `
    -InputString '' `
    -Expected @()

# Extra edge cases (not strictly required by spec, added for robustness).
Assert-TokensEqual -Description "Whitespace-only string returns empty array" `
    -InputString '   ' `
    -Expected @()

Assert-TokensEqual -Description "Multiple consecutive spaces treated as one separator" `
    -InputString '--a    --b' `
    -Expected @('--a', '--b')

Assert-TokensEqual -Description "Quoted empty value still produces one empty token" `
    -InputString '--exclude "" --fast-list' `
    -Expected @('--exclude', '', '--fast-list')

Write-Host ""
Write-Host "=== Result: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

if ($failCount -gt 0) {
    exit 1
}