[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$SourceGlobalState,
  [string]$RunId = ('codex-project-index-repair-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
  [string]$OutputRoot,
  [switch]$Apply,
  [switch]$AllowRunningDesktop
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

  if ([string]::IsNullOrWhiteSpace($Content)) {
    throw "refusing to write empty JSON content: $Path"
  }
  if ($Content.IndexOf([char]0) -ge 0) {
    throw "refusing to write JSON content containing NUL bytes: $Path"
  }
  $null = $Content | ConvertFrom-Json
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-JsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "JSON file not found: $Path"
  }
  $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "refusing empty JSON file: $Path"
  }
  if ($raw.IndexOf([char]0) -ge 0) {
    throw "refusing JSON file containing NUL bytes: $Path"
  }
  return $raw | ConvertFrom-Json
}

function Get-PropValue {
  param(
    [pscustomobject]$Object,
    [string]$Name
  )

  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) {
    return $null
  }
  return ,$prop.Value
}

function Set-PropValue {
  param(
    [pscustomobject]$Object,
    [string]$Name,
    [object]$Value
  )

  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  } else {
    $prop.Value = $Value
  }
}

function Get-Count {
  param([object]$Value)

  [int]$count = 0
  if ($null -eq $Value) {
    $count = 0
  } elseif ($Value -is [array]) {
    $count = @($Value).Count
  } elseif ($Value -is [pscustomobject]) {
    $count = @($Value.PSObject.Properties).Count
  } else {
    $count = 1
  }
  return $count
}

function Copy-IfUseful {
  param(
    [pscustomobject]$Current,
    [pscustomobject]$Source,
    [string]$Name,
    [object[]]$Report
  )

  $sourceProp = $Source.PSObject.Properties[$Name]
  $currentProp = $Current.PSObject.Properties[$Name]
  $sourceValue = if ($null -eq $sourceProp) { $null } else { $sourceProp.Value }
  $currentValue = if ($null -eq $currentProp) { $null } else { $currentProp.Value }
  $sourceCount = Get-Count -Value $sourceValue
  $currentCount = Get-Count -Value $currentValue

  $changed = $false
  if ($sourceCount -gt $currentCount) {
    Set-PropValue $Current $Name $sourceValue
    $changed = $true
  }

  $Report += [pscustomobject]@{
    field = $Name
    currentCount = $currentCount
    sourceCount = $sourceCount
    copied = $changed
  }
  return $Report
}

function Copy-AtomKeyIfUseful {
  param(
    [pscustomobject]$Current,
    [pscustomobject]$Source,
    [string]$Name,
    [object[]]$Report
  )

  $currentAtomProp = $Current.PSObject.Properties['electron-persisted-atom-state']
  $sourceAtomProp = $Source.PSObject.Properties['electron-persisted-atom-state']
  $currentAtom = if ($null -eq $currentAtomProp) { $null } else { $currentAtomProp.Value }
  $sourceAtom = if ($null -eq $sourceAtomProp) { $null } else { $sourceAtomProp.Value }
  if ($null -eq $sourceAtom) {
    return $Report
  }
  if ($null -eq $currentAtom) {
    $currentAtom = [pscustomobject]@{}
    Set-PropValue $Current 'electron-persisted-atom-state' $currentAtom
  }

  $sourceProp = $sourceAtom.PSObject.Properties[$Name]
  $currentProp = $currentAtom.PSObject.Properties[$Name]
  $sourceValue = if ($null -eq $sourceProp) { $null } else { $sourceProp.Value }
  $currentValue = if ($null -eq $currentProp) { $null } else { $currentProp.Value }
  $sourceCount = Get-Count -Value $sourceValue
  $currentCount = Get-Count -Value $currentValue

  $changed = $false
  if ($sourceCount -gt $currentCount) {
    Set-PropValue $currentAtom $Name $sourceValue
    $changed = $true
  }

  $Report += [pscustomobject]@{
    field = "electron-persisted-atom-state.$Name"
    currentCount = $currentCount
    sourceCount = $sourceCount
    copied = $changed
  }
  return $Report
}

$globalStatePath = Join-Path $CodexHome '.codex-global-state.json'
if ([string]::IsNullOrWhiteSpace($SourceGlobalState)) {
  $candidate = Join-Path $CodexHome '.codex-global-state.json.bak.bak'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $SourceGlobalState = $candidate
  } else {
    throw 'SourceGlobalState was not provided and .codex-global-state.json.bak.bak was not found'
  }
}

$desktopProcesses = @(Get-Process -Name Codex -ErrorAction SilentlyContinue)
if ($Apply -and -not $AllowRunningDesktop -and $desktopProcesses.Count -gt 0) {
  throw "Codex Desktop appears to be running; quit it first or pass -AllowRunningDesktop. PIDs: $($desktopProcesses.Id -join ', ')"
}

$current = Read-JsonFile $globalStatePath
$source = Read-JsonFile $SourceGlobalState
$report = @()

foreach ($field in @(
  'electron-saved-workspace-roots',
  'project-order',
  'pinned-thread-ids',
  'projectless-thread-ids',
  'thread-projectless-output-directories',
  'thread-workspace-root-hints'
)) {
  $report = Copy-IfUseful $current $source $field $report
}

foreach ($field in @(
  'sidebar-collapsed-groups',
  'sidebar-collapsed-sections-v1',
  'heartbeat-thread-permissions-by-id',
  'prompt-history',
  'unread-thread-ids-by-host-v1'
)) {
  $report = Copy-AtomKeyIfUseful $current $source $field $report
}

$candidateJson = $current | ConvertTo-Json -Depth 100 -Compress
$candidatePath = Join-Path $runRoot '.codex-global-state.candidate.json'
$reportPath = Join-Path $runRoot 'project-index-repair-report.json'
Write-Utf8NoBom -Path $candidatePath -Content $candidateJson
Write-Utf8NoBom -Path $reportPath -Content ($report | ConvertTo-Json -Depth 8)

if ($Apply) {
  $backupPath = Join-Path $CodexHome ('.codex-global-state.json.before-project-index-repair-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.bak')
  Copy-Item -LiteralPath $globalStatePath -Destination $backupPath -Force
  $tempPath = Join-Path $CodexHome ('.codex-global-state.json.tmp-' + [guid]::NewGuid().ToString('n'))
  Write-Utf8NoBom -Path $tempPath -Content $candidateJson
  Move-Item -LiteralPath $tempPath -Destination $globalStatePath -Force
  $null = Read-JsonFile $globalStatePath
  Write-Host "[codex-project-index-repair] applied; backup: $backupPath"
} else {
  Write-Host '[codex-project-index-repair] dry run only; pass -Apply after quitting Codex Desktop'
}

Write-Host "[codex-project-index-repair] run root: $runRoot"
Write-Host "[codex-project-index-repair] candidate: $candidatePath"
Write-Host "[codex-project-index-repair] report: $reportPath"
$report | Format-Table -AutoSize
