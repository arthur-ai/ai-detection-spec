# 109-windows-hermes-idle -- Hermes Agent through the vendor's PowerShell installer, NEVER
# launched.
#
# 107 installs the same way and starts the gateway, which is the running install. This is
# the installed-and-idle one: everything lands under %LOCALAPPDATA%\hermes, and the launcher
# in its bin\ is what filesystem-windows.sql's per-app bin\ branch reads. Nothing is started,
# so a process path cannot stand in for the file.
#
# -NonInteractive skips setup and gateway configuration, the two stages that run the
# installed command; -SkipBrowser and -SkipComputerUse leave out optional downloads.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$ps1 = Join-Path $env:RUNNER_TEMP 'hermes-install.ps1'
if (-not (Get-Download 'https://hermes-agent.nousresearch.com/install.ps1' $ps1)) {
  Write-Host 'WARN: the Hermes installer did not download'
  exit 0
}
[void](Invoke-Try 'the Hermes installer' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy',
       'Bypass', '-File', $ps1, '-NonInteractive', '-SkipBrowser', '-SkipComputerUse'))

# What the query will read, and proof that nothing of Hermes is running: the per-app bin\
# executables under every home, and any process whose path names hermes.
& $env:OSQI --json "SELECT f.path FROM users u CROSS JOIN file f ON f.path LIKE u.directory || '\AppData\Local\%\bin\%.exe' WHERE u.directory LIKE '_:\Users\%'"
& $env:OSQI --json "SELECT pid, path FROM processes WHERE path LIKE '%hermes%'"
exit 0
