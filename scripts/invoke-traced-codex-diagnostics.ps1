[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$RunId = ('codex-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
  [string]$OutputRoot,
  [string[]]$Steps = @('Status', 'ComputerUseStrict'),
  [int]$DefaultTimeoutSeconds = 120,
  [int]$MsixDryRunTimeoutSeconds = 900,
  [int]$FullRepatchTimeoutSeconds = 1800,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $repoRoot 'artifacts\runs'
}
$validSteps = @('Status', 'Backup', 'ComputerUseStrict', 'ComputerUseRepairVerify', 'MsixDryRun', 'PatchDryRunKeepWork', 'FullRepatch', 'FullRepatchSkipFastVerify', 'TrustLatestPatchedMsixSignerLocalMachine', 'RemoveCodexAppxAllUsers', 'InstallLatestPatchedMsix')
$Steps = @(
  foreach ($step in $Steps) {
    foreach ($part in ([string]$step -split ',')) {
      $trimmed = $part.Trim()
      if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        $trimmed
      }
    }
  }
)
foreach ($step in $Steps) {
  if ($validSteps -notcontains $step) {
    throw "invalid step '$step'; expected one of: $($validSteps -join ', ')"
  }
}
$runRoot = Join-Path $OutputRoot $RunId
$eventsPath = Join-Path $runRoot 'events.jsonl'
$summaryPath = Join-Path $runRoot 'summary.json'

if (Test-Path -LiteralPath $runRoot) {
  if (-not $Force) {
    throw "trace run already exists: $runRoot; pass -Force to replace it or choose a new -RunId"
  }
  Remove-Item -LiteralPath $runRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content,
    [switch]$Append
  )

  $encoding = [System.Text.UTF8Encoding]::new($false)
  if ($Append -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
    [System.IO.File]::AppendAllText($Path, $Content, $encoding)
  } else {
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
  }
}

function Write-JsonLine {
  param([hashtable]$Event)

  $Event.timestamp = (Get-Date).ToUniversalTime().ToString('o')
  Write-Utf8NoBom -Path $eventsPath -Content (($Event | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine) -Append
}

function Quote-ProcessArgument {
  param([string]$Value)

  if ($null -eq $Value) {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
  return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-TracedCommand {
  param(
    [string]$Name,
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = $DefaultTimeoutSeconds
  )

  $stepRoot = Join-Path $runRoot $Name
  New-Item -ItemType Directory -Force -Path $stepRoot | Out-Null

  $stdoutPath = Join-Path $stepRoot 'stdout.txt'
  $stderrPath = Join-Path $stepRoot 'stderr.txt'
  $metaPath = Join-Path $stepRoot 'meta.json'
  $started = Get-Date

  Write-JsonLine @{
    event = 'step_started'
    name = $Name
    filePath = $FilePath
    arguments = $Arguments
    timeoutSeconds = $TimeoutSeconds
    stdout = $stdoutPath
    stderr = $stderrPath
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FilePath
  $psi.Arguments = ($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
  $psi.WorkingDirectory = $repoRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()

  $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
  if ($timedOut) {
    try {
      $process.Kill()
      $process.WaitForExit()
    } catch {
      Write-JsonLine @{
        event = 'step_stop_failed'
        name = $Name
        error = $_.Exception.Message
      }
    }
  }
  $stdoutTask.Wait()
  $stderrTask.Wait()
  Write-Utf8NoBom -Path $stdoutPath -Content $stdoutTask.Result
  Write-Utf8NoBom -Path $stderrPath -Content $stderrTask.Result

  $ended = Get-Date
  $exitCode = if ($timedOut) { $null } else { $process.ExitCode }
  $meta = [ordered]@{
    name = $Name
    filePath = $FilePath
    arguments = $Arguments
    started = $started.ToUniversalTime().ToString('o')
    ended = $ended.ToUniversalTime().ToString('o')
    durationSeconds = [math]::Round(($ended - $started).TotalSeconds, 3)
    timeoutSeconds = $TimeoutSeconds
    timedOut = $timedOut
    exitCode = $exitCode
    stdout = $stdoutPath
    stderr = $stderrPath
  }
  Write-Utf8NoBom -Path $metaPath -Content ($meta | ConvertTo-Json -Depth 8)

  Write-JsonLine @{
    event = 'step_finished'
    name = $Name
    timedOut = $timedOut
    exitCode = $exitCode
    durationSeconds = $meta.durationSeconds
    meta = $metaPath
  }

  return [pscustomobject]$meta
}

$results = @()
Write-JsonLine @{
  event = 'run_started'
  runId = $RunId
  repoRoot = $repoRoot
  steps = $Steps
}

foreach ($step in $Steps) {
  switch ($step) {
    'Status' {
      $script = @'
$pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
  $pkg | Select-Object Name,PackageFullName,Version,SignatureKind,InstallLocation | Format-List
} else {
  'OpenAI.Codex package not found'
}
'@
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-Command', $script)
    }
    'ComputerUseStrict' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'install-computer-use-local.ps1'),
        '-StrictVerifyOnly'
      )
    }
    'ComputerUseRepairVerify' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'install-computer-use-local.ps1'),
        '-VerifyOnly'
      )
    }
    'MsixDryRun' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $MsixDryRunTimeoutSeconds -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'repatch-codex-windows.ps1'),
        '-DryRun',
        '-SkipFastVerify'
      )
    }
    'PatchDryRunKeepWork' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $MsixDryRunTimeoutSeconds -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'),
        '-DryRun',
        '-ForceRebuild',
        '-KeepWorkDir'
      )
    }
    'FullRepatch' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $FullRepatchTimeoutSeconds -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'repatch-codex-windows.ps1')
      )
    }
    'FullRepatchSkipFastVerify' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $FullRepatchTimeoutSeconds -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'repatch-codex-windows.ps1'),
        '-SkipFastVerify',
        '-SkipComputerUse',
        '-SkipMarketplace'
      )
    }
    'InstallLatestPatchedMsix' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds 600 -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'install-latest-patched-codex-msix.ps1')
      )
    }
    'TrustLatestPatchedMsixSignerLocalMachine' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds 300 -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'trust-latest-patched-msix-signer-localmachine.ps1'),
        '-TrustRootForAppxInstallRecovery'
      )
    }
    'RemoveCodexAppxAllUsers' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds 300 -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'remove-codex-appx-allusers.ps1')
      )
    }
  }
}

$summary = [ordered]@{
  runId = $RunId
  runRoot = $runRoot
  events = $eventsPath
  results = $results
}
Write-Utf8NoBom -Path $summaryPath -Content ($summary | ConvertTo-Json -Depth 8)
Write-JsonLine @{ event = 'run_finished'; summary = $summaryPath }

Write-Host "trace run: $runRoot"
Write-Host "summary: $summaryPath"

$failed = @($results | Where-Object { $_.timedOut -or ($null -ne $_.exitCode -and $_.exitCode -ne 0) })
if ($failed.Count -gt 0) {
  exit 1
}
