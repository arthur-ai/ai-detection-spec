# 110-windows-installers-more -- the Windows twin of 98-linux-installers-more: the Warp Agent
# CLI and Kilo CLI through their vendors' own installers, installed and not run.
#
#   Warp Agent CLI  app.warp.dev/download/agent-cli.ps1, which runs an Inno Setup installer
#                   with /CURRENTUSER: %LOCALAPPDATA%\Warp\bin\warp.cmd and an Uninstall key
#   Kilo CLI        kilo.ai/cli/install, the bash script Linux runs, which takes Git Bash as
#                   Windows: ~\.kilo\bin\
#
# Each runs as its own process: Warp's script ends in `exit`, which would end this one.
# --no-modify-path keeps Kilo's out of the user PATH, which nothing here reads.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$ps1 = Join-Path $env:RUNNER_TEMP 'warp-agent-cli.ps1'
if (Get-Download 'https://app.warp.dev/download/agent-cli.ps1' $ps1) {
  [void](Invoke-Bounded 'the Warp Agent CLI installer' 10 'powershell.exe' @('-NoProfile',
         '-ExecutionPolicy', 'Bypass', '-File', $ps1))
}
$sh = Join-Path $env:RUNNER_TEMP 'kilo-install.sh'
if (Get-Download 'https://kilo.ai/cli/install' $sh) {
  [void](Invoke-Bounded 'the Kilo CLI installer' 10 'bash.exe' @(($sh -replace '\\', '/'),
         '--no-modify-path'))
}

# For the log: what each installer left where the enumeration reads, and the Uninstall key.
foreach ($d in (Join-Path $env:LOCALAPPDATA 'Warp\bin'), (Join-Path $HOME '.kilo\bin')) {
  if (Test-Path $d) { Get-ChildItem $d | ForEach-Object { Write-Host "  landed: $($_.FullName)" } }
  else { Write-Host "WARN: no $d" }
}
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
  Where-Object { ($_.GetValue('DisplayName') -match 'Warp|Kilo') } |
  ForEach-Object { Write-Host "  uninstall: $($_.PSChildName) = $($_.GetValue('DisplayName'))" }
exit 0
