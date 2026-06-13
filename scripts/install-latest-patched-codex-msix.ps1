param(
  [string]$RepackRoot = (Join-Path $env:USERPROFILE 'Downloads\codex-msix-repack'),
  [string]$PackageName = 'OpenAI.Codex',
  [switch]$TrustRootForAppxInstallRecovery
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-msix-install-latest]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Fail {
  param([string]$Message)
  throw "$LogPrefix error: $Message"
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

$msix = Get-ChildItem -LiteralPath $RepackRoot -Recurse -Filter '*_patched.msix' -File -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $msix) {
  Fail "no patched MSIX found under $RepackRoot"
}

Write-Log "installing latest patched MSIX: $($msix.FullName)"
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($msix.FullName)
if (-not $cert.Subject) {
  Fail "could not read signing certificate from $($msix.FullName)"
}
Write-Log "MSIX signer: $($cert.Subject) / $($cert.Thumbprint)"

Add-CertificateToStore $cert ([System.Security.Cryptography.X509Certificates.StoreName]::TrustedPeople) ([System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
if ($TrustRootForAppxInstallRecovery) {
  Write-Log 'warning: trusting MSIX signer in CurrentUser\Root for Appx install recovery'
  Add-CertificateToStore $cert ([System.Security.Cryptography.X509Certificates.StoreName]::Root) ([System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
}

Add-AppxPackage -Path $msix.FullName -ErrorAction Stop

$pkg = Get-AppxPackage -Name $PackageName | Select-Object -First 1
if (-not $pkg) {
  Fail "$PackageName is still not installed after Add-AppxPackage"
}
Write-Log "installed package: $($pkg.PackageFullName)"
Write-Log "signature kind: $($pkg.SignatureKind)"
