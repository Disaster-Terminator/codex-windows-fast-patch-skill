function Test-CodexConfigTomlContent {
  param([string]$Content)

  if ([string]::IsNullOrWhiteSpace($Content)) {
    throw 'refusing to write empty config.toml content'
  }
  if ($Content.IndexOf([char]0) -ge 0) {
    throw 'refusing to write config.toml content containing NUL bytes'
  }
  if ($Content -notmatch '(?m)^\s*(model|model_provider|approval_policy|sandbox_mode)\s*=' -and
      $Content -notmatch '(?m)^\s*\[(mcp_servers|marketplaces|plugins|features|windows)[^\]]*\]') {
    throw 'refusing to write config.toml content that does not look like Codex TOML'
  }
}

function Test-CodexConfigTomlFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "config.toml validation target is missing: $Path"
  }

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) {
    throw "refusing config.toml file with zero bytes: $Path"
  }
  if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
    throw "refusing config.toml file containing NUL bytes: $Path"
  }

  $encoding = [System.Text.UTF8Encoding]::new($false, $true)
  $content = $encoding.GetString($bytes)
  Test-CodexConfigTomlContent $content
}

function Write-CodexConfigTomlSafely {
  param(
    [string]$Path,
    [string]$Content
  )

  Test-CodexConfigTomlContent $Content

  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    Test-CodexConfigTomlFile $Path
  }

  $tempPath = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
  $encoding = [System.Text.UTF8Encoding]::new($false)
  try {
    [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
    Test-CodexConfigTomlFile $tempPath
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
    Test-CodexConfigTomlFile $Path
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}
