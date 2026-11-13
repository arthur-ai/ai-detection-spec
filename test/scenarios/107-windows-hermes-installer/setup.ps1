# 107-windows-hermes-installer -- Hermes Agent through the vendor's PowerShell installer.
#
# `iex (irm https://hermes-agent.nousresearch.com/install.ps1)` is the vendor's native
# Windows route. It is downloaded and run with -File here so it can take its switches:
# -NonInteractive skips setup and gateway configuration, and -SkipBrowser and
# -SkipComputerUse leave out the pinned Chromium and computer-use driver, which are
# optional and add nothing to what is read.
#
# EVERYTHING LANDS UNDER %LOCALAPPDATA%\hermes: the checkout, PM's tool store and the
# launchers in its bin\. No ~\.hermes and nothing in ~\.local\bin, which are the two places
# filesystem-windows.sql reads (probe run 41870942008). So the install is found RUNNING,
# by the launcher's directory, and `hermes gateway run` is what keeps a process there: with
# no messaging platform configured it logs a warning and stays up until it is stopped. The
# first launch republishes the launchers and renames the running hermes.exe aside to
# hermes.exe.deleteme, and processes.path follows the rename (run 41880268740), which is
# why the catalog names the directory and the rows are printed below.
#
# Measured on that run: 8.4 minutes for the install, v0.22.7.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$ps1 = Join-Path $env:RUNNER_TEMP 'hermes-install.ps1'
if (-not (Get-Download 'https://hermes-agent.nousresearch.com/install.ps1' $ps1)) {
  Write-Host 'WARN: the Hermes installer did not download'
  exit 0
}
[void](Invoke-Try 'the Hermes installer' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy',
       'Bypass', '-File', $ps1, '-NonInteractive', '-SkipBrowser', '-SkipComputerUse'))

$exe = Join-Path $env:LOCALAPPDATA 'hermes\bin\hermes.exe'
if (-not (Test-Path $exe)) {
  Write-Host "WARN: the installer wrote no $exe"
  exit 0
}
& $exe --version
Start-Process -FilePath $exe -ArgumentList 'gateway', 'run' -WindowStyle Hidden `
  -RedirectStandardOutput "$env:RUNNER_TEMP\hermes-gateway.out" `
  -RedirectStandardError "$env:RUNNER_TEMP\hermes-gateway.err"
Start-Sleep -Seconds 30
Get-Content "$env:RUNNER_TEMP\hermes-gateway.out", "$env:RUNNER_TEMP\hermes-gateway.err" `
  -ErrorAction SilentlyContinue | Select-Object -Last 10
# What the query will read: the process rows under a home, as osquery spells them.
& $env:OSQI --json "SELECT pid, parent, path FROM processes WHERE path LIKE '%hermes%'"
exit 0
