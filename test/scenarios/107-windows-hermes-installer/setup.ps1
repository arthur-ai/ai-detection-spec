# PROBE ONLY: runs the vendor's PowerShell installer and prints what it wrote, as annotations.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')
function Note([string]$t, $m) { $s = ($m | Out-String); if ($s.Length -gt 6000) { $s = $s.Substring(0,6000) }
  Write-Host ("::notice title=$t::" + $s.Replace('%','%25').Replace("`r",'').Replace("`n",'%0A')) }
Note 'localappdata-before' (Get-ChildItem -Force $env:LOCALAPPDATA | Select-Object -ExpandProperty Name)
$ps1 = Join-Path $env:RUNNER_TEMP 'hermes-install.ps1'
[void](Get-Download 'https://hermes-agent.nousresearch.com/install.ps1' $ps1)
$t0 = Get-Date
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -NonInteractive -SkipBrowser -SkipComputerUse 2>&1 | Select-Object -Last 40 | Out-String | ForEach-Object { Note 'installer-tail' $_ }
Note 'installer-exit' "rc=$LASTEXITCODE minutes=$(((Get-Date)-$t0).TotalMinutes)"
$H = Join-Path $env:LOCALAPPDATA 'hermes'
Note 'hermes-home' ((Get-ChildItem -Force $H | Select-Object -ExpandProperty Name) + '---bin---' + (Get-ChildItem -Force (Join-Path $H 'bin') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name))
Note 'home' ((Get-ChildItem -Force $env:USERPROFILE | Select-Object -ExpandProperty Name) + '---.local\bin---' + (Get-ChildItem -Force "$env:USERPROFILE\.local\bin" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name))
Note 'uninstall-keys' (Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
$exe = Join-Path $H 'bin\hermes.exe'; if (-not (Test-Path $exe)) { $exe = (Get-ChildItem (Join-Path $H 'bin') -Filter 'hermes*' | Select-Object -First 1).FullName }
Note 'version' (& $exe --version 2>&1)
# Something long-lived, so a process is there to read.
Start-Process -FilePath $exe -ArgumentList 'gateway','run' -WindowStyle Hidden -RedirectStandardOutput "$env:RUNNER_TEMP\gw.out" -RedirectStandardError "$env:RUNNER_TEMP\gw.err"
Start-Process -FilePath $exe -ArgumentList 'dashboard' -WindowStyle Hidden -RedirectStandardOutput "$env:RUNNER_TEMP\db.out" -RedirectStandardError "$env:RUNNER_TEMP\db.err"
Start-Sleep -Seconds 40
Note 'gw-out' ((Get-Content "$env:RUNNER_TEMP\gw.out","$env:RUNNER_TEMP\gw.err","$env:RUNNER_TEMP\db.out","$env:RUNNER_TEMP\db.err" -ErrorAction SilentlyContinue | Select-Object -Last 30))
Note 'osq-proc' (& $env:OSQI --json "SELECT name, path FROM processes WHERE path LIKE '_:\Users\%'")
Note 'localappdata-after' (Get-ChildItem -Force $env:LOCALAPPDATA | Select-Object -ExpandProperty Name)
Note 'home-after' (Get-ChildItem -Force $env:USERPROFILE | Select-Object -ExpandProperty Name)
exit 0
