$ErrorActionPreference = 'Stop'
$build = Join-Path (Split-Path -Parent $PSScriptRoot) 'app\build'
$root = Join-Path $build ('updater-handoff-' + [guid]::NewGuid().ToString('N'))
$staging = Join-Path $root 'staging'
$installed = Join-Path $root 'installed'
New-Item -ItemType Directory -Path $staging, $installed -Force | Out-Null
$source = Join-Path $root 'FakeSetup.cs'
# The stub records arguments instead of installing anything. This exercises
# the real native helper without showing UI or touching a Windows installation.
@'
using System;
using System.IO;
class FakeSetup {
  static int Main(string[] args) {
    foreach (string arg in args) {
      if (arg.StartsWith("/DIR=")) {
        File.WriteAllLines(Path.Combine(arg.Substring(5), "handoff.txt"), args);
        return 0;
      }
    }
    return 1;
  }
}
'@ | Set-Content -LiteralPath $source -Encoding UTF8
$fakeSetup = Join-Path $staging 'Setup.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:winexe "/out:$fakeSetup" $source
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the test installer stub.' }
$helper = Join-Path $root 'updater.exe'
Copy-Item -LiteralPath (Join-Path $build 'windows\x64\runner\Release\av_network_toolbag_updater.exe') -Destination $helper
$sentinel = Join-Path $installed 'existing.txt'
Set-Content -LiteralPath $sentinel -Value 'original installation'
$parent = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 3') -WindowStyle Hidden -PassThru
$process = Start-Process -FilePath $helper -ArgumentList @($parent.Id.ToString(), ('"' + $fakeSetup + '"'), ('"' + $staging + '"'), ('"' + $installed + '"'), '--installer') -WindowStyle Hidden -PassThru
if ($process.WaitForExit(500) -or (Test-Path -LiteralPath (Join-Path $installed 'handoff.txt'))) {
    throw 'The helper did not wait for its parent to exit.'
}
if (-not $process.WaitForExit(20000)) { throw 'Updater handoff timed out.' }
$process.Refresh()
if ($process.ExitCode -ne 0) { throw "Updater failed ($($process.ExitCode))." }
$arguments = Get-Content -LiteralPath (Join-Path $installed 'handoff.txt')
if ($arguments -notcontains "/DIR=$installed" -or $arguments -notcontains '/NORESTART') {
    throw 'The installer did not receive the correct destination and restart policy.'
}
if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'original installation') {
    throw 'The helper modified the installed files instead of delegating to Setup.'
}
if (Test-Path -LiteralPath $staging) { throw 'The completed update left its staging directory behind.' }
Write-Host 'Native installer handoff passed: parent wait, destination, no file copying, and staging cleanup.'
