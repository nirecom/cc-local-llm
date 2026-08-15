# Generate a cryptographically random 32-byte key and output as lowercase hex.
# Called by setup-litellm.ps1, which reads the hex straight off stdout.
# -OutFile writes ASCII to a file instead, for callers outside PowerShell whose stdout
# redirect would otherwise produce a UTF-16 BOM.
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
