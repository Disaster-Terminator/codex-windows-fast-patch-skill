param(
  [string]$PackageName = 'OpenAI.Codex'
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-appx-remove-allusers]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
  $argsList = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    "`"$PSCommandPath`"",
    '-PackageName',
    "`"$PackageName`""
  )
  Write-Log "requesting elevation to remove all-users package registrations for $PackageName"
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -Verb RunAs -Wait -PassThru
  exit $proc.ExitCode
}

$packages = @(Get-AppxPackage -Name $PackageName -AllUsers -ErrorAction SilentlyContinue)
if ($packages.Count -eq 0) {
  Write-Log "no all-users package registrations found for $PackageName"
} else {
  foreach ($pkg in $packages) {
    Write-Log "removing package for all users: $($pkg.PackageFullName)"
    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
  }
}

$provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $PackageName })
if ($provisioned.Count -eq 0) {
  Write-Log "no provisioned package found for $PackageName"
} else {
  foreach ($pkg in $provisioned) {
    Write-Log "removing provisioned package: $($pkg.PackageName)"
    Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
  }
}
