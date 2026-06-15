[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$RunId = ('codex-desktop-crash-audit-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
  [string]$OutputRoot,
  [int]$RecentMinutes = 180,
  [datetime]$AroundLocalTime,
  [int]$WindowMinutes = 5,
  [int]$MaxLogFiles = 12
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
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value,
    [int]$Depth = 8
  )

  Write-Utf8NoBom -Path $Path -Content ($Value | ConvertTo-Json -Depth $Depth)
}

function Convert-ExitCodeToHex {
  param([object]$Code)

  if ($null -eq $Code -or [string]::IsNullOrWhiteSpace([string]$Code)) {
    return $null
  }

  try {
    return ('0x{0:x8}' -f ([uint32][int64]$Code))
  } catch {
    return $null
  }
}

function Get-CodexPackage {
  $pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $pkg) {
    return $null
  }

  return [ordered]@{
    name = $pkg.Name
    packageFullName = $pkg.PackageFullName
    packageFamilyName = $pkg.PackageFamilyName
    version = [string]$pkg.Version
    signatureKind = [string]$pkg.SignatureKind
    installLocation = $pkg.InstallLocation
  }
}

function Get-CodexApplicationEvents {
  param(
    [datetime]$StartTime,
    [datetime]$EndTime
  )

  $events = Get-WinEvent -FilterHashtable @{
      LogName = 'Application'
      StartTime = $StartTime
      EndTime = $EndTime
    } -ErrorAction SilentlyContinue

  return @(
    $events |
      Where-Object {
        $_.ProviderName -match 'Application Error|Windows Error Reporting' -and
        $_.Message -match 'OpenAI\.Codex|codex\.exe|Codex\.exe'
      } |
      ForEach-Object {
        [ordered]@{
          timeCreated = $_.TimeCreated.ToString('o')
          id = $_.Id
          providerName = $_.ProviderName
          message = $_.Message
        }
      }
  )
}

function Get-CodexSystemEvents {
  param(
    [datetime]$StartTime,
    [datetime]$EndTime
  )

  $events = Get-WinEvent -FilterHashtable @{
      LogName = 'System'
      StartTime = $StartTime
      EndTime = $EndTime
    } -ErrorAction SilentlyContinue

  return @(
    $events |
      Where-Object {
        $_.ProviderName -match 'Resource|Memory|Kernel|Application Popup' -or
        $_.Message -match 'memory|commit|virtual memory|Codex|codex|内存|资源'
      } |
      ForEach-Object {
        [ordered]@{
          timeCreated = $_.TimeCreated.ToString('o')
          id = $_.Id
          providerName = $_.ProviderName
          level = $_.LevelDisplayName
          message = $_.Message
        }
      }
  )
}

function Get-WerReports {
  param(
    [datetime]$Since,
    [datetime]$Until
  )

  $root = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    return @()
  }

  $patterns = @(
    'EventType=',
    'ReportIdentifier=',
    'IntegratorReportIdentifier=',
    'AppSessionGuid=',
    'TargetAppVer=',
    'IsFatal=',
    'Sig[',
    'DynamicSig[',
    'FriendlyEventName=',
    'AppName=',
    'AppPath='
  )

  return @(
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -like 'AppCrash_OpenAI.Codex*' -and
        $_.LastWriteTime -ge $Since -and
        $_.LastWriteTime -le $Until
      } |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object {
        $wer = Join-Path $_.FullName 'Report.wer'
        $fields = @()
        if (Test-Path -LiteralPath $wer -PathType Leaf) {
          $fields = @(
            Select-String -LiteralPath $wer -Pattern $patterns -SimpleMatch -ErrorAction Stop |
              ForEach-Object { $_.Line }
          )
        }

        [ordered]@{
          directory = $_.FullName
          lastWriteTime = $_.LastWriteTime.ToString('o')
          report = $wer
          fields = $fields
        }
      }
  )
}

function Get-CrashDumps {
  param(
    [datetime]$Since,
    [datetime]$Until
  )

  $root = Join-Path $env:LOCALAPPDATA 'CrashDumps'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    return @()
  }

  return @(
    Get-ChildItem -LiteralPath $root -Filter 'codex*.dmp' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $Since -and $_.LastWriteTime -le $Until } |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object {
        [ordered]@{
          path = $_.FullName
          length = $_.Length
          creationTime = $_.CreationTime.ToString('o')
          lastWriteTime = $_.LastWriteTime.ToString('o')
        }
      }
  )
}

function Get-LogWindowLines {
  param(
    [string]$LogsRoot,
    [datetime]$WindowStartUtc,
    [datetime]$WindowEndUtc,
    [datetime]$Since
  )

  if (-not (Test-Path -LiteralPath $LogsRoot -PathType Container)) {
    return @()
  }

  $prefixes = @()
  $cursor = $WindowStartUtc.AddMinutes(-1)
  while ($cursor -le $WindowEndUtc.AddMinutes(1)) {
    $prefixes += $cursor.ToString('yyyy-MM-ddTHH:mm')
    $cursor = $cursor.AddMinutes(1)
  }
  $prefixes = @($prefixes | Select-Object -Unique)

  $keywords = @(
    'memory allocation',
    'app_server_connection.closed',
    'Codex CLI process exited',
    'fatal_error_broadcasted',
    'app-server is not available',
    'nodeVersionError',
    'git.command.complete',
    'spawnFailed',
    'command_failed',
    'memory',
    'failed',
    'error',
    '3221225773',
    '3221226505',
    '0xc000012d',
    '0xc0000409',
    'computer-use',
    'computer_use',
    'native pipe',
    'IAB_LIFECYCLE'
  )

  $dayRoot = Join-Path $LogsRoot $WindowStartUtc.ToString('yyyy\\MM\\dd')
  $scanRoot = if (Test-Path -LiteralPath $dayRoot -PathType Container) { $dayRoot } else { $LogsRoot }
  $files = @(
    Get-ChildItem -LiteralPath $scanRoot -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $Since } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First $MaxLogFiles
  )

  $matches = @()
  foreach ($file in $files) {
    $lineNo = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName -ErrorAction Stop) {
      $lineNo++
      $text = [string]$line
      $isWindowLine = $false
      foreach ($prefix in $prefixes) {
        if ($text.StartsWith($prefix, [StringComparison]::Ordinal)) {
          $isWindowLine = $true
          break
        }
      }

      $isKeywordLine = $false
      foreach ($keyword in $keywords) {
        if ($text.IndexOf($keyword, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
          $isKeywordLine = $true
          break
        }
      }

      if ($isWindowLine -and $isKeywordLine) {
        $matches += [ordered]@{
          file = $file.FullName
          lineNumber = $lineNo
          fileLastWriteTime = $file.LastWriteTime.ToString('o')
          line = $text
        }
      }
    }
  }

  return $matches
}

$package = Get-CodexPackage
$packageFamilyName = if ($package) { $package.packageFamilyName } else { 'OpenAI.Codex_2p2nqsd0c76g0' }
$logsRoot = Join-Path $env:LOCALAPPDATA ('Packages\' + $packageFamilyName + '\LocalCache\Local\Codex\Logs')

$initialStart = if ($AroundLocalTime) {
  $AroundLocalTime.AddMinutes(-1 * [math]::Abs($WindowMinutes))
} else {
  (Get-Date).AddMinutes(-1 * [math]::Abs($RecentMinutes))
}
$initialEnd = if ($AroundLocalTime) {
  $AroundLocalTime.AddMinutes([math]::Abs($WindowMinutes))
} else {
  Get-Date
}

$appEvents = Get-CodexApplicationEvents -StartTime $initialStart -EndTime $initialEnd
$primaryCrashTime = $null
if ($AroundLocalTime) {
  $primaryCrashTime = $AroundLocalTime
} elseif ($appEvents.Count -gt 0) {
  $primaryCrashTime = [datetime]$appEvents[0].timeCreated
} else {
  $primaryCrashTime = Get-Date
}

$windowStart = $primaryCrashTime.AddMinutes(-1 * [math]::Abs($WindowMinutes))
$windowEnd = $primaryCrashTime.AddMinutes([math]::Abs($WindowMinutes))
$windowStartUtc = $windowStart.ToUniversalTime()
$windowEndUtc = $windowEnd.ToUniversalTime()
$since = $windowStart.AddMinutes(-1)
$until = $windowEnd.AddMinutes(1)

$appEvents = Get-CodexApplicationEvents -StartTime $windowStart -EndTime $windowEnd
$systemEvents = Get-CodexSystemEvents -StartTime $windowStart -EndTime $windowEnd
$werReports = Get-WerReports -Since $since -Until $until
$crashDumps = Get-CrashDumps -Since $since -Until $until
$logMatches = Get-LogWindowLines -LogsRoot $logsRoot -WindowStartUtc $windowStartUtc -WindowEndUtc $windowEndUtc -Since $since

$summary = [ordered]@{
  runId = $RunId
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  recentMinutes = $RecentMinutes
  primaryCrashTimeLocal = $primaryCrashTime.ToString('o')
  windowStartLocal = $windowStart.ToString('o')
  windowEndLocal = $windowEnd.ToString('o')
  windowStartUtc = $windowStartUtc.ToString('o')
  windowEndUtc = $windowEndUtc.ToString('o')
  logsRoot = $logsRoot
  package = $package
  applicationEventCount = @($appEvents).Count
  systemEventCount = @($systemEvents).Count
  werReportCount = @($werReports).Count
  crashDumpCount = @($crashDumps).Count
  logMatchCount = @($logMatches).Count
}

Write-JsonFile -Path (Join-Path $runRoot 'summary.json') -Value $summary -Depth 8
Write-JsonFile -Path (Join-Path $runRoot 'application-events.json') -Value $appEvents -Depth 8
Write-JsonFile -Path (Join-Path $runRoot 'system-events.json') -Value $systemEvents -Depth 8
Write-JsonFile -Path (Join-Path $runRoot 'wer-reports.json') -Value $werReports -Depth 8
Write-JsonFile -Path (Join-Path $runRoot 'crash-dumps.json') -Value $crashDumps -Depth 8
Write-JsonFile -Path (Join-Path $runRoot 'desktop-log-window.json') -Value $logMatches -Depth 8

$reportLines = @(
  '# Codex Desktop Crash Audit',
  '',
  "- Run: $RunId",
  "- Generated: $((Get-Date).ToString('o'))",
  "- Primary crash local time: $($primaryCrashTime.ToString('o'))",
  "- Window local: $($windowStart.ToString('o')) .. $($windowEnd.ToString('o'))",
  "- Logs root: $logsRoot",
  "- Application events: $(@($appEvents).Count)",
  "- System events: $(@($systemEvents).Count)",
  "- WER reports: $(@($werReports).Count)",
  "- Crash dumps: $(@($crashDumps).Count)",
  "- Desktop log matches: $(@($logMatches).Count)",
  '',
  '## Exit Code Notes',
  '',
  '- 3221226505 = 0xc0000409.',
  '- 3221225773 = 0xc000012d.',
  '',
  '## Files',
  '',
  '- summary.json',
  '- application-events.json',
  '- system-events.json',
  '- wer-reports.json',
  '- crash-dumps.json',
  '- desktop-log-window.json'
)
Write-Utf8NoBom -Path (Join-Path $runRoot 'report.md') -Content ($reportLines -join [Environment]::NewLine)

Write-Host "[codex-desktop-crash-audit] run root: $runRoot"
Write-Host "[codex-desktop-crash-audit] primary crash: $($primaryCrashTime.ToString('o'))"
Write-Host "[codex-desktop-crash-audit] application events: $(@($appEvents).Count)"
Write-Host "[codex-desktop-crash-audit] system events: $(@($systemEvents).Count)"
Write-Host "[codex-desktop-crash-audit] WER reports: $(@($werReports).Count)"
Write-Host "[codex-desktop-crash-audit] crash dumps: $(@($crashDumps).Count)"
Write-Host "[codex-desktop-crash-audit] desktop log matches: $(@($logMatches).Count)"
