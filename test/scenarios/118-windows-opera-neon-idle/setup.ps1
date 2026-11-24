# 118-windows-opera-neon-idle -- Opera Neon on Windows, installed and NEVER launched.
#
# Through the installer Opera's site serves, per user, which fetches the current build into
# ~\AppData\Local\Programs\Opera Neon. 117 installs the same way and launches it, and a
# running browser is found by its process path whatever the files say. Nothing is launched
# here, so the launcher the installer wrote is the only witness. An installer that starts
# the browser despite --launchopera=0 fails the run instead of passing on the wrong route:
# setup stops with exit 1 on any process under the install directory, and expected.json
# forbids the launcher's `proc` row.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$exe = Join-Path $env:RUNNER_TEMP 'OperaNeonSetup.exe'
if (Get-Download 'https://net.geo.opera.com/opera_neon/stable/windows' $exe) {
  [void](Install-Exe 'Opera Neon' $exe '--silent --allusers=0 --launchopera=0 --setdefaultbrowser=0 --import-browser-data=0')
}
$dir = Join-Path $env:LOCALAPPDATA 'Programs\Opera Neon'
$live = @(Get-Process | Where-Object { $_.Path -like "$dir\*" })
if ($live.Count -gt 0) {
  Write-Host "FAIL: the install is not idle. Running from ${dir}:"
  $live | Select-Object -ExpandProperty Path -Unique
  exit 1
}

# Evidence for the log, not assertions: what the per-user app branch reads under every home,
# the Uninstall keys that name Opera, and any process running from a Programs directory.
& $env:OSQI --json "SELECT f.path FROM users u CROSS JOIN file f ON f.path LIKE u.directory || '\AppData\Local\Programs\%\%.exe' WHERE u.directory LIKE '_:\Users\%'"
& $env:OSQI --json "SELECT key FROM registry WHERE key LIKE 'HKEY_USERS\%\Software\Microsoft\Windows\CurrentVersion\Uninstall\Opera%'"
& $env:OSQI --json "SELECT pid, path FROM processes WHERE path LIKE '%\AppData\Local\Programs\%'"
exit 0
