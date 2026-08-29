# roles.ps1 - which role install.ps1 was asked to install, and whether the ask is coherent.
#
# The role switches are mutually exclusive, the same way install.sh's case statement
# accepts a single token. -Uninstall has exactly one meaningful target, because server
# is the only role that leaves persistent state (two NSSM registrations) behind; every
# other reading of it would be a guess at a destructive operation, so it is refused.
#
# Function definitions only -- see native.ps1 for why.

function Resolve-InstallRole {
    [CmdletBinding()]
    param(
        [switch]$Server,
        [switch]$Client,
        [switch]$All,
        [switch]$Uninstall
    )

    $picked = @()
    if ($Server) { $picked += 'server' }
    if ($Client) { $picked += 'client' }
    if ($All)    { $picked += 'all' }

    if ($picked.Count -gt 1) {
        throw "Choose one role: -Server, -Client or -All (got $($picked -join ' + ')). -All already runs the client role before the server role."
    }

    # No role switch means client, preserving the one-word `.\install.ps1` that Windows
    # client users already have in their notes. macOS defaults to all instead; the
    # asymmetry is deliberate and is named in install.ps1's header.
    $role = if ($picked.Count -eq 1) { $picked[0] } else { 'client' }

    if ($Uninstall -and $role -ne 'server') {
        throw "-Uninstall is only defined for the server role; use: .\install.ps1 -Server -Uninstall. The client role installs no service and leaves nothing to remove, and the reverse of -All is not a single well-defined operation."
    }

    return $role
}
