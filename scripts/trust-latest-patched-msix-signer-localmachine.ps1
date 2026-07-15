param(
  [string]$RepackRoot = (Join-Path $env:USERPROFILE 'Downloads\codex-msix-repack'),
  [switch]$TrustRootForAppxInstallRecovery
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-msix-trust-signer]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Fail {
  param([string]$Message)
  throw "$LogPrefix error: $Message"
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-CertificateToStore {
  param(
    [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
    [System.Security.Cryptography.X509Certificates.StoreName]$StoreName,
    [System.Security.Cryptography.X509Certificates.StoreLocation]$StoreLocation
  )
  $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($StoreName, $StoreLocation)
  try {
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $existing = @($store.Certificates | Where-Object { $_.Thumbprint -eq $Cert.Thumbprint })
    if ($existing.Count -eq 0) {
      $store.Add($Cert)
      Write-Log "trusted certificate in ${StoreLocation}\${StoreName}: $($Cert.Thumbprint)"
    } else {
      Write-Log "certificate already trusted in ${StoreLocation}\${StoreName}: $($Cert.Thumbprint)"
    }
  } finally {
    $store.Close()
  }
}

if (-not (Test-IsAdministrator)) {
  $argsList = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    "`"$PSCommandPath`"",
    '-RepackRoot',
    "`"$RepackRoot`""
  )
  if ($TrustRootForAppxInstallRecovery) {
    $argsList += '-TrustRootForAppxInstallRecovery'
  }
  Write-Log 'requesting elevation to trust MSIX signer in LocalMachine stores'
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -Verb RunAs -Wait -PassThru
  exit $proc.ExitCode
}

$msix = Get-ChildItem -LiteralPath $RepackRoot -Recurse -Filter '*_patched.msix' -File -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $msix) {
  Fail "no patched MSIX found under $RepackRoot"
}

$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($msix.FullName)
Write-Log "MSIX signer: $($cert.Subject) / $($cert.Thumbprint)"

Add-CertificateToStore $cert ([System.Security.Cryptography.X509Certificates.StoreName]::TrustedPeople) ([System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
if ($TrustRootForAppxInstallRecovery) {
  Write-Log 'warning: trusting MSIX signer in LocalMachine\Root for Appx install recovery'
  Add-CertificateToStore $cert ([System.Security.Cryptography.X509Certificates.StoreName]::Root) ([System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
}
