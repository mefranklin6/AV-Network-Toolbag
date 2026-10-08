$ErrorActionPreference = 'Stop'
# Portable compiler only: no shortcuts, file associations, or uninstall entry.
$toolsDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'app\build\tools'
$target = Join-Path $toolsDirectory 'inno-6.7.3'
$compiler = Join-Path $target 'ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    New-Item -ItemType Directory -Path $toolsDirectory -Force | Out-Null
    $download = Join-Path $toolsDirectory 'innosetup-6.7.3.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe' -OutFile $download
    $expected = '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'
    if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ine $expected) {
        throw 'Inno Setup compiler download checksum mismatch.'
    }
    $process = Start-Process -FilePath $download -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/PORTABLE=1', ('/DIR="' + $target + '"')) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $compiler)) {
        throw "Inno compiler extraction failed ($($process.ExitCode))."
    }
}
if ($env:GITHUB_OUTPUT) {
    "iscc_path=$compiler" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
Write-Host "Inno Setup compiler: $compiler"
