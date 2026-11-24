# 120-windows-craft-octomind-npm -- Craft Agents, Octomind, Codewhale and Momentic's Mo through
# the Windows route each documents. Read off probe runs 45238894100 and 45468880057 on
# windows-2025.
#
#   Craft Agents  thecraftagents.com/install-app.ps1, which runs the app's electron-builder
#                 NSIS installer (per user, so an Uninstall key under HKCU) and writes a
#                 launcher, %LOCALAPPDATA%\Craft Agents\bin\craft-agents.cmd
#   Octomind      Muvon/octomind's install.ps1: %LOCALAPPDATA%\octomind\bin\octomind.exe
#   Codewhale     npm `codewhale`, under npm's default prefix; its setup and winget package
#                 are 121's
#   Momentic Mo   npm `qa`, likewise
#
# CRAFT AGENTS' INSTALLER STARTS THE APP, and the app writes ~\.craft-agent: the process and
# the directory were both there one second after install-app.ps1 returned (probe run
# 45468880057). So setup waits for the directory, which makes it a row of every run rather
# than of the runs that read late enough, then stops the app, and expected.json holds the
# directory present and the process absent. The three CLIs are installed and not run.
#
# Each installer runs as its own process, for 110's reason: a script that ends in `exit`
# would end this one.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

# An attempt counts only if it left the file the installer should, and is retried, as 119's
# are: a CDN can reset a transfer mid-download, and Craft Agents' is the app itself.
function Install-Vendor([string]$What, [string]$Url, [string]$Name, [int]$Minutes, [string]$Leaves) {
  $ps1 = Join-Path $env:RUNNER_TEMP $Name
  [void](Invoke-Retry $What {
    (Get-Download $Url $ps1) -and
    (Invoke-Bounded $What $Minutes 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                                                      '-File', $ps1)) -and
    (Test-Path $Leaves)
  })
}

# STOPPED UNTIL IT STAYS STOPPED, as 111 stops Warp; "Craft Agents" is the process name the
# vendor's own script stops before an upgrade.
function Stop-CraftAgents {
  $quiet = 0
  for ($i = 0; $i -lt 24 -and $quiet -lt 3; $i++) {
    $ps = @(Get-Process -Name 'Craft Agents' -ErrorAction SilentlyContinue)
    if ($ps.Count) {
      $quiet = 0
      $ps | ForEach-Object { Write-Host "  stopping $($_.Path)"
                             Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    } else { $quiet++ }
    Start-Sleep -Seconds 5
  }
}

Install-Vendor 'the Craft Agents installer' 'https://thecraftagents.com/install-app.ps1' `
  'craft-install-app.ps1' 15 (Join-Path $env:LOCALAPPDATA 'Craft Agents\bin\craft-agents.cmd')
$dot = Join-Path $HOME '.craft-agent'
for ($i = 0; $i -lt 24 -and -not (Test-Path $dot); $i++) { Start-Sleep -Seconds 5 }
if (-not (Test-Path $dot)) { Write-Host "WARN: no $dot; the installer's app did not write it" }
Stop-CraftAgents

Install-Vendor 'the Octomind installer' `
  'https://raw.githubusercontent.com/muvon/octomind/master/install.ps1' `
  'octomind-install.ps1' 10 (Join-Path $env:LOCALAPPDATA 'octomind\bin\octomind.exe')
Reset-NpmPrefix
Install-NpmGlobal @('codewhale', 'qa')
# Again, last: 111's Warp was running again by the time rows were read.
Stop-CraftAgents

# For the log: what each installer left where the enumeration reads, and the Uninstall key.
foreach ($f in $dot, (Join-Path $env:LOCALAPPDATA 'Craft Agents\bin\craft-agents.cmd'),
               (Join-Path $env:LOCALAPPDATA 'octomind\bin\octomind.exe'),
               (Join-Path $env:APPDATA 'npm\node_modules\codewhale'),
               (Join-Path $env:APPDATA 'npm\node_modules\qa')) {
  if (Test-Path $f) { Write-Host "  landed: $f" } else { Write-Host "WARN: no $f" }
}
Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Filter '*.exe' -Recurse -Depth 1 -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host "  app: $($_.FullName)" }
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
  Where-Object { ($_.GetValue('DisplayName') -match 'Craft') } |
  ForEach-Object { Write-Host "  uninstall: $($_.PSChildName) = $($_.GetValue('DisplayName'))" }
exit 0
