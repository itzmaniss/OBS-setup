#Requires -Version 5.1
<#
Restore the Terminal Lab scenes, assets, output profile, and desktop shortcut.
TestRoot runs the file restore in isolation; it never installs or launches OBS.
#>
[CmdletBinding()]
param(
    [string]$ObsPath,
    [ValidateSet('Auto', 'Nvidia', 'Software')][string]$Encoder = 'Auto',
    [switch]$NoLaunch,
    [string]$TestRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
$testMode = -not [string]::IsNullOrWhiteSpace($TestRoot)
$profileName = 'itzmaniss - Terminal Lab'
$collectionFile = 'itzmaniss-terminal-lab.json'
$assetToken = '__TERMINAL_LAB_ASSETS__/'

function Write-Utf8([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-ChildPath([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative.Contains(':')) {
        throw "Unsafe relative path: $Relative"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside its destination: $Relative"
    }
    return $full
}

function Find-Obs {
    if ($ObsPath) {
        if (-not (Test-Path -LiteralPath $ObsPath -PathType Leaf) -or (Split-Path -Leaf $ObsPath) -ne 'obs64.exe') {
            throw 'ObsPath must point to an existing obs64.exe.'
        }
        return [IO.Path]::GetFullPath($ObsPath)
    }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\obs-studio\bin\64bit\obs64.exe')
    )
    foreach ($baseKey in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($entry in @(Get-ItemProperty -Path "$baseKey\*" -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'OBS Studio*' })) {
            if ($entry.PSObject.Properties['InstallLocation'] -and $entry.InstallLocation) {
                $candidates += Join-Path $entry.InstallLocation 'bin\64bit\obs64.exe'
            }
            if ($entry.PSObject.Properties['UninstallString'] -and $entry.UninstallString -match '^"?(.+?\.exe)"?(?:\s|$)') {
                $candidates += Join-Path (Split-Path -Parent $Matches[1]) 'bin\64bit\obs64.exe'
            }
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Merge-Ini([string]$Existing, [string]$Managed) {
    $sections = [ordered]@{}
    foreach ($document in @($Existing, $Managed)) {
        $section = $null
        foreach ($line in ($document -split '\r?\n')) {
            if ($line -match '^\[([^\]]+)\]$') {
                $section = $Matches[1]
                if (-not $sections.Contains($section)) { $sections[$section] = [ordered]@{} }
            } elseif ($section -and $line -match '^([^=]+)=(.*)$') {
                $sections[$section][$Matches[1]] = $Matches[2]
            }
        }
    }
    $lines = foreach ($name in $sections.Keys) {
        "[$name]"
        foreach ($key in $sections[$name].Keys) { "$key=$($sections[$name][$key])" }
        ''
    }
    return ($lines -join "`r`n")
}

try {
    $mutex = New-Object Threading.Mutex($false, 'Local\itzmaniss-TerminalLab-Setup')
    $ownsMutex = $mutex.WaitOne(0)
    if (-not $ownsMutex) { throw 'Another Terminal Lab setup is already running.' }

    # Validate the entire package before touching OBS or installing anything.
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'obs\asset-manifest.json') | ConvertFrom-Json
    if ($manifest.version -ne 1 -or @($manifest.files).Count -lt 1) { throw 'Invalid asset manifest.' }
    foreach ($file in $manifest.files) {
        $source = Get-ChildPath $repoRoot $file.path
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Package is missing $($file.path). Download and extract the complete repo ZIP." }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.sha256) { throw "Asset changed or is incomplete: $($file.path). Run setup\Update-AssetManifest.ps1 after intentional edits." }
    }
    $collection = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'obs\scene-collection.template.json') | ConvertFrom-Json
    if ($collection.name -ne $profileName -or @($collection.scene_order).Count -ne 13) { throw 'Unexpected scene collection template.' }

    if ($testMode) {
        $testBase = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\', '/')
        if ($testBase -eq [IO.Path]::GetPathRoot($testBase).TrimEnd('\', '/') -or $testBase -eq $env:APPDATA -or $testBase -eq $env:LOCALAPPDATA) { throw 'TestRoot must be a dedicated test folder.' }
        $installBase = Get-ChildPath $testBase 'local\itzmaniss-stream'
        $obsRoot = Get-ChildPath $testBase 'roaming\obs-studio'
        $recordings = Get-ChildPath $testBase 'videos\itzmaniss'
    } else {
        if (Get-Process -Name obs64, obs32 -ErrorAction SilentlyContinue) { throw 'OBS is open. Close OBS, then double-click SETUP-OBS.cmd again. Setup never stops an active stream.' }
        $installBase = Join-Path $env:LOCALAPPDATA 'itzmaniss-stream'
        $obsRoot = Join-Path $env:APPDATA 'obs-studio'
        $recordings = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'itzmaniss'
        $obsExe = Find-Obs
        if (-not $obsExe) {
            $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
            if (-not $winget) { throw 'Install Microsoft App Installer (winget) from Microsoft Store, or install OBS from https://obsproject.com/download, then rerun setup.' }
            Write-Host 'Installing OBS Studio using winget. Complete any Windows permission or first-run prompts.' -ForegroundColor Cyan
            & $winget.Source install --exact --id OBSProject.OBSStudio --source winget --silent
            if ($LASTEXITCODE -ne 0) { throw "OBS installation did not finish (winget exit $LASTEXITCODE). Install OBS, then rerun setup." }
            $obsExe = Find-Obs
            if (-not $obsExe) { throw 'OBS was installed but its path was not found. Rerun with -ObsPath "C:\path\to\obs64.exe".' }
        }
    }

    $assetRoot = Get-ChildPath $installBase 'terminal-lab'
    $scenePath = Get-ChildPath $obsRoot "basic\scenes\$collectionFile"
    $profileRoot = Get-ChildPath $obsRoot 'basic\profiles\itzmaniss-terminal-lab'
    $basicPath = Get-ChildPath $profileRoot 'basic.ini'

    # Preserve this machine's device choices and private alerts on repeated runs.
    if (Test-Path -LiteralPath $scenePath) {
        $existingCollection = Get-Content -Raw -Encoding UTF8 -LiteralPath $scenePath | ConvertFrom-Json
        foreach ($source in $collection.sources) {
            $old = @($existingCollection.sources | Where-Object { $_.name -eq $source.name -and $_.id -eq $source.id })
            if ($old.Count -ne 1) { continue }
            if ($source.id -in @('dshow_input', 'wasapi_input_capture')) { $source.settings = $old[0].settings }
            if ($source.id -eq 'browser_source' -and $source.settings.PSObject.Properties['url'] -and $old[0].settings.PSObject.Properties['url']) {
                $source.settings.url = $old[0].settings.url
            }
        }
    }

    foreach ($source in $collection.sources) {
        foreach ($key in @('file', 'local_file')) {
            if ($source.settings.PSObject.Properties[$key] -and $source.settings.$key) {
                $value = [string]$source.settings.$key
                if (-not $value.StartsWith($assetToken)) { throw "Non-portable asset path in $($source.name)." }
                $relative = $value.Substring($assetToken.Length)
                if ($relative -notin @($manifest.files.path)) { throw "Asset is not in the manifest: $relative" }
                $source.settings.$key = (Get-ChildPath $assetRoot $relative).Replace('\', '/')
            }
        }
    }
    foreach ($transition in $collection.transitions) {
        if ($transition.settings.PSObject.Properties['path'] -and $transition.settings.path) {
            $value = [string]$transition.settings.path
            if (-not $value.StartsWith($assetToken)) { throw 'Non-portable transition path.' }
            $relative = $value.Substring($assetToken.Length)
            if ($relative -notin @($manifest.files.path)) { throw "Transition is not in the manifest: $relative" }
            $transition.settings.path = (Get-ChildPath $assetRoot $relative).Replace('\', '/')
        }
    }
    $sceneText = $collection | ConvertTo-Json -Depth 100
    if ($sceneText.Contains($assetToken)) { throw 'An asset placeholder was not resolved.' }

    if ($Encoder -eq 'Auto') {
        $Encoder = 'Software'
        if (-not $testMode) {
            $gpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            if ($gpuNames -match 'NVIDIA') { $Encoder = 'Nvidia' }
        }
    }
    $encoderId = if ($Encoder -eq 'Nvidia') { 'obs_nvenc_h264_tex' } else { 'obs_x264' }
    $profileText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'obs\profile.basic.ini.in')
    $profileText = $profileText.Replace('__ENCODER__', $encoderId).Replace('__RECORDINGS__', $recordings.Replace('\', '/'))
    $existingIni = if (Test-Path -LiteralPath $basicPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $basicPath } else { '' }
    $profileText = Merge-Ini $existingIni $profileText
    $streamEncoder = @{ rate_control='CBR'; bitrate=6000; keyint_sec=2; profile='high' }
    $recordEncoder = @{ rate_control='CRF'; crf=20; keyint_sec=2; profile='high'; preset='veryfast' }
    if ($Encoder -eq 'Nvidia') {
        $streamEncoder += @{ preset='p5'; tune='hq'; multipass='disabled'; lookahead=$false; adaptive_quantization=$true; bf=2 }
        $recordEncoder = $streamEncoder.Clone()
        $recordEncoder.rate_control = 'CQP'
        $recordEncoder.cqp = 20
    } else { $streamEncoder.preset = 'veryfast' }

    if (-not $testMode -and (Get-Process -Name obs64, obs32 -ErrorAction SilentlyContinue)) { throw 'OBS opened during setup. Close OBS and run setup again before restoring the files.' }

    # Save a complete local rollback copy of this setup before updating it.
    $backupRoot = Get-ChildPath $installBase ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $hadExisting = (Test-Path -LiteralPath $assetRoot) -or (Test-Path -LiteralPath $scenePath) -or (Test-Path -LiteralPath $profileRoot)
    if ($hadExisting) {
        [void][IO.Directory]::CreateDirectory($backupRoot)
        if (Test-Path -LiteralPath $assetRoot) { Copy-Item -LiteralPath $assetRoot -Destination (Join-Path $backupRoot 'assets') -Recurse }
        if (Test-Path -LiteralPath $scenePath) { Copy-Item -LiteralPath $scenePath -Destination (Join-Path $backupRoot $collectionFile) }
        if (Test-Path -LiteralPath $profileRoot) { Copy-Item -LiteralPath $profileRoot -Destination (Join-Path $backupRoot 'profile') -Recurse }
    }

    # Copy only the manifest allowlist; never copy Git data or local credentials.
    foreach ($file in $manifest.files) {
        $destination = Get-ChildPath $assetRoot $file.path
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath (Get-ChildPath $repoRoot $file.path) -Destination $destination -Force
    }
    Write-Utf8 $scenePath $sceneText
    Write-Utf8 $basicPath $profileText
    Write-Utf8 (Get-ChildPath $profileRoot 'streamEncoder.json') ($streamEncoder | ConvertTo-Json)
    Write-Utf8 (Get-ChildPath $profileRoot 'recordEncoder.json') ($recordEncoder | ConvertTo-Json)
    $servicePath = Get-ChildPath $profileRoot 'service.json'
    if (-not (Test-Path -LiteralPath $servicePath)) {
        Write-Utf8 $servicePath '{"type":"rtmp_common","settings":{"service":"Twitch","server":"auto","key":""}}'
    }
    [void][IO.Directory]::CreateDirectory($recordings)

    if (-not $testMode) {
        $launchArgs = '--profile "' + $profileName + '" --collection "' + $profileName + '" --scene "' + $collection.current_scene + '"'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'OBS - Terminal Lab.lnk'))
        $shortcut.TargetPath = $obsExe
        $shortcut.Arguments = $launchArgs
        $shortcut.WorkingDirectory = Split-Path -Parent $obsExe
        $shortcut.IconLocation = "$obsExe,0"
        $shortcut.Save()
        if (-not $NoLaunch) { Start-Process -FilePath $obsExe -ArgumentList $launchArgs -WorkingDirectory (Split-Path -Parent $obsExe) }
    }

    Write-Host "`nTerminal Lab is ready: 13 scenes, 1080p60, $Encoder encoder." -ForegroundColor Green
    Write-Host "Assets: $assetRoot"
    if ($hadExisting) { Write-Host "Backup: $backupRoot" }
    if ($testMode) { Write-Host 'TEST MODE: OBS and your real OBS configuration were not touched.' }
    else { Write-Host 'Connect Twitch in Settings > Stream, check your mic/camera, and test game capture before going live.' }
} catch {
    Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ((Get-Variable ownsMutex -ErrorAction SilentlyContinue) -and $ownsMutex) { $mutex.ReleaseMutex() }
    if (Get-Variable mutex -ErrorAction SilentlyContinue) { $mutex.Dispose() }
}
