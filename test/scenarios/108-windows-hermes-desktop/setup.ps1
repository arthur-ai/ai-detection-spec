# PROBE ONLY: installs the Hermes desktop MSIX and prints its identity as annotations.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')
function Note([string]$t, $m) { $s = ($m | Out-String); if ($s.Length -gt 6000) { $s = $s.Substring(0,6000) }
  Write-Host ("::notice title=$t::" + $s.Replace('%','%25').Replace("`r",'').Replace("`n",'%0A')) }
$dl = Join-Path $env:RUNNER_TEMP 'hermes'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
$ai = Join-Path $dl 'stable.appinstaller'
[void](Get-Download 'https://hermes-assets.nousresearch.com/releases/win32/stable/stable.appinstaller' $ai)
$x = Get-Content -Raw $ai; Note 'appinstaller' $x
$uri = ([xml]$x).AppInstaller.MainBundle.Uri; if (-not $uri) { $uri = ([xml]$x).AppInstaller.MainPackage.Uri }
$b = Join-Path $dl 'hermes.msixbundle'
if (Get-Download $uri $b) { try { Add-AppxPackage -Path $b } catch { Note 'add-appx-failed' "$_" } }
Note 'appx' (Get-AppxPackage | Where-Object { $_.Name -like '*ermes*' -or $_.Publisher -like '*Nous*' } | Format-List Name,PackageFamilyName,Publisher,Version,InstallLocation)
Note 'aliases' (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
Note 'osq-programs' (& $env:OSQI --json "SELECT name, identifying_number, publisher, version, install_location FROM programs WHERE name LIKE '%ermes%' OR publisher LIKE '%Nous%' OR identifying_number LIKE '%ermes%'")
Note 'home' (Get-ChildItem -Force $env:USERPROFILE | Select-Object -ExpandProperty Name)
exit 0
