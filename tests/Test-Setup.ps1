#Requires -Version 5.1
[CmdletBinding()]
param([string]$TestRoot = (Join-Path $env:TEMP ('terminal-lab-test-' + [guid]::NewGuid().ToString('N'))))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testBase = [IO.Path]::GetFullPath($TestRoot)
$install = Join-Path $testBase ('fresh user ' + [char]0x03A9 + ' & spaces')
$scenePath = Join-Path $install 'roaming\obs-studio\basic\scenes\itzmaniss-terminal-lab.json'
$profileRoot = Join-Path $install 'roaming\obs-studio\basic\profiles\itzmaniss-terminal-lab'
$assets = Join-Path $install 'local\itzmaniss-stream\terminal-lab'
$utf8 = New-Object Text.UTF8Encoding($false)
$passed = 0

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Put([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Run-Setup([string]$Root, [string]$Target, [string]$Encoder = 'Software') {
    $output = & $psExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'setup\Install-TerminalLab.ps1') -TestRoot $Target -Encoder $Encoder 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Host ($output -join "`n") }
    return $code
}

# Fresh-user restore with spaces and shell metacharacters in the location.
Assert ((Run-Setup $repoRoot $install) -eq 0) 'fresh restore completes in Windows PowerShell 5.1'
$collection = Get-Content -Raw -Encoding UTF8 -LiteralPath $scenePath | ConvertFrom-Json
Assert (@($collection.scene_order).Count -eq 13) 'all 13 scene layouts restore'
Assert ($collection.current_scene -eq $collection.scene_order[0].name) 'restores to Starting Soon'
$uuids = @($collection.sources.uuid)
$references = @($collection.sources | Where-Object { $_.id -eq 'scene' } | ForEach-Object { $_.settings.items.source_uuid })
Assert (@($references | Where-Object { $_ -notin $uuids }).Count -eq 0) 'all scene items reference restored sources'
$paths = @($collection.sources | ForEach-Object {
    foreach ($key in @('file','local_file')) { if ($_.settings.PSObject.Properties[$key] -and $_.settings.$key) { $_.settings.$key } }
}) + @($collection.transitions | ForEach-Object { $_.settings.path })
Assert (@($paths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) 'every source and transition asset exists'
Assert (@($paths | Where-Object { -not ([IO.Path]::GetFullPath($_)).StartsWith($assets + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) 'all asset paths point into the installed asset folder'
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'obs\asset-manifest.json') | ConvertFrom-Json
Assert (@(Get-ChildItem -LiteralPath $assets -Recurse -File).Count -eq @($manifest.files).Count) 'copies the complete asset allowlist'
$sceneText = Get-Content -Raw -Encoding UTF8 -LiteralPath $scenePath
Assert (-not $sceneText.Contains('__TERMINAL_LAB_ASSETS__') -and -not $sceneText.Contains($repoRoot.Replace('\','/'))) 'replaces template paths with the new Windows-user location'
$ini = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $profileRoot 'basic.ini')
Assert ($ini.Contains('FPSCommon=60') -and $ini.Contains('BaseCX=1920') -and $ini.Contains('SampleRate=48000')) 'restores 1080p60 and 48 kHz audio'
Assert ($ini.Contains('Encoder=obs_x264') -and $ini.Contains('RecTracks=31') -and $ini.Contains('VodTrackIndex=6')) 'software fallback retains recording tracks and VOD mix'
$service = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'service.json') | ConvertFrom-Json
Assert ($service.settings.key -eq '') 'fresh setup contains no Twitch stream key'
$alerts = @($collection.sources | Where-Object { $_.name -like 'Alerts*' })[0]
$camera = @($collection.sources | Where-Object { $_.id -eq 'dshow_input' })[0]
Assert ($alerts.settings.url -eq 'about:blank' -and $camera.mixers -eq 0) 'private alerts stay blank and camera audio stays muted'

# Simulate an existing setup with local-only preferences and account configuration.
$alerts.settings.url = 'https://example.invalid/local-alert-preference'
$camera.settings | Add-Member -MemberType NoteProperty -Name video_device_id -Value 'TEST-LOCAL-CAMERA'
$mic = @($collection.sources | Where-Object { $_.id -eq 'wasapi_input_capture' })[0]
$mic.settings.device_id = 'TEST-LOCAL-MIC'
Put $scenePath ($collection | ConvertTo-Json -Depth 100)
Put (Join-Path $profileRoot 'basic.ini') ($ini + "`r`n[Twitch]`r`nAccountName=local-test-account`r`n[Auth]`r`nType=Twitch`r`n")
Put (Join-Path $profileRoot 'service.json') '{"type":"rtmp_common","settings":{"service":"Twitch","server":"auto","key":"LOCAL-TEST-ONLY"}}'
$unrelated = Join-Path $install 'roaming\obs-studio\basic\profiles\other-profile\basic.ini'
$userIni = Join-Path $install 'roaming\obs-studio\user.ini'
Put $unrelated 'DO NOT CHANGE THIS PROFILE'
Put $userIni 'DO NOT CHANGE GLOBAL OBS PREFERENCES'
$originalSceneHash = (Get-FileHash -LiteralPath $scenePath).Hash
Assert ((Run-Setup $repoRoot $install 'Nvidia') -eq 0) 'repeat restore completes with the NVIDIA profile'
$restored = Get-Content -Raw -Encoding UTF8 -LiteralPath $scenePath | ConvertFrom-Json
Assert (@($restored.sources | Where-Object { $_.name -like 'Alerts*' })[0].settings.url -eq $alerts.settings.url) 'preserves the existing local alert URL'
Assert (@($restored.sources | Where-Object { $_.id -eq 'dshow_input' })[0].settings.video_device_id -eq 'TEST-LOCAL-CAMERA') 'preserves the existing camera selection'
Assert (@($restored.sources | Where-Object { $_.id -eq 'wasapi_input_capture' })[0].settings.device_id -eq 'TEST-LOCAL-MIC') 'preserves the existing microphone selection'
$afterIni = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $profileRoot 'basic.ini')
Assert ($afterIni.Contains('AccountName=local-test-account') -and $afterIni.Contains('Encoder=obs_nvenc_h264_tex')) 'preserves account settings while applying the output profile'
Assert ((Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'service.json') | ConvertFrom-Json).settings.key -eq 'LOCAL-TEST-ONLY') 'preserves the existing local service configuration'
Assert ((Get-Content -Raw -LiteralPath $unrelated) -eq 'DO NOT CHANGE THIS PROFILE' -and (Get-Content -Raw -LiteralPath $userIni) -eq 'DO NOT CHANGE GLOBAL OBS PREFERENCES') 'leaves other profiles and global preferences untouched'
$backups = @(Get-ChildItem -LiteralPath (Join-Path $install 'local\itzmaniss-stream\backups') -Directory)
Assert ($backups.Count -eq 1 -and (Get-FileHash -LiteralPath (Join-Path $backups[0].FullName 'itzmaniss-terminal-lab.json')).Hash -eq $originalSceneHash) 'backs up the exact previous scene collection before updating'
$recordEncoder = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'recordEncoder.json') | ConvertFrom-Json
Assert ($recordEncoder.rate_control -eq 'CQP' -and $recordEncoder.cqp -eq 20) 'NVIDIA recording uses CQP 20'

# A corrupt/incomplete download must fail before changing a working setup.
$brokenRepo = Join-Path $testBase 'incomplete download'
[void][IO.Directory]::CreateDirectory((Join-Path $brokenRepo 'setup'))
[void][IO.Directory]::CreateDirectory((Join-Path $brokenRepo 'obs'))
Copy-Item -LiteralPath (Join-Path $repoRoot 'setup\Install-TerminalLab.ps1') -Destination (Join-Path $brokenRepo 'setup\Install-TerminalLab.ps1')
Copy-Item -LiteralPath (Join-Path $repoRoot 'obs\asset-manifest.json') -Destination (Join-Path $brokenRepo 'obs\asset-manifest.json')
$beforeFailure = (Get-FileHash -LiteralPath $scenePath).Hash
Assert ((Run-Setup $brokenRepo $install) -ne 0) 'rejects an incomplete package'
Assert ((Get-FileHash -LiteralPath $scenePath).Hash -eq $beforeFailure) 'failed validation leaves the installed scene collection untouched'
Put (Join-Path $brokenRepo $manifest.files[0].path) 'deliberately corrupt test asset'
Assert ((Run-Setup $brokenRepo $install) -ne 0) 'rejects an asset checksum mismatch'
Assert ((Get-FileHash -LiteralPath $scenePath).Hash -eq $beforeFailure) 'corrupt assets leave the working setup untouched'
$badManifest = @{ version=1; files=@(@{path='../outside.txt'; sha256='invalid'}) } | ConvertTo-Json -Depth 5
Put (Join-Path $brokenRepo 'obs\asset-manifest.json') $badManifest
Assert ((Run-Setup $brokenRepo $install) -ne 0) 'rejects paths outside the asset package'

Write-Host "`n$passed checks passed. Test files: $testBase" -ForegroundColor Green
