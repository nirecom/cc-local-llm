# uninstall-obsolete.ps1 - Retire Windows-side LiteLLM artifacts (Windows)
# The LiteLLM gateway now runs natively on the Mac (#41); this host previously
# ran it itself via Docker Desktop, from a Compose stack that has since been
# removed. Usage: called by install.ps1 (always, not only -Full).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Remove the obsolete ccgw-litellm / ccgw-postgres containers ---
if (Get-Command docker -ErrorAction SilentlyContinue) {
    foreach ($name in @("ccgw-litellm", "ccgw-postgres")) {
        $exists = docker container inspect $name 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Removing obsolete container: $name (LiteLLM now runs on the Mac)" -ForegroundColor Yellow
            docker container rm -f $name 2>$null | Out-Null
        }
    }

    # --- Remove the obsolete litellm-postgres volume (project name: ccgw) ---
    $volName = "ccgw_litellm-postgres"
    $volExists = docker volume inspect $volName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Removing obsolete volume: $volName (LiteLLM key store now lives on the Mac)" -ForegroundColor Yellow
        docker volume rm $volName 2>$null | Out-Null
    }
} else {
    Write-Host "docker not found -- skipping obsolete ccgw-litellm/ccgw-postgres cleanup." -ForegroundColor DarkGray
}
