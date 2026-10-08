$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repo 'app\build'))
$testId = 'AVNetworkToolbag-Smoke-' + [guid]::NewGuid().ToString('N')
$testRoot = Join-Path $buildRoot $testId
$destination = Join-Path $testRoot 'installed'
$bundle = Join-Path $buildRoot 'windows\x64\runner\Release'
$compiler = Join-Path $buildRoot 'tools\inno-6.7.3\ISCC.exe'
$script = Join-Path $PSScriptRoot 'AVNetworkToolbag.iss'
$registryKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\${testId}_is1"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function Invoke-TestInstaller([string]$Path, [string]$LogName) {
    $process = Start-Process -FilePath $Path -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', ('/DIR="' + $destination + '"'), ('/LOG="' + (Join-Path $testRoot $LogName) + '"')) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(60000)) { throw 'Test installer did not finish in 60 seconds.' }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "Test installer failed: $($process.ExitCode). See $LogName." }
}

try {
    # Use an isolated per-user identity and no shortcuts; do not install the
    # production AppId or modify any existing AV Network Toolbag installation.
    foreach ($version in @('1.0.0', '1.0.1')) {
        & $compiler '/Q' "/DAppVersion=$version" "/DReleaseTag=$version" "/DBundleDir=$bundle" "/DOutputDir=$testRoot" "/DInstallerAppId=$testId" '/DInstallPrivileges=lowest' "/DRunningMutex=$testId" $script
        if ($LASTEXITCODE -ne 0) { throw 'Test installer compilation failed.' }
        $setup = Join-Path $testRoot "AV-Network-Toolbag-$version-windows-x64-Setup.exe"
        Invoke-TestInstaller $setup "install-$version.log"
        if ((Get-ItemProperty -LiteralPath $registryKey).DisplayVersion -ne $version) {
            throw 'The uninstall entry was not updated to the new version.'
        }
        $marker = (Get-Content -LiteralPath (Join-Path $destination 'installed.location') -Raw -Encoding UTF8).Trim()
        if ($marker -ne $destination) { throw 'Installed-copy marker has the wrong location.' }
        foreach ($file in @('av_network_toolbag.exe', 'av_network_toolbag_updater.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'data\app.so')) {
            if (-not (Test-Path -LiteralPath (Join-Path $destination $file))) { throw "Installed file missing: $file" }
        }
        Write-Host "Install/upgrade $version passed."
    }
    # A running instance must block Setup without terminating that instance.
    $mutex = New-Object Threading.Mutex($false, $testId)
    try {
        $blocked = Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', ('/DIR="' + $destination + '"')) -WindowStyle Hidden -PassThru
        if (-not $blocked.WaitForExit(60000)) { throw 'Blocked installer did not exit.' }
        $blocked.Refresh()
        if ($blocked.ExitCode -eq 0) { throw 'Setup ignored the running-app mutex.' }
        Write-Host 'Running-app protection passed.'
    } finally {
        $mutex.Dispose()
    }
} finally {
    # Only execute the uninstaller created in this unique workspace test path.
    $resolved = [IO.Path]::GetFullPath($destination)
    if (-not $resolved.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to uninstall outside the build directory.'
    }
    $uninstaller = Join-Path $resolved 'unins000.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        $uninstall = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + (Join-Path $testRoot 'uninstall.log') + '"')) -WindowStyle Hidden -Wait -PassThru
        if ($uninstall.ExitCode -ne 0) { throw 'Test uninstall failed.' }
    }
}
if ((Test-Path -LiteralPath $registryKey) -or (Test-Path -LiteralPath (Join-Path $destination 'av_network_toolbag.exe')) -or (Test-Path -LiteralPath (Join-Path $destination 'installed.location'))) {
    throw 'Uninstall left installed application files or its registry entry behind.'
}
Write-Host "Installer smoke tests passed. Logs: $testRoot"
