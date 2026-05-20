---
name: codex-windows-fast-patch
description: Reapply the Windows Codex Desktop MSIX patch after Store upgrades, including Fast Mode, plugin UI gates, Goal command gates, ASAR integrity repair, signing/installing the patched package, SDK cleanup, Fast Mode wire verification, and registering the local plugin marketplace openai-curated-local.
---

# Codex Windows Fast Patch

Use this skill when the user says Codex Desktop was upgraded and the Fast Mode / Plugins / Goal patch disappeared, asks to repatch Codex on Windows, asks to verify whether Fast Mode is really being sent, asks to restore/register the local plugin marketplace, or asks to enable Windows Computer Use in Codex Desktop.

## Default Workflow

1. Inspect current package status:

```powershell
Get-AppxPackage -Name OpenAI.Codex | Select-Object Name,PackageFullName,Version,SignatureKind,InstallLocation
```

2. Run a dry run first after every Codex upgrade:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\repatch-codex-windows.ps1" -DryRun
```

3. If the dry run finds all patch targets, run the full repatch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\repatch-codex-windows.ps1"
```

The wrapper calls the bundled patch script at `scripts\patch_codex_fast_mode_windows_msix.ps1` with these defaults:

- `-InstallPrerequisites`
- `-Install`
- `-Launch`
- `-CleanupWindowsSdkAfterInstall`
- `-CleanupAfter`
- `-VerifyFastModeRequest`

It also checks/registers the local marketplace at `$env:USERPROFILE\.codex\marketplaces\openai-curated-local`.
It also installs a local `computer-use@openai-bundled` compatibility plugin and enables `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1` for the current user so the Desktop app can expose Windows Computer Use after restart.

## Important Guardrails

- Do not modify `C:\Program Files\WindowsApps` in place. Use the MSIX repack script.
- Do not trust a response like `FAST_CHECK_OK` as proof of Fast Mode. Trust only the wrapper/script wire verification, which captures Codex's `/v1/responses` WebSocket request and checks `service_tier=priority`.
- If the app launches then immediately exits, run Electron logging and check for ASAR integrity failures:

```powershell
$pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
$exe = Join-Path $pkg.InstallLocation 'app\Codex.exe'
$env:ELECTRON_ENABLE_LOGGING='1'
Push-Location (Split-Path -Parent $exe)
& $exe --enable-logging=stderr --v=1 2>&1 | Select-String -Pattern 'FATAL|Integrity|asar|ERROR'
Pop-Location
Remove-Item Env:ELECTRON_ENABLE_LOGGING -ErrorAction SilentlyContinue
```

- If `makeappx.exe` or `signtool.exe` is missing, run the wrapper normally; it installs Windows SDK temporarily and removes it afterward.
- If the local marketplace directory is missing, do not invent a marketplace. Report the missing path and ask whether to restore it from backup or re-extract it from a known source.
- Do not depend on `Downloads\patch_codex_fast_mode_windows_msix.ps1`; the skill is intended to be self-contained. Use `scripts\patch_codex_fast_mode_windows_msix.ps1` unless the user explicitly passes `-PatchScript`.
- Do not modify `C:\Program Files\WindowsApps` in place to enable Computer Use. The Windows gate is controlled by `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1`, and the helper paths are supplied through the local `computer-use@openai-bundled` plugin.

## Useful Wrapper Options

- `-DryRun`: verify bundle targets only; no install.
- `-NoLaunch`: install but do not start Codex Desktop.
- `-SkipFastVerify`: skip the WebSocket `service_tier` capture.
- `-KeepBuild`: keep `Downloads\codex-msix-repack` for debugging.
- `-SkipSdkCleanup`: leave Windows SDK installed.
- `-RegisterMarketplaceOnly`: only register `openai-curated-local`; do not patch Codex.
- `-PatchScript <path>`: override the bundled patch script only when testing a newer patcher.
- `-SkipComputerUse`: skip installing/verifying the local Computer Use compatibility plugin.

## Computer Use Only

To refresh only the local Windows Computer Use files and environment gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1"
```

To verify without changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1" -VerifyOnly
```

## Success Criteria

- `Get-AppxPackage -Name OpenAI.Codex` shows `SignatureKind = Developer`.
- Codex Desktop processes stay alive from `...\WindowsApps\OpenAI.Codex_<version>...\app\Codex.exe`.
- Fast Mode verification logs `request wire service_tier=priority`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-curated-local]`.
- `$env:USERPROFILE\.codex\config.toml` contains `[plugins."computer-use@openai-bundled"]` with `enabled = true`.
- `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE` is set to `1` for the current user.
- `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\computer-use\latest\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js` exists and can return screen info/screenshot.
- `makeappx.exe` and `signtool.exe` are missing again if SDK cleanup was enabled.
