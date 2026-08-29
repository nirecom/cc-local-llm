# certs.ps1 - provision the TLS pair Caddy serves on every front-end port.
#
# The three states are handled separately on purpose (CPR-SC): a pair that already
# exists is left untouched, because regenerating it would silently invalidate the
# copy every LAN client has already trusted; a HALF pair is refused rather than
# completed, because guessing which half is authoritative is how a cert and a key
# from two different CAs end up beside each other.

param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CertDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$SanNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:SYSTEM_OPS_APPROVED = '1'

. "$PSScriptRoot\lib\native.ps1"

$ipv4 = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
$names = @($SanNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($names.Count -eq 0) {
    throw "-SanNames is empty; mkcert would produce a certificate valid for nothing."
}
if (-not (@($names | Where-Object { $_ -match $ipv4 }).Count)) {
    throw "-SanNames ($($names -join ', ')) contains no IPv4 address. LAN clients reach this host by address, so a certificate without one is rejected by every one of them."
}

$certPath = Join-Path $CertDir 'cert.pem'
$keyPath  = Join-Path $CertDir 'key.pem'
$hasCert  = Test-Path -LiteralPath $certPath -PathType Leaf
$hasKey   = Test-Path -LiteralPath $keyPath  -PathType Leaf

if ($hasCert -and $hasKey) {
    foreach ($p in @($certPath, $keyPath)) {
        if ((Get-Item -LiteralPath $p).Length -le 0) {
            throw "$p exists but is empty. Delete both $certPath and $keyPath, then re-run .\install.ps1 -Server."
        }
        if (-not ((Get-Content -LiteralPath $p -TotalCount 1) -match '^-----BEGIN ')) {
            throw "$p is not PEM-encoded. Delete both $certPath and $keyPath, then re-run .\install.ps1 -Server."
        }
    }
    Write-Host "Certificate pair already present in $CertDir -- leaving it as-is." -ForegroundColor DarkGray
    return
}

if ($hasCert -or $hasKey) {
    $present = if ($hasCert) { $certPath } else { $keyPath }
    $missing = if ($hasCert) { $keyPath } else { $certPath }
    throw "Found $present but not $missing. Refusing to guess: move or delete $present, then re-run .\install.ps1 -Server to generate a matching pair."
}

if (-not (Test-Path -LiteralPath $CertDir)) {
    New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
}

Write-Host "Generating a certificate for: $($names -join ', ')"
$caInstallArgs = @('-install')
$generateArgs  = @('-cert-file', $certPath, '-key-file', $keyPath) + $names
Invoke-Native -FilePath 'mkcert' -Arguments $caInstallArgs -Context 'mkcert local CA installation'
Invoke-Native -FilePath 'mkcert' -Arguments $generateArgs -Context 'mkcert certificate generation'

if (-not ((Test-Path -LiteralPath $certPath -PathType Leaf) -and (Test-Path -LiteralPath $keyPath -PathType Leaf))) {
    throw "mkcert reported success but $certPath / $keyPath were not both written."
}

Write-Host "Certificate written to $certPath" -ForegroundColor Green
