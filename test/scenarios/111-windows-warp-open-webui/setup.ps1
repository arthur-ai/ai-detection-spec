# 111-windows-warp-open-webui -- the Warp app, Open WebUI Desktop, and Open WebUI from PyPI,
# on Windows.
#
#   Warp           WarpSetup.exe, Inno Setup, per user (/CURRENTUSER, as winget's Warp.Warp
#                  runs it): an Uninstall key
#   Open WebUI     the desktop app's electron-builder installer, per user (/S): an Uninstall key;
#                  and `uv tool install open-webui`, which names its tool directory for the
#                  package under %APPDATA%\uv\tools\ (SPEC.md 6.4.6)
#
# BOUNDED, NOT Install-Exe: Start-Process -Wait waits for every process the installer starts,
# and Warp's starts the app when it finishes, even silent. The first run of this scenario sat
# in setup until the job's timeout with two warp processes left (probe run 44703507946). The
# app is stopped once its installer returns, so what it writes on a full first run is not
# what this scenario reads. Open WebUI declares
# Python >=3.11,<3.13, so uv is told 3.12 rather than left to pick the runner's; its install
# pulls torch.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$dl = Join-Path $env:RUNNER_TEMP 'desktop'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

$warp = Join-Path $dl 'WarpSetup.exe'
if (Get-Download 'https://app.warp.dev/download?package=exe_x86_64' $warp) {
  [void](Invoke-Bounded 'the Warp installer' 10 $warp @('/VERYSILENT', '/SUPPRESSMSGBOXES',
         '/NORESTART', '/SP-', '/CURRENTUSER'))
  Get-Process -Name 'warp' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  stopping the app its installer started: $($_.Path)"
    Stop-Process -Id $_.Id -Force
  }
}
$owui = Join-Path $dl 'open-webui-setup.exe'
if (Get-Download 'https://github.com/open-webui/desktop/releases/latest/download/open-webui-x64-setup.exe' $owui) {
  [void](Invoke-Bounded 'the Open WebUI Desktop installer' 10 $owui @('/S'))
}
[void](Invoke-Try 'installing uv' 'python' @('-m', 'pip', 'install', '--quiet', '--upgrade', 'uv'))
[void](Invoke-Bounded 'uv tool install open-webui' 20 'python' @('-m', 'uv', 'tool', 'install',
       '--python', '3.12', 'open-webui'))

# For the log: each Uninstall key the installers wrote, and the tool directory.
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
  Where-Object { ($_.GetValue('DisplayName') -match 'Warp|Open WebUI') } |
  ForEach-Object { Write-Host "  uninstall: $($_.PSChildName) = $($_.GetValue('DisplayName'))" }
$tools = Join-Path $env:APPDATA 'uv\tools\open-webui'
if (Test-Path $tools) { Write-Host "  landed: $tools" } else { Write-Host "WARN: no $tools" }

# PROBE ONLY: the case of %LOCALAPPDATA%\warp once the app has run, and where the CLI's
# installer puts its launcher on top of it.
function Show-Warp([string]$When) {
  Get-ChildItem $env:LOCALAPPDATA | Where-Object { $_.Name -ieq 'warp' } |
    ForEach-Object { Write-Host "PROBE $When dir: $($_.FullName)"
      Get-ChildItem $_.FullName | ForEach-Object { Write-Host "PROBE $When   $($_.FullName)" } }
  Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'warp|webui' } | ForEach-Object { Write-Host "PROBE $When prog: $($_.FullName)" }
}
Show-Warp 'app-installed'
$ps1 = Join-Path $env:RUNNER_TEMP 'warp-agent-cli.ps1'
if (Get-Download 'https://app.warp.dev/download/agent-cli.ps1' $ps1) {
  [void](Invoke-Bounded 'the Warp Agent CLI installer' 10 'powershell.exe' @('-NoProfile',
         '-ExecutionPolicy', 'Bypass', '-File', $ps1))
}
Show-Warp 'cli-after-app'
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
  ForEach-Object { Write-Host "PROBE uninstall: $($_.PSChildName) = $($_.GetValue('DisplayName'))" }
exit 0
