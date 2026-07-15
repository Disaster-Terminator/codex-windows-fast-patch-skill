[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$RunId = ('codex-desktop-state-audit-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
  [string]$OutputRoot,
  [int]$RecentHours = 8,
  [int]$MaxFilesPerArea = 200
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $repoRoot 'artifacts\runs'
}

$runRoot = Join-Path $OutputRoot $RunId
if (Test-Path -LiteralPath $runRoot) {
  throw "trace run already exists: $runRoot"
}
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-JsonFile {
  param(
    [string]$Path,
    [object]$Value,
    [int]$Depth = 8
  )

  Write-Utf8NoBom -Path $Path -Content ($Value | ConvertTo-Json -Depth $Depth)
}

function Get-FileDigestSummary {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [ordered]@{
      path = $Path
      exists = $false
    }
  }

  $item = Get-Item -LiteralPath $Path
  $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
  $nulCount = 0
  foreach ($byte in $bytes) {
    if ($byte -eq 0) {
      $nulCount++
    }
  }

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $digest = $sha256.ComputeHash($bytes)
    $hash = -join ($digest | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha256.Dispose()
  }
  return [ordered]@{
    path = $item.FullName
    exists = $true
    length = $item.Length
    creationTime = $item.CreationTime.ToString('o')
    lastWriteTime = $item.LastWriteTime.ToString('o')
    sha256 = $hash
    nulBytes = $nulCount
  }
}

function Get-ChildFileInventory {
  param(
    [string]$Path,
    [int]$MaxFiles = 200
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    return @()
  }

  return @(
    Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First $MaxFiles |
      ForEach-Object {
        [ordered]@{
          path = $_.FullName
          relativePath = $_.FullName.Substring($Path.Length).TrimStart('\')
          length = $_.Length
          creationTime = $_.CreationTime.ToString('o')
          lastWriteTime = $_.LastWriteTime.ToString('o')
        }
      }
  )
}

function Get-RecentLogHits {
  param(
    [string]$LogsRoot,
    [datetime]$Since
  )

  if (-not (Test-Path -LiteralPath $LogsRoot -PathType Container)) {
    return @()
  }

  $patterns = @(
    'onboarding',
    'project',
    'workspace',
    'migration',
    'reset',
    'first run',
    'first-run',
    'database',
    'indexeddb',
    'localstorage',
    'corrupt',
    'config',
    'auth'
  )

  $files = Get-ChildItem -LiteralPath $LogsRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $Since } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 80

  $hits = @()
  foreach ($file in $files) {
    try {
      $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -SimpleMatch -ErrorAction Stop |
        Select-Object -First 40
      foreach ($match in $matches) {
        $hits += [ordered]@{
          file = $file.FullName
          lastWriteTime = $file.LastWriteTime.ToString('o')
          lineNumber = $match.LineNumber
          line = $match.Line
        }
      }
    } catch {
      $hits += [ordered]@{
        file = $file.FullName
        lastWriteTime = $file.LastWriteTime.ToString('o')
        error = $_.Exception.Message
      }
    }
  }

  return $hits
}

$since = (Get-Date).AddHours(-1 * [math]::Abs($RecentHours))
$codexHome = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexHome 'config.toml'
$backupRoot = Join-Path $codexHome 'backups\config'
$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
$packageRoot = if ($package) {
  Join-Path $env:LOCALAPPDATA ('Packages\' + $package.PackageFamilyName)
} else {
  Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0'
}
$localCache = Join-Path $packageRoot 'LocalCache'
$localState = Join-Path $packageRoot 'LocalState'
$roamingCodex = Join-Path $localCache 'Roaming\Codex'
$localCodex = Join-Path $localCache 'Local\Codex'
$logsRoot = Join-Path $localCodex 'Logs'

$backupFiles = @()
if (Test-Path -LiteralPath $backupRoot -PathType Container) {
  $backupFiles = @(
    Get-ChildItem -LiteralPath $backupRoot -Filter 'config.toml*.bak' -File |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 20 |
      ForEach-Object { Get-FileDigestSummary $_.FullName }
  )
}

$stateAreas = [ordered]@{
  packageRoot = $packageRoot
  localCache = $localCache
  localState = $localState
  roamingCodex = $roamingCodex
  localCodex = $localCodex
  logsRoot = $logsRoot
}

$summary = [ordered]@{
  runId = $RunId
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  since = $since.ToString('o')
  package = if ($package) {
    [ordered]@{
      name = $package.Name
      packageFullName = $package.PackageFullName
      packageFamilyName = $package.PackageFamilyName
      version = [string]$package.Version
      signatureKind = [string]$package.SignatureKind
      installLocation = $package.InstallLocation
    }
  } else {
    $null
  }
  codexHome = $codexHome
  config = Get-FileDigestSummary $configPath
  recentConfigBackups = $backupFiles
  stateAreas = $stateAreas
}

ConvertTo-JsonFile -Path (Join-Path $runRoot 'summary.json') -Value $summary -Depth 10
ConvertTo-JsonFile -Path (Join-Path $runRoot 'package-files-recent.json') -Value (Get-ChildFileInventory -Path $packageRoot -MaxFiles $MaxFilesPerArea) -Depth 8
ConvertTo-JsonFile -Path (Join-Path $runRoot 'roaming-codex-files-recent.json') -Value (Get-ChildFileInventory -Path $roamingCodex -MaxFiles $MaxFilesPerArea) -Depth 8
ConvertTo-JsonFile -Path (Join-Path $runRoot 'local-codex-files-recent.json') -Value (Get-ChildFileInventory -Path $localCodex -MaxFiles $MaxFilesPerArea) -Depth 8
ConvertTo-JsonFile -Path (Join-Path $runRoot 'local-state-files-recent.json') -Value (Get-ChildFileInventory -Path $localState -MaxFiles $MaxFilesPerArea) -Depth 8
ConvertTo-JsonFile -Path (Join-Path $runRoot 'recent-log-hits.json') -Value (Get-RecentLogHits -LogsRoot $logsRoot -Since $since) -Depth 8

Write-Host "[codex-desktop-state-audit] run root: $runRoot"
Write-Host "[codex-desktop-state-audit] package root: $packageRoot"
Write-Host "[codex-desktop-state-audit] config length: $($summary.config.length); nul bytes: $($summary.config.nulBytes)"
Write-Host "[codex-desktop-state-audit] wrote summary.json and recent state inventories"
