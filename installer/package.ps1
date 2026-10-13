param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$IsccPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'app\build\tools\inno-6.7.3\ISCC.exe')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'app'
if ($Tag -cnotmatch '^v?(\d+\.\d+\.\d+)$') {
    throw "Release tag '$Tag' must be a version such as v1.1.0."
}
$version = $Matches[1]
$bundle = Join-Path $app 'build\windows\x64\runner\Release'
foreach ($required in @('av_network_toolbag.exe', 'av_network_toolbag_updater.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $required) -PathType Leaf)) {
        throw "Missing release file: $required. Run flutter build windows --release first."
    }
}
$exeVersion = (Get-Item -LiteralPath (Join-Path $bundle 'av_network_toolbag.exe')).VersionInfo
if ("$($exeVersion.FileMajorPart).$($exeVersion.FileMinorPart).$($exeVersion.FileBuildPart)" -ne $version) {
    throw "The executable version does not match release tag '$Tag'. Rebuild with --build-name $version before packaging."
}
if (Test-Path -LiteralPath (Join-Path $bundle 'installed.location')) {
    throw 'The build bundle must not contain an installed-copy marker.'
}
if (-not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Run installer/bootstrap-inno.ps1 or pass -IsccPath with the path to ISCC.exe.'
}
# App-local runtime files make both distributions usable on a clean PC.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'Visual Studio C++ tools were not found.' }
$redistRoot = Join-Path $visualStudio 'VC\Redist\MSVC'
$redistVersion = Get-ChildItem -LiteralPath $redistRoot -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $redistVersion) { throw 'Visual C++ redistributable files were not found.' }
$crt = Get-ChildItem -Path (Join-Path $redistVersion.FullName 'x64\Microsoft.VC*.CRT') -Directory | Select-Object -First 1
if (-not $crt) { throw 'Visual C++ x64 redistributable files were not found.' }
foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    Copy-Item -LiteralPath (Join-Path $crt.FullName $dll) -Destination $bundle -Force
}
$output = Join-Path $app 'dist'
New-Item -ItemType Directory -Path $output -Force | Out-Null
& $IsccPath "/DAppVersion=$version" "/DReleaseTag=$Tag" "/DBundleDir=$bundle" "/DOutputDir=$output" (Join-Path $PSScriptRoot 'AVNetworkToolbag.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed ($LASTEXITCODE)." }
$installer = Join-Path $output "AV-Network-Toolbag-$Tag-windows-x64-Setup.exe"
$archive = Join-Path $output "AV-Network-Toolbag-$Tag-windows-x64.zip"
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive -Force
$checksums = Join-Path $output 'SHA256SUMS.txt'
@($installer, $archive) | ForEach-Object {
    $hash = Get-FileHash -LiteralPath $_ -Algorithm SHA256
    '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), (Split-Path -Leaf $_)
} | Set-Content -LiteralPath $checksums -Encoding ascii
if ($env:GITHUB_OUTPUT) {
    @("safe_tag=$Tag", "archive_path=$archive", "installer_path=$installer", "checksum_path=$checksums") |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
Write-Host "Packaged installer, portable ZIP, and checksums in $output"
