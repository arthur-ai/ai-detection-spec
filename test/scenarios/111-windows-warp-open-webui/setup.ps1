# 111-windows-warp-open-webui -- the Warp app with its Agent CLI installed after it, Open WebUI
# Desktop, and Open WebUI from PyPI, on Windows.
#
#   Warp           WarpSetup.exe, Inno Setup, per user (/CURRENTUSER, as winget's Warp.Warp
#                  runs it): an Uninstall key. Then the CLI's agent-cli.ps1, as 110 runs it.
#   Open WebUI     the desktop app's electron-builder installer, per user (/S): an Uninstall key;
#                  and `uv tool install open-webui`, which names its tool directory for the
#                  package under %APPDATA%\uv\tools\ (SPEC.md 6.4.6)
#
# THE CLI AFTER THE APP, because the order moves its launcher. The app's install, which starts
# the app, leaves %LOCALAPPDATA%\warp\Warp, lowercase, and the CLI's installer then writes
# into that same directory, so its launcher is warp\bin\warp.cmd here and Warp\bin\warp.cmd in
# 110, where no app came first (probe run 44709924340). SPEC.md 6.4.7 compares that case, so each
# spelling is its own value, and this is the scenario that produces the lowercase one.
#
# BOUNDED, NOT Install-Exe: Start-Process -Wait waits for every process the installer starts,
# and Warp's starts the app when it finishes, even silent. The first run of this scenario sat
# in setup until the job's timeout with two warp processes left (probe run 44703507946).
# Open WebUI declares Python >=3.11,<3.13, so uv is told 3.12 rather than left to pick the
# runner's; its install pulls torch.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

# STOPPED UNTIL IT STAYS STOPPED: a warp process stopped once was running again by the time
# rows were read (probe run 44709924340). Fifteen quiet seconds, within two minutes, and
# expected.json's forbid_rows holds the result.
function Stop-Warp {
  $quiet = 0
  for ($i = 0; $i -lt 24 -and $quiet -lt 3; $i++) {
    $ps = @(Get-Process -Name 'warp' -ErrorAction SilentlyContinue)
    if ($ps.Count) {
      $quiet = 0
      $ps | ForEach-Object { Write-Host "  stopping $($_.Path)"
                             Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    } else { $quiet++ }
    Start-Sleep -Seconds 5
  }
}

$dl = Join-Path $env:RUNNER_TEMP 'desktop'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

$warp = Join-Path $dl 'WarpSetup.exe'
if (Get-Download 'https://app.warp.dev/download?package=exe_x86_64' $warp) {
  [void](Invoke-Bounded 'the Warp installer' 10 $warp @('/VERYSILENT', '/SUPPRESSMSGBOXES',
         '/NORESTART', '/SP-', '/CURRENTUSER'))
}
# The app has run, and been stopped, before the CLI's installer looks for its directory.
Stop-Warp
$ps1 = Join-Path $env:RUNNER_TEMP 'warp-agent-cli.ps1'
if (Get-Download 'https://app.warp.dev/download/agent-cli.ps1' $ps1) {
  [void](Invoke-Bounded 'the Warp Agent CLI installer' 10 'powershell.exe' @('-NoProfile',
         '-ExecutionPolicy', 'Bypass', '-File', $ps1))
}
$owui = Join-Path $dl 'open-webui-setup.exe'
if (Get-Download 'https://github.com/open-webui/desktop/releases/latest/download/open-webui-x64-setup.exe' $owui) {
  [void](Invoke-Bounded 'the Open WebUI Desktop installer' 10 $owui @('/S'))
}
[void](Invoke-Try 'installing uv' 'python' @('-m', 'pip', 'install', '--quiet', '--upgrade', 'uv'))
[void](Invoke-Bounded 'uv tool install open-webui' 20 'python' @('-m', 'uv', 'tool', 'install',
       '--python', '3.12', 'open-webui'))
Stop-Warp

# For the log: each Uninstall key the installers wrote, where the CLI's launcher went, and the
# tool directory.
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
  Where-Object { ($_.GetValue('DisplayName') -match 'Warp|Open WebUI') } |
  ForEach-Object { Write-Host "  uninstall: $($_.PSChildName) = $($_.GetValue('DisplayName'))" }
Get-ChildItem $env:LOCALAPPDATA | Where-Object { $_.Name -ieq 'warp' } |
  ForEach-Object { Get-ChildItem $_.FullName } | ForEach-Object { Write-Host "  landed: $($_.FullName)" }
$tools = Join-Path $env:APPDATA 'uv\tools\open-webui'
if (Test-Path $tools) { Write-Host "  landed: $tools" } else { Write-Host "WARN: no $tools" }
exit 0
