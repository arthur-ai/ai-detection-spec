# 112-windows-craft-octomind-npm -- four agents added 2026-11-23, through the Windows route
# each documents, installed and not run. Read off probe run 45238894100 on windows-2025.
#
#   Craft Agents  thecraftagents.com/install-app.ps1, which runs the app's electron-builder
#                 NSIS installer (per user, so an Uninstall key under HKCU) and writes a
#                 launcher, %LOCALAPPDATA%\Craft Agents\bin\craft-agents.cmd
#   Octomind      Muvon/octomind's install.ps1: %LOCALAPPDATA%\octomind\bin\octomind.exe
#   Codewhale     npm `codewhale`, under npm's default prefix
#   Momentic Mo   npm `qa`, likewise
#
# Each installer runs as its own process, for 110's reason: a script that ends in `exit`
# would end this one.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$ps1 = Join-Path $env:RUNNER_TEMP 'craft-install-app.ps1'
if (Get-Download 'https://thecraftagents.com/install-app.ps1' $ps1) {
  [void](Invoke-Bounded 'the Craft Agents installer' 15 'powershell.exe' @('-NoProfile',
         '-ExecutionPolicy', 'Bypass', '-File', $ps1))
}
$om = Join-Path $env:RUNNER_TEMP 'octomind-install.ps1'
if (Get-Download 'https://raw.githubusercontent.com/muvon/octomind/master/install.ps1' $om) {
  [void](Invoke-Bounded 'the Octomind installer' 10 'powershell.exe' @('-NoProfile',
         '-ExecutionPolicy', 'Bypass', '-File', $om))
}
Reset-NpmPrefix
Install-NpmGlobal @('codewhale', 'qa')

# For the log: what each installer left where the enumeration reads, and the Uninstall key.
foreach ($f in (Join-Path $env:LOCALAPPDATA 'Craft Agents\bin\craft-agents.cmd'),
               (Join-Path $env:LOCALAPPDATA 'octomind\bin\octomind.exe'),
               (Join-Path $env:APPDATA 'npm\node_modules\codewhale'),
               (Join-Path $env:APPDATA 'npm\node_modules\qa')) {
  if (Test-Path $f) { Write-Host "  landed: $f" } else { Write-Host "WARN: no $f" }
}
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
  Where-Object { ($_.GetValue('DisplayName') -match 'Craft') } |
  ForEach-Object { Write-Host "  uninstall: $($_.PSChildName) = $($_.GetValue('DisplayName'))" }
exit 0
