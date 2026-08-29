# cc-local-llm installer for Windows.
#
# Two roles. The client role installs the prerequisites this host needs to TALK to a
# gateway; the server role registers the llama-swap + Caddy services that SERVE one.
# No switch means -Client, preserving the one-word `.\install.ps1` Windows client users
# already have in their notes -- install.sh defaults to all instead, and that asymmetry
# is deliberate: on macOS the same machine is normally both.
#
# Usage: .\install.ps1 [-Client | -Server | -All] [-LanIp <ipv4>]
#        .\install.ps1 -Server -Uninstall

param(
    [switch]$Server,
    [switch]$Client,
    [switch]$All,
    [switch]$Uninstall,
    [ValidatePattern('^$|^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$')]
    [string]$LanIp = ''
)

if ($IsWindows -eq $false) {
    Write-Host "Error: install.ps1 must not run on Linux/macOS. Use install.sh instead." -ForegroundColor Red
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$RepoRoot = $PSScriptRoot

. "$RepoRoot\install\win\lib\roles.ps1"
$Role = Resolve-InstallRole -Server:$Server -Client:$Client -All:$All -Uninstall:$Uninstall

# Server-role path literals live here and nowhere else; docs/infrastructure.md mirrors
# them on its '<!-- synced-from: install.ps1 -->' lines rather than restating them.
$CertDir = 'C:\LLM\certs\llama-swap'
$RuntimeDir = 'C:\LLM\llama-swap'
$ConfigPath = "$RepoRoot\llama-swap\rtx5070ti-128gb\config.yaml"

function Get-LanIPv4 {
    # The address a LAN client dials, which is the one that must be in the certificate.
    # Ordered by interface metric so the primary NIC wins on a host with several.
    $candidates = @(Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
        ForEach-Object { $_.IPv4Address.IPAddress } |
        Where-Object { $_ -and $_ -ne '127.0.0.1' })

    if ($candidates.Count -eq 0) {
        throw "Could not determine this host's LAN IPv4 address. Pass it explicitly: .\install.ps1 -Server -LanIp <address>."
    }
    return $candidates[0]
}

function Install-ClientRole {
    Write-Host ""
    Write-Host "--- Retiring obsolete Windows-side LiteLLM artifacts ---"
    & "$RepoRoot\install\win\uninstall-obsolete.ps1"

    Write-Host ""
    Write-Host "--- Installing mkcert ---"
    & "$RepoRoot\install\win\mkcert.ps1"

    Write-Host ""
    Write-Host "--- Setting up .env ---"
    $EnvPath = "$RepoRoot\.env"
    if (Test-Path $EnvPath) {
        Write-Host ".env already exists -- leaving it as-is." -ForegroundColor DarkGray
    } else {
        Copy-Item "$RepoRoot\.env.example" $EnvPath
        Write-Host "Created .env from .env.example -- fill in LITELLM_ANTHROPIC_BASE_URL / LITELLM_CLIENT_KEY / CCGW_CA_CERT." -ForegroundColor Green
    }
}

function Install-ServerRole {
    $address = if ($LanIp) { $LanIp } else { Get-LanIPv4 }
    if ($address -notmatch '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$') {
        throw "-LanIp '$LanIp' is not an IPv4 address. It is baked into the certificate SAN list, where a typo only surfaces days later as a client that silently refuses the connection."
    }

    Write-Host ""
    Write-Host "--- Installing nssm ---"
    & "$RepoRoot\install\win\nssm.ps1"

    Write-Host ""
    Write-Host "--- Installing caddy ---"
    & "$RepoRoot\install\win\caddy.ps1"

    Write-Host ""
    Write-Host "--- Installing mkcert ---"
    & "$RepoRoot\install\win\mkcert.ps1"

    Write-Host ""
    Write-Host "--- Provisioning certificates ($CertDir) ---"
    & "$RepoRoot\install\win\certs.ps1" -CertDir $CertDir -SanNames @('localhost', '127.0.0.1', $address)

    Write-Host ""
    Write-Host "--- Registering the llama-swap and Caddy services ---"
    & "$RepoRoot\install\win\llama-swap-service.ps1" -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -CertDir $CertDir
}

function Uninstall-ServerRole {
    Write-Host ""
    Write-Host "--- Removing the Caddy and llama-swap services ---"
    & "$RepoRoot\install\win\llama-swap-service.ps1" -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -CertDir $CertDir -Uninstall
}

Write-Host "=== cc-local-llm installer (Windows, $Role$(if ($Uninstall) { ', uninstall' })) ===" -ForegroundColor Cyan

if ($Uninstall) {
    Uninstall-ServerRole
    Write-Host ""
    Write-Host "=== Done ===" -ForegroundColor Cyan
    Write-Host "The certificates in $CertDir and the runtime files in $RuntimeDir were left in place;"
    Write-Host "delete them by hand if this host is no longer serving models."
    return
}

# -All is client-then-server: the server role reuses mkcert, which the client role
# installs, and an operator watching the output sees the cheap half succeed first.
if ($Role -eq 'client' -or $Role -eq 'all') { Install-ClientRole }
if ($Role -eq 'server' -or $Role -eq 'all') { Install-ServerRole }

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
if ($Role -eq 'client' -or $Role -eq 'all') {
    Write-Host "Remaining client steps are interactive (trusting the Mac's root CA, filling in the gateway key)"
    Write-Host "and are documented in docs/ops.md#client-windows."
}
