---
name: codex-windows-fast-patch
description: Reapply the Windows Codex Desktop MSIX patch after Store upgrades, including Fast Mode, plugin UI gates, Goal command gates, Windows Computer Use availability gates, ASAR integrity repair, signing/installing the patched package, SDK cleanup, Fast Mode wire verification, and registering the local plugin marketplace openai-curated-local.
---

# Codex Windows Fast Patch

Use this skill when the user says Codex Desktop was upgraded and the Fast Mode / Plugins / Goal patch disappeared, asks to repatch Codex on Windows, asks to verify whether Fast Mode is really being sent, asks to restore/register the local plugin marketplace, or asks to enable Windows Computer Use in Codex Desktop. Also use it when the Computer Control settings page shows "Any App" / "任意应用" as disabled by organization or unavailable in the current region.

## Platform Compatibility

This skill is Windows-only. It depends on the Windows Store/MSIX package layout, PowerShell, `Get-AppxPackage`, `makeappx.exe`, `signtool.exe`, Windows user environment variables, and Windows Computer Use helper paths.

Do not run this skill on macOS. A macOS adaptation needs a separate workflow for the Codex `.app` bundle, ASAR extraction and repacking, macOS code signing or quarantine handling, shell scripts, and macOS-specific Computer Use availability.

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

It also verifies and writes the local marketplace config at `$env:USERPROFILE\.codex\marketplaces\openai-curated-local`, including `source_type = "local"` and the exact `source` path.
It also syncs the installed `openai-bundled` marketplace from the current Codex package into `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled`, overlays a local `computer-use@openai-bundled` compatibility plugin, writes that local marketplace into config, and enables `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1` for the current user so the Desktop app can expose Windows Computer Use after restart.
It also patches the Desktop webview gates that otherwise hide or disable Windows Computer Use behind the `computer_use` experimental feature and Statsig gate `1506311413`, and it writes `features.computer_use = true` into `$env:USERPROFILE\.codex\config.toml` without replacing the rest of the `[features]` table.
It also repairs local marketplace manifest layout when a local root has only a legacy root `marketplace.json`; the current Codex CLI expects `.agents\plugins\marketplace.json`, and missing that file can make `codex plugin list` fail for all configured marketplaces.

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
- If `codex plugin list` fails with `failed to load configured marketplace snapshot(s)` and a local marketplace root contains only `marketplace.json`, copy that manifest to `.agents\plugins\marketplace.json` and re-run `codex plugin list` before diagnosing individual plugins.
- Do not depend on `Downloads\patch_codex_fast_mode_windows_msix.ps1`; the skill is intended to be self-contained. Use `scripts\patch_codex_fast_mode_windows_msix.ps1` unless the user explicitly passes `-PatchScript`.
- Do not modify `C:\Program Files\WindowsApps` in place to enable Computer Use. The Windows gate is controlled by `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1`, and the helper paths are supplied through the local `computer-use@openai-bundled` plugin.
- If "任意应用" is visible but disabled as organization/region unavailable, inspect `webview\assets\use-is-plugins-enabled-*.js` in the extracted ASAR. The relevant local gates are `featureName:\`computer_use\`` and Statsig `1506311413`; reapply the MSIX patch rather than editing WindowsApps in place.

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

To verify and automatically repair missing local Computer Use files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1" -VerifyOnly
```

To verify without changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\install-computer-use-local.ps1" -StrictVerifyOnly
```

## Success Criteria

- `Get-AppxPackage -Name OpenAI.Codex` shows `SignatureKind = Developer`.
- Codex Desktop processes stay alive from `...\WindowsApps\OpenAI.Codex_<version>...\app\Codex.exe`.
- Fast Mode verification logs `request wire service_tier=priority`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-curated-local]`.
- `$env:USERPROFILE\.codex\config.toml` contains `[marketplaces.openai-bundled]` pointing at `$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled`, and that local mirror contains the installed bundled plugins plus `computer-use`.
- Any configured local marketplace used for personal plugins has a supported `.agents\plugins\marketplace.json`; root-level `marketplace.json` alone is not enough for the current plugin CLI.
- `$env:USERPROFILE\.codex\config.toml` contains `[plugins."computer-use@openai-bundled"]` with `enabled = true`.
- `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE` is set to `1` for the current user.
- `$env:USERPROFILE\.codex\config.toml` contains `[features]` with `computer_use = true`.
- `$env:USERPROFILE\.codex\plugins\cache\openai-bundled\computer-use\latest\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js` exists and can return screen info/screenshot.
- The patched ASAR has `webview\assets\use-is-plugins-enabled-*.js` with the Computer Use availability gate forced local-available and `webview\assets\use-plugin-install-flow-*.js` with the Computer Use install gate unblocked.
- `makeappx.exe` and `signtool.exe` are missing again if SDK cleanup was enabled.
