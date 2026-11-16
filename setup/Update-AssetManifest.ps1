#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$files = @(
    Get-ChildItem -LiteralPath $repoRoot -File | Where-Object { $_.Extension -in @('.html', '.css', '.png') -and $_.Name -notin @('obs-installed.png', 'twitch-updated.png') }
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'browser'), (Join-Path $repoRoot 'media') -File -Recurse
) | Sort-Object FullName
# Match the LF text checkout mandated by .gitattributes on every machine.
foreach ($file in $files) {
    if ($file.Extension -in @('.html', '.css', '.js')) {
        $text = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n").Replace("`r", "`n")
        [IO.File]::WriteAllText($file.FullName, $text, (New-Object Text.UTF8Encoding($false)))
    }
}
$entries = @($files | ForEach-Object {
    [ordered]@{ path=$_.FullName.Substring($repoRoot.Length + 1).Replace('\', '/'); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$json = [ordered]@{version=1; files=$entries} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $repoRoot 'obs\asset-manifest.json'), $json + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Updated manifest: $($entries.Count) assets."
