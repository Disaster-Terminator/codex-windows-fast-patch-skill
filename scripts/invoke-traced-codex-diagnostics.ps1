[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$RunId = ('codex-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
  [string]$OutputRoot,
  [string[]]$Steps = @('Status', 'ComputerUseStrict'),
  [int]$DefaultTimeoutSeconds = 120,
  [int]$MsixDryRunTimeoutSeconds = 900,
  [int]$FullRepatchTimeoutSeconds = 1800,
  [int]$RemoteControlTimeoutSeconds = 1800,
  [string]$RemoteControlOutputRoot,
  [string]$RemoteControlNativeWorkRoot,
  [string]$ReplacementResourceCodexExe,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $repoRoot 'artifacts\runs'
}
if ([string]::IsNullOrWhiteSpace($RemoteControlOutputRoot)) {
  $RemoteControlOutputRoot = Join-Path $repoRoot 'artifacts\remote-control'
}
$validSteps = @('Status', 'RemoteControlStatus', 'RemoteControlAuthVerify', 'RemoteControlDryRun', 'RemoteControlNativeBuild', 'RemoteControlPatch', 'Backup', 'ComputerUseStrict', 'ComputerUseRepairVerify', 'MsixDryRun', 'ModelExperienceDryRun', 'ModelExperiencePatch', 'PatchDryRunKeepWork', 'FullRepatch', 'FullRepatchSkipFastVerify', 'TrustLatestPatchedMsixSignerLocalMachine', 'RemoveCodexAppxAllUsers', 'InstallLatestPatchedMsix')
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
if ($Steps -contains 'RemoteControlNativeBuild' -and [string]::IsNullOrWhiteSpace($RemoteControlNativeWorkRoot)) {
  throw 'RemoteControlNativeBuild requires -RemoteControlNativeWorkRoot'
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
    'RemoteControlStatus' {
      $script = @'
$ErrorActionPreference = 'Stop'

function Get-FileSummary {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [ordered]@{ exists = $false }
  }
  $item = Get-Item -LiteralPath $Path
  return [ordered]@{
    exists = $true
    length = $item.Length
    lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
  }
}

function Get-MarkerStatus {
  param(
    [string]$Path,
    [string[]]$Markers
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [ordered]@{ exists = $false; present = @(); missing = $Markers }
  }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
  $present = @($Markers | Where-Object { $text.Contains($_) })
  $missing = @($Markers | Where-Object { -not $text.Contains($_) })
  return [ordered]@{ exists = $true; present = $present; missing = $missing }
}

$probeRoot = Join-Path $env:TEMP 'codex-remote-control-status'
$pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
  Sort-Object Version -Descending |
  Select-Object -First 1
$nativePath = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'
$asarPath = Join-Path $pkg.InstallLocation 'app\resources\app.asar'
$probePath = Join-Path $probeRoot 'installed-resource-codex-version-probe.exe'
New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
Copy-Item -LiteralPath $nativePath -Destination $probePath -Force
try {
  $nativeVersion = (& $probePath --version 2>&1 | Out-String).Trim()
} finally {
  Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
}

$nativeMarkers = @(
  'remote_control_app_server_isolated_oauth_used',
  'remote_control_native_remote_json_first',
  'remote_control_websocket_proxy_attempt',
  'remote_control_websocket_proxy_connected',
  'remote-control-oauth.json',
  'remote.json',
  'codex.remote_control.enroll'
)
$asarMarkers = @(
  'remote_control_desktop_fetch_override_used',
  'remote_control_auth_token_expired_skipped',
  'remote_control_appserver_bh_isolated_auth_fallback',
  'remote_control_connection_auth_fallback_used',
  'remote_control_mobile_setup_no_auth_redirect',
  'remote_control_mobile_setup_authorize_before_enable',
  'remote_control_mfa_info_403_nonblocking',
  'remote_control_client_list_partial_failure_nonblocking',
  'remote_control_settings_force_control_this_pc_visible',
  'remote_control_settings_force_remote_control_section_visible'
)
$codexHome = Join-Path $env:USERPROFILE '.codex'
$authPath = Join-Path $codexHome 'auth.json'
$authSummary = [ordered]@{ exists = $false; hasApiKey = $false; hasOAuthTokens = $false; parseError = $null }
if (Test-Path -LiteralPath $authPath -PathType Leaf) {
  $authSummary.exists = $true
  try {
    $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
    $propertyNames = @($auth.PSObject.Properties.Name)
    $authSummary.hasApiKey = [bool](@($propertyNames | Where-Object { $_ -match '(?i)api.?key' }).Count)
    $authSummary.hasOAuthTokens = [bool](@($propertyNames | Where-Object { $_ -match '(?i)token|oauth' }).Count)
  } catch {
    $authSummary.parseError = $_.Exception.Message
  }
}
$configPath = Join-Path $codexHome 'config.toml'
$modelProvider = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
  $configText = Get-Content -Raw -LiteralPath $configPath
  $providerMatch = [regex]::Match($configText, '(?m)^\s*model_provider\s*=\s*["'']([^"'']+)["'']')
  if ($providerMatch.Success) {
    $modelProvider = $providerMatch.Groups[1].Value
  }
}

[pscustomobject]@{
  package = [ordered]@{
    fullName = $pkg.PackageFullName
    version = [string]$pkg.Version
    signatureKind = [string]$pkg.SignatureKind
    installLocation = $pkg.InstallLocation
  }
  nativeVersion = $nativeVersion
  nativeMarkers = Get-MarkerStatus -Path $nativePath -Markers $nativeMarkers
  asarMarkers = Get-MarkerStatus -Path $asarPath -Markers $asarMarkers
  auth = $authSummary
  modelProvider = $modelProvider
  remoteJson = Get-FileSummary -Path (Join-Path $codexHome 'remote.json')
  remoteControlOauth = Get-FileSummary -Path (Join-Path $codexHome 'remote-control-oauth.json')
  remoteControlFlowLog = Get-FileSummary -Path (Join-Path $codexHome 'remote-control-flow.log')
} | ConvertTo-Json -Depth 8
'@
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-Command', $script)
    }
    'RemoteControlAuthVerify' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'uv.exe' -TimeoutSeconds $DefaultTimeoutSeconds -Arguments @(
        'run',
        '--no-project',
        'python',
        (Join-Path $PSScriptRoot 'refresh-remote-control-auth.py'),
        '--verify-only'
      )
    }
    'RemoteControlDryRun' {
      $remoteArgs = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'patch-remote-control-windows-msix.ps1'),
        '-DryRun',
        '-ForceRebuild',
        '-OutputRoot',
        $RemoteControlOutputRoot
      )
      if (-not [string]::IsNullOrWhiteSpace($ReplacementResourceCodexExe)) {
        $remoteArgs += @('-ReplacementResourceCodexExe', $ReplacementResourceCodexExe)
      }
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $RemoteControlTimeoutSeconds -Arguments $remoteArgs
    }
    'RemoteControlNativeBuild' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $RemoteControlTimeoutSeconds -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'build-remote-control-native-replacement.ps1'),
        '-WorkRoot',
        $RemoteControlNativeWorkRoot
      )
    }
    'RemoteControlPatch' {
      $remoteArgs = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'patch-remote-control-windows-msix.ps1'),
        '-Install',
        '-Launch',
        '-InstallPrerequisites',
        '-ForceRebuild',
        '-OutputRoot',
        $RemoteControlOutputRoot
      )
      if (-not [string]::IsNullOrWhiteSpace($ReplacementResourceCodexExe)) {
        $remoteArgs += @('-ReplacementResourceCodexExe', $ReplacementResourceCodexExe)
      }
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $RemoteControlTimeoutSeconds -Arguments $remoteArgs
    }
    'Backup' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'manage-codex-backups.ps1'),
        '-Action',
        'Backup'
      )
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
    'ModelExperienceDryRun' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $MsixDryRunTimeoutSeconds -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'),
        '-OnlyModelExperience',
        '-DryRun',
        '-ForceRebuild'
      )
    }
    'ModelExperiencePatch' {
      $results += Invoke-TracedCommand -Name $step -FilePath 'powershell.exe' -TimeoutSeconds $FullRepatchTimeoutSeconds -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'),
        '-OnlyModelExperience',
        '-InstallPrerequisites',
        '-Install',
        '-Launch',
        '-CleanupWindowsSdkAfterInstall',
        '-CleanupAfter',
        '-ForceRebuild'
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
