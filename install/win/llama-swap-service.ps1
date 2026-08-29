# llama-swap-service.ps1 - register (or remove) the llama-swap and Caddy NSSM services.
#
# RuntimeDir / ConfigPath / CertDir are explicit and Mandatory because the three used to
# be one assumption: config.yaml living beside llama-swap.exe. It no longer does -- the
# config is a checked-out file and the certificates are host state -- so a default here
# would quietly re-create the assumption it replaced.
#
# Every precondition is checked before the first registration: a service that installs
# and then fails to start leaves an operator with two half-states to unpick instead of
# one clear message.

param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuntimeDir,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CertDir,
    [ValidateNotNullOrEmpty()][string]$CaddyfileTemplate = "$PSScriptRoot\Caddyfile.template",
    [ValidateNotNullOrEmpty()][string]$ListenAddr = '127.0.0.1:18080',
    [ValidateRange(1, 2147483647)][int]$LogRotateBytes = 0,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:SYSTEM_OPS_APPROVED = '1'

. "$PSScriptRoot\lib\native.ps1"
. "$PSScriptRoot\lib\nssm-args.ps1"

# ValidateRange rejects an explicit 0; an unbound parameter never reaches it, so the
# untouched default is where the shared SSOT value is picked up.
if ($LogRotateBytes -le 0) { $LogRotateBytes = Get-DefaultLogRotateBytes }

$CaddyfilePath = Join-Path $RuntimeDir 'Caddyfile'
$ListenPort    = [int](@($ListenAddr -split ':')[-1])

function Get-CaddyFrontPorts {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Select-String -LiteralPath $Path -Pattern '^\s*:(\d+)\s*\{' |
        ForEach-Object { [int]$_.Matches[0].Groups[1].Value })
}

function Test-ScmRegistration {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$QueryOutput)

    return (@($QueryOutput | Where-Object { "$_" -match 'SERVICE_NAME|STATE' }).Count -gt 0)
}

function Register-NssmService {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Settings
    )

    # Get-Service is a cmdlet, so it reports absence without an exit code -- which is
    # why no nssm call site in this file needs a non-zero code blessed.
    $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Reconfiguring existing service '$Name'..."
        if ($existing.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force
            (Get-Service -Name $Name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
    } else {
        Write-Host "Installing service '$Name'..."
        Invoke-Nssm -Arguments @('install', $Name, $Settings['Application']) -Context "nssm install of '$Name'"
    }

    foreach ($key in @($Settings.Keys)) {
        $setArgs = @('set', $Name, $key, "$($Settings[$key])")
        Invoke-Nssm -Arguments $setArgs -Context "nssm set of $Name $key"
    }

    Start-Service -Name $Name
    (Get-Service -Name $Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
}

function Remove-NssmService {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
    Write-Host "Removing service '$Name'..."
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    Invoke-Nssm -Arguments @('remove', $Name, 'confirm') -Context "nssm remove of '$Name'"
}

function Remove-PortZombie {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string[]]$ExpectedImagePaths
    )

    # A process that outlived its service keeps the port, and the next start then fails
    # with a bind error that names nothing. Get-NetTCPConnection answers "who holds it",
    # which an exit code from a listing tool cannot: no match and never looked both exit 0.
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $ownerPid = [int]$listener.OwningProcess
        if ($ownerPid -le 4) { continue }

        # The port is the symptom, not the identity: anything else may have taken it in
        # the meantime, so only our own two images are killable and unknown never matches.
        $image = $null
        try {
            $owner = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            if ($owner) { $image = $owner.Path }
        } catch {
            $image = $null
        }
        if ((-not $image) -or ($ExpectedImagePaths -notcontains $image)) {
            $shown = if ($image) { $image } else { 'unknown' }
            Write-Warning "PID $ownerPid ($shown) is listening on :$Port but is neither llama-swap nor Caddy; leaving it running, so :$Port stays bound."
            continue
        }

        Write-Host "Killing leftover process $ownerPid still listening on :$Port"
        Invoke-Native -FilePath 'taskkill' -Arguments @('/f', '/pid', "$ownerPid") `
            -AllowExitCodes 128 -Context "taskkill of the process holding :$Port"
    }
}

if ($Uninstall) {
    # Caddy first: it is the front end, so removing it stops new traffic reaching a
    # llama-swap that is about to disappear.
    Remove-NssmService -Name 'llama-swap-caddy'
    Remove-NssmService -Name 'llama-swap'

    # The SCM addresses a service by name, so each sweep is spelled out rather than
    # looped: 1060 ("no such service") is the answer both calls are hoping for.
    $caddyGhost = @(Invoke-Native -FilePath 'sc.exe' -Arguments @('query', 'llama-swap-caddy') `
        -AllowExitCodes 1060 -Context "SCM registration check for 'llama-swap-caddy'" -PassThru)
    if (Test-ScmRegistration -QueryOutput $caddyGhost) {
        Invoke-Native -FilePath 'sc.exe' -Arguments @('delete', 'llama-swap-caddy') `
            -AllowExitCodes 1060 -Context "sc delete of 'llama-swap-caddy'"
    }

    $swapGhost = @(Invoke-Native -FilePath 'sc.exe' -Arguments @('query', 'llama-swap') `
        -AllowExitCodes 1060 -Context "SCM registration check for 'llama-swap'" -PassThru)
    if (Test-ScmRegistration -QueryOutput $swapGhost) {
        Invoke-Native -FilePath 'sc.exe' -Arguments @('delete', 'llama-swap') `
            -AllowExitCodes 1060 -Context "sc delete of 'llama-swap'"
    }

    $exePath  = Join-Path $RuntimeDir 'llama-swap.exe'
    $caddyCmd = Get-Command caddy -ErrorAction SilentlyContinue
    $killable = @($exePath)
    if ($caddyCmd) { $killable += $caddyCmd.Source }

    foreach ($port in (@($ListenPort) + (Get-CaddyFrontPorts -Path $CaddyfilePath))) {
        Remove-PortZombie -Port $port -ExpectedImagePaths $killable
    }

    foreach ($name in @('llama-swap', 'llama-swap-caddy')) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            Write-Warning "'$name' is still registered. An open Services.msc or Event Viewer window keeps the handle alive; close it and reboot to complete the delete."
        }
    }

    Write-Host "Both services removed." -ForegroundColor Green
    return
}

$exePath  = Join-Path $RuntimeDir 'llama-swap.exe'
$certPath = Join-Path $CertDir 'cert.pem'
$keyPath  = Join-Path $CertDir 'key.pem'

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "llama-swap.exe not found at $exePath. Download the Windows release into $RuntimeDir, then re-run .\install.ps1 -Server."
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "config.yaml not found at $ConfigPath. The config lives in the checkout, not beside the exe."
}
foreach ($pem in @($certPath, $keyPath)) {
    if (-not (Test-Path -LiteralPath $pem -PathType Leaf)) {
        throw "$pem not found. Run install/win/certs.ps1 (install.ps1 -Server does this) before registering the services."
    }
}
if (-not (Test-Path -LiteralPath $CaddyfileTemplate -PathType Leaf)) {
    throw "Caddyfile template not found at $CaddyfileTemplate."
}
$caddyCommand = Get-Command caddy -ErrorAction SilentlyContinue
if (-not $caddyCommand) {
    throw "caddy is not on PATH. Run install/win/caddy.ps1 first, then open a new shell."
}

$rendered = (Get-Content -LiteralPath $CaddyfileTemplate -Raw).Replace('{{CERT_DIR}}', $CertDir)
if ($rendered -match '\{\{[A-Za-z0-9_]+\}\}') {
    throw "$CaddyfileTemplate carries a placeholder this script does not substitute; caddy would receive it verbatim."
}
Set-Content -LiteralPath $CaddyfilePath -Value $rendered -Encoding utf8
Write-Host "Wrote $CaddyfilePath"

Register-NssmService -Name 'llama-swap' -Settings (
    Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath `
        -ListenAddr $ListenAddr -LogRotateBytes $LogRotateBytes)

Register-NssmService -Name 'llama-swap-caddy' -Settings (
    Get-CaddyNssmSettings -RuntimeDir $RuntimeDir -CaddyExe $caddyCommand.Source `
        -Caddyfile $CaddyfilePath -LogRotateBytes $LogRotateBytes)

foreach ($name in @('llama-swap', 'llama-swap-caddy')) {
    $status = (Get-Service -Name $name).Status
    if ($status -ne 'Running') {
        throw "'$name' registered but is $status. Check $RuntimeDir for its *-stderr.log."
    }
}

# A running service that never bound its port is the failure mode NSSM hides: the
# process restarts on a loop while the service still reports Running.
foreach ($port in (@($ListenPort) + (Get-CaddyFrontPorts -Path $CaddyfilePath))) {
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) {
            throw "Nothing is listening on :$port after 30s. Check $RuntimeDir for the service logs."
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "  ok: listening on :$port" -ForegroundColor DarkGray
}

Write-Host "llama-swap and Caddy are registered and running." -ForegroundColor Green
