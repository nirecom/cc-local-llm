# lm-eval.ps1 - Install lm-evaluation-harness (EleutherAI) for benchmark runs.
# Used by IFEval / MMLU-Pro / GPQA via the local OpenAI-compatible endpoint.

$ErrorActionPreference = "Stop"

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "uv not found -- install uv first (https://docs.astral.sh/uv/)." -ForegroundColor Yellow
    exit 1
}

Write-Host "Installing lm-evaluation-harness..."
uv tool install --force "lm_eval[api]"
if ($LASTEXITCODE -ne 0) {
    Write-Host "lm-evaluation-harness installation failed (exit $LASTEXITCODE)." -ForegroundColor Yellow
    exit 1
}

$ver = lm_eval --version 2>&1 | Select-Object -First 1
Write-Host "lm-evaluation-harness installed: $ver" -ForegroundColor Green
