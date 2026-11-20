# 110-windows-opera-neon -- Opera Neon on Windows, running.
#
# Through the installer Opera's site serves, which fetches the current build into
# ~\AppData\Local\Programs\Opera Neon. Its Uninstall key carries the version in its name, so
# an idle install matches nothing (catalog/agents.yaml, opera-neon), and Neon is launched:
# the running process is what process_paths reads.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$exe = Join-Path $env:RUNNER_TEMP 'OperaNeonSetup.exe'
if (Get-Download 'https://net.geo.opera.com/opera_neon/stable/windows' $exe) {
  [void](Install-Exe 'Opera Neon' $exe '--silent --allusers=0 --launchopera=0 --setdefaultbrowser=0 --import-browser-data=0')
}
$neon = Join-Path $env:LOCALAPPDATA 'Programs\Opera Neon\opera.exe'
if (Test-Path $neon) {
  Start-Process $neon -ArgumentList '--no-first-run', 'about:blank'
  Start-Sleep -Seconds 20
} else {
  Write-Host "WARN: the installer left no $neon"
}
exit 0
