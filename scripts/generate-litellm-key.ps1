# Generate a cryptographically random 32-byte key and output as lowercase hex.
# Called by setup-litellm.cmd via: powershell -NoProfile -File generate-litellm-key.ps1 -OutFile <path>
# -OutFile writes ASCII directly to avoid cmd.exe stdout redirect producing UTF-16 BOM (breaks set /p).
# Works on PowerShell 5.1 and PowerShell 7+.
param([string]$OutFile = "")
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 32
$rng.GetBytes($bytes)
$hex = [System.BitConverter]::ToString($bytes).Replace('-', '').ToLower()
if ($OutFile) {
    [System.IO.File]::WriteAllText($OutFile, $hex, [System.Text.Encoding]::ASCII)
} else {
    Write-Output $hex
}
