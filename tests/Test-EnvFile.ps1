<#
.SYNOPSIS
    Unit tests for the exported Invoke-EnvFile function in RcloneSync.psm1.
.DESCRIPTION
    Invoke-EnvFile reads a general-purpose .env file and injects KEY=VALUE
    pairs into the current process environment, returning the list of keys
    that were set. It is an exported (public) cmdlet, so unlike the private
    ConvertTo-ArgTokens it can be invoked directly - no module-scope trick
    is needed.

    Each test writes a temporary .env file with controlled content, invokes
    Invoke-EnvFile against it, and asserts on the returned key list and the
    resulting $env: values. The environment is cleaned up after each test so
    tests do not leak variables into one another or the host session.

    Run from the directory containing RcloneSync.psm1:
        .\Test-EnvFile.ps1
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

$workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("RcloneSyncEnvTest-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -Path $workDir -ItemType Directory -Force | Out-Null

# All test keys use a distinctive RTEST_ prefix to avoid colliding with any
# real variable in the host session, and to make cleanup safe & unambiguous.
$trackedKeys = [System.Collections.Generic.List[string]]::new()

function Remove-TrackedEnvVars {
    foreach ($k in $trackedKeys) {
        Remove-Item "Env:\$k" -ErrorAction SilentlyContinue
    }
    $trackedKeys.Clear()
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

function Invoke-EnvFileForTest {
    param([string]$Path, [switch]$WhatIf)
    if ($WhatIf) {
        $result = Invoke-EnvFile -Path $Path -WhatIf
    }
    else {
        $result = Invoke-EnvFile -Path $Path
    }
    # Invoke-EnvFile returns the protected array via `, $array`; a plain
    # assignment preserves it, so @() here collects the single array object
    # into a 1-element outer array. Unwrap one level to get the real list.
    return @($result)
}

function New-EnvFile {
    param([string]$Name, [string]$Content)
    $path = Join-Path -Path $workDir -ChildPath $Name
    Set-Content -Path $path -Value $Content -Encoding utf8
    return $path
}

Write-Host "=== Invoke-EnvFile unit tests ===" -ForegroundColor Cyan

# --- 1. Basic KEY=VALUE -----------------------------------------------------
$envFile = New-EnvFile -Name "basic.env" -Content "RTEST_KEY1=value1"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Basic KEY=VALUE: returns the key" -Condition ($keys -eq @("RTEST_KEY1"))
Assert -Description "Basic KEY=VALUE: env var set to value" -Condition ($env:RTEST_KEY1 -eq "value1")
$trackedKeys.Add("RTEST_KEY1"); Remove-TrackedEnvVars

# --- 2. Multiple keys -------------------------------------------------------
$envFile = New-EnvFile -Name "multi.env" -Content "RTEST_M1=a`nRTEST_M2=b"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Multiple keys: returns both keys" -Condition (($keys -contains "RTEST_M1") -and ($keys -contains "RTEST_M2"))
Assert -Description "Multiple keys: both env vars set" -Condition (($env:RTEST_M1 -eq "a") -and ($env:RTEST_M2 -eq "b"))
$trackedKeys.Add("RTEST_M1"); $trackedKeys.Add("RTEST_M2"); Remove-TrackedEnvVars

# --- 3. Comments and blank lines skipped -----------------------------------
$envFile = New-EnvFile -Name "comments.env" -Content "# a comment`n`n   `nRTEST_C1=val"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Comments/blanks: comment lines not returned" -Condition ($keys -eq @("RTEST_C1"))
Assert -Description "Comments/blanks: only the real key is set" -Condition ($env:RTEST_C1 -eq "val")
$trackedKeys.Add("RTEST_C1"); Remove-TrackedEnvVars

# --- 4. Empty value ---------------------------------------------------------
$envFile = New-EnvFile -Name "emptyval.env" -Content "RTEST_E1="
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Empty value: key returned" -Condition ($keys -eq @("RTEST_E1"))
Assert -Description "Empty value: env var set to empty string" -Condition ($env:RTEST_E1 -eq "")
$trackedKeys.Add("RTEST_E1"); Remove-TrackedEnvVars

# --- 5. Whitespace trimmed --------------------------------------------------
$envFile = New-EnvFile -Name "trim.env" -Content "  RTEST_T1  =   padded value  "
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Whitespace: key and value trimmed" -Condition (($keys -eq @("RTEST_T1")) -and ($env:RTEST_T1 -eq "padded value"))
$trackedKeys.Add("RTEST_T1"); Remove-TrackedEnvVars

# --- 6. export prefix -------------------------------------------------------
$envFile = New-EnvFile -Name "export.env" -Content "export RTEST_X1=exported"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "export prefix: stripped and parsed" -Condition (($keys -eq @("RTEST_X1")) -and ($env:RTEST_X1 -eq "exported"))
$trackedKeys.Add("RTEST_X1"); Remove-TrackedEnvVars

# --- 7. Duplicate key, last wins --------------------------------------------
$envFile = New-EnvFile -Name "dupe.env" -Content "RTEST_D1=first`nRTEST_D1=second"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Duplicate key: returned once" -Condition ($keys -eq @("RTEST_D1"))
Assert -Description "Duplicate key: last occurrence wins" -Condition ($env:RTEST_D1 -eq "second")
$trackedKeys.Add("RTEST_D1"); Remove-TrackedEnvVars

# --- 8. Missing file -> empty array, no error -------------------------------
$missingPath = Join-Path -Path $workDir -ChildPath "does-not-exist.env"
$keys = Invoke-EnvFileForTest -Path $missingPath
Assert -Description "Missing file: returns empty array" -Condition ($keys.Count -eq 0)

# --- 9. Empty file -> empty array -------------------------------------------
$envFile = New-EnvFile -Name "empty.env" -Content ""
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Empty file: returns empty array" -Condition ($keys.Count -eq 0)

# --- 10. Malformed line (no '=') skipped, no error --------------------------
$envFile = New-EnvFile -Name "malformed.env" -Content "just-a-key-without-equals`nRTEST_Z1=ok"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Malformed line: skipped, valid key still returned" -Condition ($keys -eq @("RTEST_Z1"))
Assert -Description "Malformed line: valid key still set" -Condition ($env:RTEST_Z1 -eq "ok")
$trackedKeys.Add("RTEST_Z1"); Remove-TrackedEnvVars

# --- 11. WhatIf suppresses side effects -------------------------------------
$envFile = New-EnvFile -Name "whatif.env" -Content "RTEST_W1=should-not-set"
$keys = Invoke-EnvFileForTest -Path $envFile -WhatIf
Assert -Description "WhatIf: env var NOT actually set" -Condition ($null -eq $env:RTEST_W1)
$trackedKeys.Add("RTEST_W1"); Remove-TrackedEnvVars

# --- 12. UTF-8 with non-ASCII characters ------------------------------------
$expectedVal = ([char]0x00E9) + ([char]0x5C) + ([char]0x4E2D) + ([char]0x6587)   # é\中文
$utf8Content = "RTEST_U1=" + $expectedVal
$envFile = New-EnvFile -Name "utf8.env" -Content $utf8Content
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "UTF-8: non-ASCII value parses correctly" -Condition ($env:RTEST_U1 -eq $expectedVal)
$trackedKeys.Add("RTEST_U1"); Remove-TrackedEnvVars

# --- 13. Cleanup restores environment ---------------------------------------
$envFile = New-EnvFile -Name "cleanup.env" -Content "RTEST_CL1=temp"
$null = Invoke-EnvFileForTest -Path $envFile
$setBeforeCleanup = ($null -ne $env:RTEST_CL1)
Remove-Item "Env:\RTEST_CL1" -ErrorAction SilentlyContinue
$goneAfterCleanup = ($null -eq $env:RTEST_CL1)
Assert -Description "Cleanup: variable was set, then removable" -Condition ($setBeforeCleanup -and $goneAfterCleanup)

# --- 14. Value may contain '=' ----------------------------------------------
$envFile = New-EnvFile -Name "equals.env" -Content "RTEST_EQ1=a=b=c"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Value contains '=': split on first '=' only" -Condition ($env:RTEST_EQ1 -eq "a=b=c")
$trackedKeys.Add("RTEST_EQ1"); Remove-TrackedEnvVars

# --- 15. Overwrite existing session variable --------------------------------
Set-Item "Env:\RTEST_OV1" -Value "original"
$envFile = New-EnvFile -Name "overwrite.env" -Content "RTEST_OV1=newvalue"
$keys = Invoke-EnvFileForTest -Path $envFile
Assert -Description "Overwrite: .env value overrides existing session variable" -Condition ($env:RTEST_OV1 -eq "newvalue")
$trackedKeys.Add("RTEST_OV1"); Remove-TrackedEnvVars

Write-Host ""
Write-Host "=== Result: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

Remove-TrackedEnvVars
Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failCount -gt 0) {
    exit 1
}