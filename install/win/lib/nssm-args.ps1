# nssm-args.ps1 - the NSSM setting name/value pairs for the two services, as pure data.
#
# Kept apart from llama-swap-service.ps1 so the exact registration a change would produce
# can be asserted without registering anything. Both builders return the same setting
# names (CPR-ORTH): the two services are one class, and a rotation policy that reached
# only one of them is how caddy-stderr.log once grew to 125 MB.
#
# Function definitions only -- see native.ps1 for why.

# One default for both services. Splitting it into two literals is precisely the drift
# the shared-key contract above exists to prevent.
function Get-DefaultLogRotateBytes {
    return 10485760
}

# AppParameters is a single flat string handed to NSSM, which re-splits it on spaces.
# A path containing a space therefore has to arrive quoted -- and a path without one has
# to arrive unquoted, or every existing registration's AppParameters changes shape.
function ConvertTo-NssmArgumentToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

# Mandatory alone still accepts '   ', which would build a service rooted at the
# filesystem root and only fail hours later, at first start.
function Assert-NssmPathArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must be a non-empty path (got '$Value')."
    }
}

# The port in here is the single source for the front-end mapping. NSSM accepts any
# string, so a typo would surface as a service that registers cleanly and never listens.
function Assert-NssmListenAddress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -notmatch '^\S+:\d{1,5}$') {
        throw "ListenAddr must be host:port, e.g. 127.0.0.1:18080 (got '$Value')."
    }
    $port = [int](@($Value -split ':')[-1])
    if ($port -lt 1 -or $port -gt 65535) {
        throw "ListenAddr port must be between 1 and 65535 (got '$Value')."
    }
}

# AppRotateOnline matters as much as AppRotateFiles here: both services are resident, so
# without it nothing rotates until the next reboot.
function Add-NssmLogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][int]$LogRotateBytes
    )

    $Settings['AppRotateFiles']  = 1
    $Settings['AppRotateOnline'] = 1
    $Settings['AppRotateBytes']  = $LogRotateBytes
    $Settings['AppStdoutCreationDisposition'] = 4
    $Settings['AppStderrCreationDisposition'] = 4
}

function Get-LlamaSwapNssmSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuntimeDir,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
        [string]$ListenAddr = '127.0.0.1:18080',
        [ValidateRange(1, 2147483647)][int]$LogRotateBytes = (Get-DefaultLogRotateBytes)
    )

    Assert-NssmPathArgument -Value $RuntimeDir -Name 'RuntimeDir'
    Assert-NssmPathArgument -Value $ConfigPath -Name 'ConfigPath'
    Assert-NssmListenAddress -Value $ListenAddr

    # ConfigPath is the one input that lives outside RuntimeDir: it is the repo's
    # llama-swap/rtx5070ti-128gb/config.yaml, while the exe and the logs stay on the host.
    $settings = [ordered]@{
        Application   = (Join-Path $RuntimeDir 'llama-swap.exe')
        AppParameters = "--config $(ConvertTo-NssmArgumentToken $ConfigPath) --listen $ListenAddr --watch-config"
        AppDirectory  = $RuntimeDir
        Start         = 'SERVICE_AUTO_START'
        DisplayName   = 'llama-swap LLM Model Server'
        Description   = 'LLM model switching server for local inference'
        AppStdout     = (Join-Path $RuntimeDir 'service-stdout.log')
        AppStderr     = (Join-Path $RuntimeDir 'service-stderr.log')
    }
    Add-NssmLogRotation -Settings $settings -LogRotateBytes $LogRotateBytes
    return $settings
}

function Get-CaddyNssmSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuntimeDir,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CaddyExe,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Caddyfile,
        [ValidateRange(1, 2147483647)][int]$LogRotateBytes = (Get-DefaultLogRotateBytes)
    )

    Assert-NssmPathArgument -Value $RuntimeDir -Name 'RuntimeDir'
    Assert-NssmPathArgument -Value $CaddyExe  -Name 'CaddyExe'
    Assert-NssmPathArgument -Value $Caddyfile -Name 'Caddyfile'

    # Caddy fronts far more than llama-swap (Open WebUI, JudgeClaw, LangChain, Langfuse),
    # which is why it runs as its own service with its own log pair rather than sharing.
    $settings = [ordered]@{
        Application   = $CaddyExe
        AppParameters = "run --config $(ConvertTo-NssmArgumentToken $Caddyfile) --adapter caddyfile"
        AppDirectory  = $RuntimeDir
        Start         = 'SERVICE_AUTO_START'
        DisplayName   = 'llama-swap Caddy TLS Proxy'
        Description   = 'TLS reverse proxy for llama-swap and the other local HTTP services'
        AppStdout     = (Join-Path $RuntimeDir 'caddy-stdout.log')
        AppStderr     = (Join-Path $RuntimeDir 'caddy-stderr.log')
    }
    Add-NssmLogRotation -Settings $settings -LogRotateBytes $LogRotateBytes
    return $settings
}
