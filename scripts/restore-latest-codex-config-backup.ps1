[CmdletBinding()]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$BackupPath,
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-config-restore]'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'config-safe-write.ps1')

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

$configPath = Join-Path $CodexHome 'config.toml'
$backupRoot = Join-Path $CodexHome 'backups\config'

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
  if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
    throw "backup directory not found: $backupRoot"
  }

  $BackupPath = Get-ChildItem -LiteralPath $backupRoot -Filter 'config.toml*.bak' -File |
    Sort-Object LastWriteTime -Descending |
    Where-Object {
      try {
        Test-CodexConfigTomlFile $_.FullName
        $true
      } catch {
        Write-Log "skipping invalid backup: $($_.FullName) ($($_.Exception.Message))"
        $false
      }
    } |
    Select-Object -First 1 -ExpandProperty FullName
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
  throw "no valid config.toml backup found under $backupRoot"
}

Test-CodexConfigTomlFile $BackupPath
$backupItem = Get-Item -LiteralPath $BackupPath
Write-Log "selected backup: $($backupItem.FullName)"
Write-Log "backup last write: $($backupItem.LastWriteTime)"
Write-Log "target config: $configPath"

if (-not $Apply) {
  Write-Log 'dry run only; pass -Apply to restore this backup'
  exit 0
}

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
  $rollbackPath = "$configPath.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').pre-restore.bak"
  Copy-Item -LiteralPath $configPath -Destination $rollbackPath -Force
  Write-Log "current config backup before restore: $rollbackPath"
  Remove-Item -LiteralPath $configPath -Force
}

$content = [System.IO.File]::ReadAllText($BackupPath, [System.Text.UTF8Encoding]::new($false, $true))
Write-CodexConfigTomlSafely -Path $configPath -Content $content
Write-Log 'restore ok'
