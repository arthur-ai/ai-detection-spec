# 109-windows-hermes-idle -- Hermes Agent through the vendor's PowerShell installer, NEVER
# launched.
#
# 107 installs the same way but launches Hermes before rows are collected, and a launch
# rewrites the launchers in %LOCALAPPDATA%\hermes\bin\. So 107 cannot tell a launcher the
# installer wrote from one the first launch wrote. A machine where Hermes was installed and
# never run has only the installer's, so nothing is launched here.
#
# -NonInteractive skips setup and gateway configuration, the two stages that run the
# installed command; -SkipBrowser and -SkipComputerUse leave out optional downloads. The
# install is bounded as 107's is.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$ps1 = Join-Path $env:RUNNER_TEMP 'hermes-install.ps1'
if (-not (Get-Download 'https://hermes-agent.nousresearch.com/install.ps1' $ps1)) {
  Write-Host 'WARN: the Hermes installer did not download'
  exit 0
}
[void](Invoke-Bounded 'the Hermes installer' 25 'powershell.exe' @('-NoProfile',
       '-ExecutionPolicy', 'Bypass', '-File', $ps1, '-NonInteractive', '-SkipBrowser',
       '-SkipComputerUse'))

# Evidence for the log, not assertions: the per-user launcher branch's rows under every
# home, and any process whose path names hermes, which should be none.
& $env:OSQI --json "SELECT f.path FROM users u CROSS JOIN file f ON f.path LIKE u.directory || '\AppData\Local\%\bin\%' WHERE u.directory LIKE '_:\Users\%'"
& $env:OSQI --json "SELECT pid, path FROM processes WHERE path LIKE '%hermes%'"
exit 0
