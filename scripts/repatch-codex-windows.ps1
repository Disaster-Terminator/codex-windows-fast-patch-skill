[CmdletBinding()]
param(
  [string]$PatchScript,
  [string]$MarketplacePath = (Join-Path $env:USERPROFILE '.codex\marketplaces\openai-curated-local'),
  [switch]$DryRun,
  [switch]$NoLaunch,
  [switch]$SkipFastVerify,
  [switch]$SkipSdkCleanup,
  [switch]$KeepBuild,
  [switch]$SkipMarketplace,
  [switch]$SkipComputerUse,
  [switch]$RegisterMarketplaceOnly,
  [switch]$ForceRebuild
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-windows-fast-patch]'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($PatchScript)) {
  $PatchScript = Join-Path $ScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
}
$ComputerUseScript = Join-Path $ScriptRoot 'install-computer-use-local.ps1'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Find-CodexCli {
  $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if (Test-Path -LiteralPath $binRoot) {
    $hit = Get-ChildItem -LiteralPath $binRoot -Recurse -Filter 'codex.exe' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($hit) {
      return $hit.FullName
    }
  }

  $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source -notlike '*\WindowsApps\OpenAI.Codex_*\app\resources\codex.exe') {
    return $cmd.Source
  }

  return $null
}

function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$ErrorMessage
  )

  Write-Log "$FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$ErrorMessage (exit code $LASTEXITCODE)"
  }
}

function Register-LocalMarketplace {
  param([string]$Path)

  $manifest = Join-Path $Path '.agents\plugins\marketplace.json'
  if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Log "warning: local marketplace not found: $manifest"
    Write-Log 'warning: restore it from backup or re-extract it before registering marketplace'
    return
  }

  $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  $alreadyConfigured = $false
  if (Test-Path -LiteralPath $configPath) {
    $alreadyConfigured = Select-String -LiteralPath $configPath -Pattern '^\[marketplaces\.openai-curated-local\]' -Quiet
  }

  if ($alreadyConfigured) {
    Write-Log 'local plugin marketplace already configured: openai-curated-local'
    return
  }

  $codex = Find-CodexCli
  if (-not $codex) {
    Write-Log 'warning: codex CLI not found; cannot register local plugin marketplace'
    return
  }

  Write-Log "registering local plugin marketplace: $Path"
  & $codex plugin marketplace add $Path
  if ($LASTEXITCODE -ne 0) {
    throw "codex plugin marketplace add failed (exit code $LASTEXITCODE)"
  }
}

function Show-Status {
  $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pkg) {
    Write-Log "package: $($pkg.PackageFullName)"
    Write-Log "signature: $($pkg.SignatureKind)"
    Write-Log "install location: $($pkg.InstallLocation)"
  } else {
    Write-Log 'warning: OpenAI.Codex package not found'
  }

  $makeappx = Get-Command makeappx.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  Write-Log "makeappx.exe: $(if ($makeappx) { $makeappx.Source } else { '<missing>' })"
  Write-Log "signtool.exe: $(if ($signtool) { $signtool.Source } else { '<missing>' })"
}

if (-not $SkipMarketplace) {
  Register-LocalMarketplace $MarketplacePath
}

if (-not $SkipComputerUse) {
  if (-not (Test-Path -LiteralPath $ComputerUseScript)) {
    throw "Computer Use installer not found: $ComputerUseScript"
  }
  if ($DryRun) {
    Invoke-Checked 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ComputerUseScript, '-VerifyOnly') 'Computer Use verification failed'
  } else {
    Invoke-Checked 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ComputerUseScript) 'Computer Use installation failed'
    $env:CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE = '1'
  }
}

if ($RegisterMarketplaceOnly) {
  Show-Status
  exit 0
}

if (-not (Test-Path -LiteralPath $PatchScript)) {
  throw "patch script not found: $PatchScript"
}

$patchArgs = @()
if ($DryRun) {
  $patchArgs += '-DryRun'
  $patchArgs += '-ForceRebuild'
} else {
  $patchArgs += '-InstallPrerequisites'
  $patchArgs += '-Install'
  if (-not $NoLaunch) {
    $patchArgs += '-Launch'
  }
  if (-not $SkipSdkCleanup) {
    $patchArgs += '-CleanupWindowsSdkAfterInstall'
  }
  if (-not $KeepBuild) {
    $patchArgs += '-CleanupAfter'
  }
  if (-not $SkipFastVerify) {
    $patchArgs += '-VerifyFastModeRequest'
  }
  if ($ForceRebuild) {
    $patchArgs += '-ForceRebuild'
  }
}

Invoke-Checked 'powershell' (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PatchScript) + $patchArgs) 'Codex MSIX patch failed'

if (-not $SkipMarketplace) {
  Register-LocalMarketplace $MarketplacePath
}

Show-Status
