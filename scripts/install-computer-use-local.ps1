[CmdletBinding()]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$PluginVersion = '0.1.0-local',
  [switch]$VerifyOnly,
  [switch]$SkipUserEnvironment
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-computer-use-local]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )
  Write-Utf8NoBom $Path (($Value | ConvertTo-Json -Depth 30) + "`n")
}

function Resolve-OrCreateDirectory {
  param([string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-UnderPath {
  param(
    [string]$Path,
    [string]$Parent
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to modify path outside expected root: $full"
  }
}

function Set-TomlTable {
  param(
    [string]$ConfigPath,
    [string]$Header,
    [hashtable]$Values
  )

  $content = ''
  if (Test-Path -LiteralPath $ConfigPath) {
    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  }

  $lines = foreach ($key in ($Values.Keys | Sort-Object)) {
    $value = $Values[$key]
    if ($value -is [bool]) {
      "$key = $($value.ToString().ToLowerInvariant())"
    } else {
      $escaped = [string]$value -replace "'", "''"
      "$key = '$escaped'"
    }
  }
  $body = ($lines -join "`r`n") + "`r`n"
  $escapedHeader = [regex]::Escape($Header)
  $pattern = "(?ms)^$escapedHeader\s*\r?\n(?:(?!^\[).)*"
  $replacement = "$Header`r`n$body"

  if ([regex]::IsMatch($content, $pattern)) {
    $content = [regex]::Replace($content, $pattern, $replacement, 1)
  } else {
    if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) {
      $content += "`r`n"
    }
    if ($content.Length -gt 0 -and -not $content.EndsWith("`r`n`r`n")) {
      $content += "`r`n"
    }
    $content += $replacement
  }

  Write-Utf8NoBom $ConfigPath $content
}

function Enable-UserEnvironment {
  if ($SkipUserEnvironment) {
    Write-Log 'skipping user environment update'
    return
  }

  [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE', '1', 'User')
  $env:CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE = '1'

  try {
    $signature = @'
using System;
using System.Runtime.InteropServices;
public static class CodexEnvBroadcast {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
    if (-not ('CodexEnvBroadcast' -as [type])) {
      Add-Type -TypeDefinition $signature
    }
    $result = [UIntPtr]::Zero
    [CodexEnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result) | Out-Null
  } catch {
    Write-Log "warning: environment broadcast failed: $($_.Exception.Message)"
  }

  Write-Log 'enabled CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1 for this process and the current user'
}

function Get-PluginJson {
  return [ordered]@{
    name = 'computer-use'
    version = $PluginVersion
    description = 'Local Windows Computer Use compatibility helper for Codex Desktop.'
    author = [ordered]@{
      name = 'Local'
    }
    homepage = 'https://openai.com/'
    repository = 'https://openai.com/'
    license = 'Proprietary'
    keywords = @('computer-use', 'windows', 'desktop')
    skills = './skills/'
    interface = [ordered]@{
      displayName = 'Computer Use'
      shortDescription = 'Control this Windows desktop from Codex'
      longDescription = 'Local compatibility plugin that provides the Windows helper paths expected by Codex Desktop Computer Use.'
      developerName = 'Local'
      category = 'Productivity'
      capabilities = @('Interactive', 'Read', 'Write')
      websiteURL = 'https://openai.com/'
      privacyPolicyURL = 'https://openai.com/policies/row-privacy-policy/'
      termsOfServiceURL = 'https://openai.com/policies/row-terms-of-use/'
      defaultPrompt = @('Look at my screen and help me navigate')
      brandColor = '#10A37F'
      screenshots = @()
    }
  }
}

function Get-SkillMarkdown {
  return @'
---
name: computer-use
description: Local Windows Computer Use compatibility helper for Codex Desktop. Provides the @oai/sky paths that the Desktop app expects when CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1.
---

# Computer Use

This local compatibility plugin is installed by the codex-windows-fast-patch skill. It supplies the Windows helper transport paths that Codex Desktop resolves for Computer Use.

The Desktop app must be launched with `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1`. The installer writes that as a user environment variable, so restart Codex after installation.
'@
}

function Get-HelperTransportJs {
  return @'
import { execFile } from "node:child_process";
import { appendFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const logPath = join(
  process.env.LOCALAPPDATA || process.env.TEMP || ".",
  "OpenAI",
  "Codex",
  "computer-use-local-helper.log",
);

async function log(entry) {
  try {
    await mkdir(dirname(logPath), { recursive: true });
    await appendFile(logPath, `${new Date().toISOString()} ${JSON.stringify(entry)}\n`, "utf8");
  } catch {
    // Logging must never break Computer Use requests.
  }
}

function encodePowerShell(script) {
  return Buffer.from(script, "utf16le").toString("base64");
}

async function runPowerShell(script, timeout = 30000) {
  const { stdout } = await execFileAsync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encodePowerShell(script)],
    {
      encoding: "utf8",
      env: process.env,
      timeout,
      windowsHide: true,
      maxBuffer: 64 * 1024 * 1024,
    },
  );
  const text = stdout.trim();
  return text.length === 0 ? null : JSON.parse(text);
}

function numberFrom(params, names, fallback = 0) {
  for (const name of names) {
    const value = params?.[name];
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
  }
  return fallback;
}

function buttonFrom(params) {
  const raw = String(params?.button || params?.mouseButton || "left").toLowerCase();
  if (raw.includes("right")) return "right";
  if (raw.includes("middle")) return "middle";
  return "left";
}

function keyFrom(params) {
  return String(params?.key || params?.keys || params?.text || params?.value || "");
}

function textFrom(params) {
  return String(params?.text ?? params?.value ?? params?.input ?? "");
}

const user32Script = `
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodexUser32 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
}
"@
`;

function mouseFlags(button, action) {
  if (button === "right") return action === "down" ? "0x0008" : "0x0010";
  if (button === "middle") return action === "down" ? "0x0020" : "0x0040";
  return action === "down" ? "0x0002" : "0x0004";
}

async function screenshot() {
  return await runPowerShell(`
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
$stream = New-Object System.IO.MemoryStream
$bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
$bytes = $stream.ToArray()
$stream.Dispose()
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::Write((ConvertTo-Json -Compress @{
  mimeType = "image/png"
  data = [Convert]::ToBase64String($bytes)
  width = $bounds.Width
  height = $bounds.Height
  left = $bounds.Left
  top = $bounds.Top
}))
`, 30000);
}

async function screenInfo() {
  return await runPowerShell(`
Add-Type -AssemblyName System.Windows.Forms
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::Write((ConvertTo-Json -Compress @{
  width = $bounds.Width
  height = $bounds.Height
  left = $bounds.Left
  top = $bounds.Top
}))
`);
}

async function moveMouse(params) {
  const x = Math.round(numberFrom(params, ["x", "X", "left"]));
  const y = Math.round(numberFrom(params, ["y", "Y", "top"]));
  return await runPowerShell(`
${user32Script}
[CodexUser32]::SetCursorPos(${x}, ${y}) | Out-Null
[Console]::Write('{"ok":true}')
`);
}

async function clickMouse(params, count = 1) {
  const x = Math.round(numberFrom(params, ["x", "X", "left"], Number.NaN));
  const y = Math.round(numberFrom(params, ["y", "Y", "top"], Number.NaN));
  const button = buttonFrom(params);
  const down = mouseFlags(button, "down");
  const up = mouseFlags(button, "up");
  const maybeMove = Number.isFinite(x) && Number.isFinite(y) ? `[CodexUser32]::SetCursorPos(${x}, ${y}) | Out-Null` : "";
  return await runPowerShell(`
${user32Script}
${maybeMove}
for ($i = 0; $i -lt ${count}; $i++) {
  [CodexUser32]::mouse_event(${down}, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 35
  [CodexUser32]::mouse_event(${up}, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
}
[Console]::Write('{"ok":true}')
`);
}

async function dragMouse(params) {
  const fromX = Math.round(numberFrom(params, ["fromX", "startX", "x1", "x"]));
  const fromY = Math.round(numberFrom(params, ["fromY", "startY", "y1", "y"]));
  const toX = Math.round(numberFrom(params, ["toX", "endX", "x2"]));
  const toY = Math.round(numberFrom(params, ["toY", "endY", "y2"]));
  return await runPowerShell(`
${user32Script}
[CodexUser32]::SetCursorPos(${fromX}, ${fromY}) | Out-Null
Start-Sleep -Milliseconds 80
[CodexUser32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[CodexUser32]::SetCursorPos(${toX}, ${toY}) | Out-Null
Start-Sleep -Milliseconds 120
[CodexUser32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
[Console]::Write('{"ok":true}')
`);
}

async function scrollMouse(params) {
  const delta = Math.round(numberFrom(params, ["delta", "wheelDelta"], 0) || -120 * numberFrom(params, ["amount", "clicks"], 1));
  return await runPowerShell(`
${user32Script}
[CodexUser32]::mouse_event(0x0800, 0, 0, ${delta}, [UIntPtr]::Zero)
[Console]::Write('{"ok":true}')
`);
}

function sendKeysLiteral(text) {
  return text
    .replaceAll("{", "{{}")
    .replaceAll("}", "{}}")
    .replaceAll("+", "{+}")
    .replaceAll("^", "{^}")
    .replaceAll("%", "{%}")
    .replaceAll("~", "{~}")
    .replaceAll("(", "{(}")
    .replaceAll(")", "{)}")
    .replaceAll("[", "{[}")
    .replaceAll("]", "{]}")
    .replaceAll("\n", "{ENTER}");
}

function normalizeKey(key) {
  const value = String(key).trim();
  const upper = value.toUpperCase();
  const aliases = {
    ENTER: "{ENTER}",
    RETURN: "{ENTER}",
    ESC: "{ESC}",
    ESCAPE: "{ESC}",
    TAB: "{TAB}",
    BACKSPACE: "{BACKSPACE}",
    DELETE: "{DELETE}",
    DEL: "{DELETE}",
    SPACE: " ",
    UP: "{UP}",
    DOWN: "{DOWN}",
    LEFT: "{LEFT}",
    RIGHT: "{RIGHT}",
    HOME: "{HOME}",
    END: "{END}",
    PAGEUP: "{PGUP}",
    PAGEDOWN: "{PGDN}",
  };
  if (aliases[upper]) return aliases[upper];
  if (/^F([1-9]|1[0-2])$/.test(upper)) return `{${upper}}`;
  return sendKeysLiteral(value);
}

async function sendKeys(keys) {
  const encoded = Buffer.from(keys, "utf8").toString("base64");
  return await runPowerShell(`
Add-Type -AssemblyName System.Windows.Forms
$keys = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("${encoded}"))
[System.Windows.Forms.SendKeys]::SendWait($keys)
[Console]::Write('{"ok":true}')
`);
}

async function typeText(params) {
  return await sendKeys(sendKeysLiteral(textFrom(params)));
}

async function keypress(params) {
  return await sendKeys(normalizeKey(keyFrom(params)));
}

export class WindowsHelperTransport {
  constructor({ helperArgs = [], helperCommand = null } = {}) {
    this.helperArgs = helperArgs;
    this.helperCommand = helperCommand;
    log({ event: "transport-created", helperCommand, helperArgs }).catch(() => {});
  }

  async request(method, params = {}, options = {}) {
    await log({ event: "request", method, params, hasTurnMetadata: !!options?.codexTurnMetadata });
    const name = String(method || "").replace(/[-_]/g, "").toLowerCase();
    if (name === "ping") return "pong";
    if (["screenshot", "takescreenshot", "capture", "captureimage", "capturescreen", "screencapture"].includes(name)) return await screenshot(params);
    if (["screeninfo", "getscreeninfo", "displays", "getdisplays", "screenstate"].includes(name)) return await screenInfo(params);
    if (["movemouse", "mousemove", "move"].includes(name)) return await moveMouse(params);
    if (["click", "mouseclick", "clickmouse"].includes(name)) return await clickMouse(params, 1);
    if (["doubleclick", "mousedoubleclick"].includes(name)) return await clickMouse(params, 2);
    if (["drag", "mousedrag", "dragmouse"].includes(name)) return await dragMouse(params);
    if (["scroll", "mousescroll", "scrollmouse"].includes(name)) return await scrollMouse(params);
    if (["type", "typetext", "text"].includes(name)) return await typeText(params);
    if (["keypress", "presskey", "key", "sendkey"].includes(name)) return await keypress(params);
    if (["close", "shutdown"].includes(name)) return { ok: true };
    await log({ event: "unknown-method", method, params });
    throw new Error(`Unsupported local Computer Use helper method: ${method}`);
  }

  async close() {
    await log({ event: "transport-closed" });
  }
}
'@
}

function Write-PluginTree {
  param([string]$Root)

  $pluginJsonPath = Join-Path $Root '.codex-plugin\plugin.json'
  $skillPath = Join-Path $Root 'skills\computer-use\SKILL.md'
  $packagePath = Join-Path $Root 'node_modules\@oai\sky\package.json'
  $helperExePath = Join-Path $Root 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
  $helperTransportPath = Join-Path $Root 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'

  ConvertTo-JsonFile $pluginJsonPath (Get-PluginJson)
  Write-Utf8NoBom $skillPath ((Get-SkillMarkdown) + "`n")
  ConvertTo-JsonFile $packagePath ([ordered]@{
    name = '@oai/sky'
    version = $PluginVersion
    type = 'module'
    private = $true
  })
  Write-Utf8NoBom $helperExePath "# Placeholder executable path for Codex Desktop Windows Computer Use resolution.`r`n# The local helper transport module implements the actual request handling.`r`n"
  Write-Utf8NoBom $helperTransportPath ((Get-HelperTransportJs) + "`n")
}

function Update-BundledMarketplaceManifest {
  param([string]$MarketplaceRoot)

  $manifestPath = Join-Path $MarketplaceRoot '.agents\plugins\marketplace.json'
  if (Test-Path -LiteralPath $manifestPath) {
    $json = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  } else {
    $json = [pscustomobject]@{
      name = 'openai-bundled'
      interface = [pscustomobject]@{ displayName = 'OpenAI Bundled' }
      plugins = @()
    }
  }

  if (-not $json.name) {
    $json | Add-Member -NotePropertyName name -NotePropertyValue 'openai-bundled'
  }
  if (-not $json.interface) {
    $json | Add-Member -NotePropertyName interface -NotePropertyValue ([pscustomobject]@{ displayName = 'OpenAI Bundled' })
  }

  $entry = [pscustomobject]@{
    name = 'computer-use'
    source = [pscustomobject]@{
      source = 'local'
      path = './plugins/computer-use'
    }
    policy = [pscustomobject]@{
      installation = 'INSTALLED_BY_DEFAULT'
      authentication = 'ON_INSTALL'
    }
    category = 'Productivity'
  }

  $plugins = @($json.plugins | Where-Object { $_.name -ne 'computer-use' })
  $json.plugins = @($entry) + $plugins
  ConvertTo-JsonFile $manifestPath $json
}

function Update-CodexConfig {
  param([string]$MarketplaceRoot)

  $configPath = Join-Path $CodexHome 'config.toml'
  if ((Test-Path -LiteralPath $configPath) -and -not (Test-Path -LiteralPath "$configPath.computer-use.bak")) {
    Copy-Item -LiteralPath $configPath -Destination "$configPath.computer-use.bak" -Force
  }
  $source = '\\?\' + $MarketplaceRoot
  Set-TomlTable $configPath '[marketplaces.openai-bundled]' @{
    last_updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    source = $source
    source_type = 'local'
  }
  Set-TomlTable $configPath '[plugins."computer-use@openai-bundled"]' @{
    enabled = $true
  }
}

function Test-TomlSyntax {
  param([string]$ConfigPath)

  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    Write-Log 'warning: python not found; skipping tomllib syntax validation'
    return
  }

  $script = @'
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
tomllib.loads(path.read_text(encoding="utf-8"))
'@
  $temp = Join-Path $env:TEMP ('codex-toml-validate-' + [guid]::NewGuid().ToString('N') + '.py')
  try {
    Write-Utf8NoBom $temp $script
    & $python.Source $temp $ConfigPath
    if ($LASTEXITCODE -ne 0) {
      throw "tomllib validation failed for $ConfigPath"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Install-ComputerUse {
  $codexHomeResolved = Resolve-OrCreateDirectory $CodexHome
  $marketplaceRoot = Join-Path $codexHomeResolved '.tmp\bundled-marketplaces\openai-bundled'
  $pluginSourceRoot = Join-Path $marketplaceRoot 'plugins\computer-use'
  $cacheRoot = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\computer-use'
  $cacheVersionRoot = Join-Path $cacheRoot $PluginVersion
  $latestPath = Join-Path $cacheRoot 'latest'

  Resolve-OrCreateDirectory $marketplaceRoot | Out-Null
  Resolve-OrCreateDirectory $cacheRoot | Out-Null
  Assert-UnderPath $pluginSourceRoot $marketplaceRoot
  Assert-UnderPath $cacheVersionRoot $cacheRoot
  Assert-UnderPath $latestPath $cacheRoot

  Write-PluginTree $pluginSourceRoot
  Write-PluginTree $cacheVersionRoot
  Update-BundledMarketplaceManifest $marketplaceRoot
  Update-CodexConfig $marketplaceRoot
  Enable-UserEnvironment

  if (Test-Path -LiteralPath $latestPath) {
    Remove-Item -LiteralPath $latestPath -Recurse -Force
  }
  New-Item -ItemType Junction -Path $latestPath -Target $cacheVersionRoot | Out-Null

  Write-Log "installed marketplace plugin: $pluginSourceRoot"
  Write-Log "installed cached plugin: $cacheVersionRoot"
  Write-Log "updated latest junction: $latestPath"
}

function Test-ComputerUse {
  $codexHomeResolved = Resolve-OrCreateDirectory $CodexHome
  $marketplaceRoot = Join-Path $codexHomeResolved '.tmp\bundled-marketplaces\openai-bundled'
  $manifestPath = Join-Path $marketplaceRoot '.agents\plugins\marketplace.json'
  $cacheLatest = Join-Path $codexHomeResolved 'plugins\cache\openai-bundled\computer-use\latest'
  $required = @(
    $manifestPath,
    (Join-Path $marketplaceRoot 'plugins\computer-use\.codex-plugin\plugin.json'),
    (Join-Path $cacheLatest '.codex-plugin\plugin.json'),
    (Join-Path $cacheLatest 'node_modules\@oai\sky\package.json'),
    (Join-Path $cacheLatest 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe'),
    (Join-Path $cacheLatest 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')
  )

  foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path)) {
      throw "missing required Computer Use path: $path"
    }
  }

  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $entry = @($manifest.plugins | Where-Object { $_.name -eq 'computer-use' }) | Select-Object -First 1
  if (-not $entry) {
    throw 'computer-use is missing from openai-bundled marketplace manifest'
  }
  if ($entry.source.source -ne 'local' -or $entry.source.path -ne './plugins/computer-use') {
    throw 'computer-use marketplace entry does not point to ./plugins/computer-use'
  }

  $userEnv = [Environment]::GetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE', 'User')
  if ($userEnv -ne '1') {
    throw 'CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE is not enabled for the current user'
  }

  Test-TomlSyntax (Join-Path $codexHomeResolved 'config.toml')
  Write-Log 'verification ok'
}

if ($VerifyOnly) {
  Test-ComputerUse
  exit 0
}

Install-ComputerUse
Test-ComputerUse
