<#
.SYNOPSIS
    Step 4 regression test: runs the exact, unmodified rcloneFlags strings
    from config.json.example through the full Invoke-RcloneSync pipeline
    (Step 2 + Step 3 changes combined) and verifies zero behavioral
    regression versus the original -split '\s+' tokenizer.
.DESCRIPTION
    config.json.example ships with Windows-style localFolder paths
    (C:\Users\username\...) that will not exist on a fresh test machine,
    and Validate() requires localFolder to exist. To keep this a true
    regression test of what actually changed (flag tokenization + exit
    code handling), every field is copied verbatim from
    config.json.example EXCEPT localFolder, which is repointed at a real
    temp directory created by this script. rcloneFlags, destName,
    destFolder, exclude, showCommand, maximumLogFiles, and enabled are
    byte-for-byte identical to config.json.example.

    Run from the directory containing RcloneSync.psm1 and
    config.json.example:
        .\Test-Regression-ConfigExample.ps1
#>

param(
    [string]$ModulePath = (Join-Path -Path $PSScriptRoot -ChildPath "RcloneSync.psm1"),
    [string]$ExampleConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "config.json.example")
)

if (-not (Test-Path -Path $ModulePath -PathType Leaf)) {
    throw "Module file not found: $ModulePath"
}
if (-not (Test-Path -Path $ExampleConfigPath -PathType Leaf)) {
    throw "config.json.example not found: $ExampleConfigPath (pass -ExampleConfigPath explicitly if it lives elsewhere)"
}

Import-Module -Name $ModulePath -Force

$failCount = 0
$passCount = 0

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

# --- Load the real, unmodified example config ------------------------------

$rawJson = Get-Content -Path $ExampleConfigPath -Raw
$originalTasks = $rawJson | ConvertFrom-Json

Write-Host "=== Loaded $($originalTasks.Count) task(s) from config.json.example ===" -ForegroundColor Cyan

# --- Test harness setup -----------------------------------------------------

$workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("RcloneSyncRegressionTest-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
$logFolder = Join-Path -Path $workDir -ChildPath "logs"
New-Item -Path $logFolder -ItemType Directory -Force | Out-Null

$fakeRclonePath = Join-Path -Path $workDir -ChildPath "fake-rclone.ps1"
@'
param()
$logFileArg = $args | Where-Object { $_ -like "--log-file=*" }
if ($logFileArg) {
    $logFilePath = $logFileArg.Substring(11)
    Set-Content -Path $logFilePath -Value "{`"level`":`"info`",`"msg`":`"Transferred: 0 files`"}" -Encoding utf8
}
exit 0
'@ | Set-Content -Path $fakeRclonePath -Encoding utf8

# --- Part 1: tokenizer equivalence check on the ORIGINAL rcloneFlags strings ---
# This isolates exactly what Step 2 changed: for flag strings with no quotes
# (which is what config.json.example uses today), ConvertTo-ArgTokens must
# produce identical output to the old `-split '\s+' | Where-Object {...}`.

Write-Host ""
Write-Host "=== Part 1: tokenizer equivalence on original rcloneFlags strings ===" -ForegroundColor Cyan

foreach ($task in $originalTasks) {
    $oldStyleTokens = @($task.rcloneFlags -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # Invoke the private tokenizer the same way Test-ArgTokenizer.ps1 does,
    # via a script block executed inside the module's own scope.
    #
    # IMPORTANT: capture the result with a plain assignment first, THEN wrap
    # with @(). ConvertTo-ArgTokens returns `, $tokens.ToArray()` internally
    # to stop PowerShell from unrolling a single array result into scalars.
    # That protection only survives a bare `$x = ...` assignment. Wrapping
    # the pipeline call itself in @(...) forces PowerShell to collect
    # pipeline OUTPUT COUNT instead: since exactly one object crossed the
    # pipe (the already-protected array), @() treats that one object as a
    # single array ELEMENT and nests it - producing a 1-item array whose
    # only element is the real token array, instead of the token array
    # itself. Do not "simplify" this back to @(& $moduleRef { ... } ...).
    $moduleRef = Get-Module -Name (Split-Path -Path $ModulePath -Leaf) -ErrorAction SilentlyContinue
    if (-not $moduleRef) {
        $moduleRef = Import-Module -Name $ModulePath -Force -PassThru
    }
    $rawResult = & $moduleRef { param($s) ConvertTo-ArgTokens -InputString $s } $task.rcloneFlags
    $newTokens = @($rawResult)

    $isEqual = $oldStyleTokens.Count -eq $newTokens.Count
    if ($isEqual) {
        for ($i = 0; $i -lt $oldStyleTokens.Count; $i++) {
            if ($oldStyleTokens[$i] -cne $newTokens[$i]) { $isEqual = $false; break }
        }
    }

    Assert -Description "Task '$($task.taskName)': ConvertTo-ArgTokens matches old -split behavior" `
        -Condition $isEqual `
        -Detail "Old: [$($oldStyleTokens -join ' | ')]  New: [$($newTokens -join ' | ')]"
}

# --- Part 2: full end-to-end pipeline run, all fields unchanged except localFolder ---

Write-Host ""
Write-Host "=== Part 2: end-to-end Invoke-RcloneSync run against example config ===" -ForegroundColor Cyan

$adaptedConfigs = @()
foreach ($task in $originalTasks) {
    $tempLocalFolder = Join-Path -Path $workDir -ChildPath ("local-" + $task.taskName)
    New-Item -Path $tempLocalFolder -ItemType Directory -Force | Out-Null

    $adaptedConfigs += [PSCustomObject]@{
        taskName        = $task.taskName
        localFolder     = $tempLocalFolder          # only field intentionally changed
        destName        = $task.destName
        destFolder      = $task.destFolder
        exclude         = $task.exclude
        rcloneFlags     = $task.rcloneFlags          # byte-for-byte identical to config.json.example
        showCommand     = $task.showCommand
        maximumLogFiles = $task.maximumLogFiles
        enabled         = $task.enabled
    }
}

$pipelineThrew = $false
$pipelineErrors = $null
try {
    $adaptedConfigs | Invoke-RcloneSync -RclonePath $fakeRclonePath -LogFolderPath $logFolder -Confirm:$false -ErrorVariable pipelineErrors -ErrorAction SilentlyContinue
}
catch {
    $pipelineThrew = $true
    Write-Host "       Unexpected terminating error: $_" -ForegroundColor Red
}

Assert -Description "Full pipeline run over all example tasks completes without a terminating error" `
    -Condition (-not $pipelineThrew)

Assert -Description "No per-task errors were raised (all example tasks used exit code 0)" `
    -Condition ($pipelineErrors.Count -eq 0) `
    -Detail "Errors: $($pipelineErrors -join ' | ')"

foreach ($task in $originalTasks) {
    $logFile = Get-ChildItem -Path $logFolder -Filter "$($task.taskName).*.log" -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    Assert -Description "Task '$($task.taskName)': fake rclone was invoked and produced a log file" `
        -Condition ($null -ne $logFile)
}

Write-Host ""
Write-Host "=== Result: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failCount -gt 0) {
    exit 1
}