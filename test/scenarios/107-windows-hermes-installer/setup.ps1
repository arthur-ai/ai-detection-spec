# 107-windows-hermes-installer -- Hermes Agent through the vendor's PowerShell installer.
#
# `iex (irm https://hermes-agent.nousresearch.com/install.ps1)` is the vendor's native
# Windows route. It is downloaded and run with -File here so it can take its switches:
# -NonInteractive skips setup and gateway configuration, and -SkipBrowser and
# -SkipComputerUse leave out the pinned Chromium and computer-use driver, which are
# optional and add nothing to what is read.
#
# Two witnesses, one per route: the launchers the installer writes to
# %LOCALAPPDATA%\hermes\bin\, found installed, and `hermes gateway run` running from there,
# which with no messaging platform configured logs a warning and stays up until stopped.
# catalog/agents.yaml's hermes entry says why the running one is matched by its directory.
#
# Measured on probe run 41870942008: 8.4 minutes for the install, v0.22.7. The bound is
# three times that.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$ps1 = Join-Path $env:RUNNER_TEMP 'hermes-install.ps1'
if (-not (Get-Download 'https://hermes-agent.nousresearch.com/install.ps1' $ps1)) {
  Write-Host 'WARN: the Hermes installer did not download'
  exit 0
}
[void](Invoke-Bounded 'the Hermes installer' 25 'powershell.exe' @('-NoProfile',
       '-ExecutionPolicy', 'Bypass', '-File', $ps1, '-NonInteractive', '-SkipBrowser',
       '-SkipComputerUse'))

$bin = Join-Path $env:LOCALAPPDATA 'hermes\bin'
$exe = Join-Path $bin 'hermes.exe'
if (-not (Test-Path $exe)) {
  Write-Host "WARN: the installer wrote no $exe"
  exit 0
}
Get-ChildItem $bin | Select-Object -ExpandProperty Name
# --version checks for an update over the network, so it is bounded too.
[void](Invoke-Bounded 'hermes --version' 2 $exe @('--version'))
Start-Process -FilePath $exe -ArgumentList 'gateway', 'run' -WindowStyle Hidden `
  -RedirectStandardOutput "$env:RUNNER_TEMP\hermes-gateway.out" `
  -RedirectStandardError "$env:RUNNER_TEMP\hermes-gateway.err"
Start-Sleep -Seconds 30
Get-Content "$env:RUNNER_TEMP\hermes-gateway.out", "$env:RUNNER_TEMP\hermes-gateway.err" `
  -ErrorAction SilentlyContinue | Select-Object -Last 10
# What the query will read: the process rows under a home, as osquery spells them.
& $env:OSQI --json "SELECT pid, parent, path FROM processes WHERE path LIKE '%hermes%'"
exit 0
