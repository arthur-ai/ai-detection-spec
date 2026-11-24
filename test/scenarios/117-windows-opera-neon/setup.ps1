# 117-windows-opera-neon -- Opera Neon on Windows, installed and running.
#
# Through the installer Opera's site serves, per user, which fetches the current build into
# ~\AppData\Local\Programs\Opera Neon. Two witnesses, one per route: the launcher the
# installer writes, found installed, and the browser running from that directory.
# 118-windows-opera-neon-idle installs the same way and launches nothing.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$exe = Join-Path $env:RUNNER_TEMP 'OperaNeonSetup.exe'
if (Get-Download 'https://net.geo.opera.com/opera_neon/stable/windows' $exe) {
  [void](Install-Exe 'Opera Neon' $exe '--silent --allusers=0 --launchopera=0 --setdefaultbrowser=0 --import-browser-data=0')
}
$dir = Join-Path $env:LOCALAPPDATA 'Programs\Opera Neon'
$neon = Join-Path $dir 'opera.exe'
if (-not (Test-Path $neon)) {
  Write-Host "WARN: the installer left no $neon"
  exit 0
}
Start-Process $neon -ArgumentList '--no-first-run', 'about:blank'
# Polled, not slept through: a slow start gets its two minutes and a quick one costs seconds.
$running = @()
foreach ($n in 1..60) {
  $running = @(Get-Process | Where-Object { $_.Path -like "$dir\*" })
  if ($running.Count -gt 0) { break }
  Start-Sleep -Seconds 2
}
if ($running.Count -eq 0) { Write-Host "WARN: nothing is running from $dir after two minutes" }
$running | Select-Object -ExpandProperty Path -Unique
exit 0
