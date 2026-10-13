# Download only the native Windows app; no Swift installation or elevation.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'Methurcoder/Castor'
$work = $null
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This launcher is for Windows.' }
    # Do not mistake an emulated x64 process on ARM64 for an x64 computer.
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -ne 'AMD64') { throw 'The preview currently supports Windows x64 only.' }
    $platform = 'windows_x86_64'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('castor-download-' + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    $authenticated = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh auth status --hostname github.com *> $null
        $authenticated = $LASTEXITCODE -eq 0
    }
    $endpoint = "repos/$repo/releases/latest"
    if ($authenticated) {
        $releaseText = & gh api $endpoint
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the Release. Check repository access.' }
        $release = ($releaseText -join "`n") | ConvertFrom-Json
    } else {
        $release = Invoke-RestMethod -Uri "https://api.github.com/$endpoint"
    }
    if ($release.tag_name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'Invalid Release tag.' }
    if ($release.draft -or $release.prerelease) { throw 'Use a stable Release.' }
    function Get-ReleaseFile([string]$name, [string]$destination) {
        $matches = @($release.assets | Where-Object { $_.name -ceq $name })
        if ($matches.Count -ne 1) { throw "Missing or duplicate Release asset: $name" }
        $asset = $matches[0]
        if ($asset.id -le 0 -or $asset.browser_download_url -cnotlike "https://github.com/$repo/releases/download/*") {
            throw 'Unexpected Release asset.'
        }
        if ($authenticated) {
            # gh writes asset bytes itself; PowerShell 5.1 stdout redirection would corrupt ZIPs.
            $fetchDirectory = Join-Path $work ([Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $fetchDirectory | Out-Null
            & gh release download $release.tag_name --repo $repo --pattern $name --dir $fetchDirectory
            if ($LASTEXITCODE -ne 0) { throw 'Asset download failed.' }
            Move-Item -LiteralPath (Join-Path $fetchDirectory $name) -Destination $destination
        } else {
            Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $destination
        }
    }
    $manifestFile = Join-Path $work 'manifest.json'
    Get-ReleaseFile 'castor-downloads.json' $manifestFile
    $manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.version -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'Invalid download manifest.'
    }
    $version = $manifest.version
    $app = $manifest.platforms.$platform
    if (-not $app) { throw 'No Release app for this operating system and CPU.' }
    $name = "Castor-$version-$platform.zip"
    if ($app.asset -cne $name -or $app.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $app.bytes -le 0) {
        throw 'Invalid app manifest.'
    }
    Write-Host "Downloading Castor $version ($platform)..."
    $zipFile = Join-Path $work 'app.zip'
    Get-ReleaseFile $name $zipFile
    if ((Get-Item -LiteralPath $zipFile).Length -ne $app.bytes) { throw 'Download size does not match.' }
    if ((Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $app.sha256) {
        throw 'SHA-256 does not match. The app was not installed.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stage = Join-Path $work 'app'
    New-Item -ItemType Directory -Path $stage | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($zipFile)
    try {
        foreach ($entry in $zip.Entries) {
            $path = $entry.FullName
            if ($path -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:|\\)' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'Unsafe ZIP entry.'
            }
            $full = [IO.Path]::GetFullPath((Join-Path $stage $path))
            if (-not $full.StartsWith($stage + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ZIP entry leaves the install folder.'
            }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $stage)
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'CastorPet.exe') -PathType Leaf)) { throw 'CastorPet.exe is missing.' }
    $base = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    [IO.Directory]::CreateDirectory($base) | Out-Null
    $target = Join-Path $base "Castor-$version-$platform"
    # Directory.Move fails if destination already exists, including races.
    [IO.Directory]::Move($stage, $target)
    Write-Host "Installed: $target"
    Start-Process explorer.exe -ArgumentList ('"' + $target + '"')
} catch {
    Write-Host ("Castor: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'If the repository is private, check access and run gh auth login locally. A Release must exist.'
    exit 1
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
