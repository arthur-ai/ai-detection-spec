# THROWAWAY PROBE, never merged: installs Opera Neon from the vendor's endpoint and prints
# what it leaves.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')
$out = Join-Path $env:RUNNER_TEMP 'probe.out'
& {
  $exe = Join-Path $env:RUNNER_TEMP 'neon-setup.exe'
  & curl.exe -sSL -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -m 300 -D (Join-Path $env:RUNNER_TEMP 'h.txt') -o $exe 'https://net.geo.opera.com/opera_neon/stable/windows'
  Get-Content (Join-Path $env:RUNNER_TEMP 'h.txt') | Select-String -Pattern 'content-disposition|content-length|location'
  "size $((Get-Item $exe).Length)"
  $sig = Get-AuthenticodeSignature $exe
  "signature $($sig.Status) $($sig.SignerCertificate.Subject)"
  "version $((Get-Item $exe).VersionInfo.ProductName) $((Get-Item $exe).VersionInfo.ProductVersion)"
  $p = Start-Process -FilePath $exe -ArgumentList '--silent --allusers=0 --launchopera=0 --setdefaultbrowser=0 --import-browser-data=0' -PassThru
  if (-not $p.WaitForExit(600000)) { 'installer still running after 600s'; Stop-Process -Id $p.Id -Force }
  "installer exit $($p.ExitCode)"
  Start-Sleep -Seconds 10
  '=== uninstall keys'
  foreach ($root in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
      $v = Get-ItemProperty $_.PSPath
      if ("$($_.PSChildName) $($v.DisplayName) $($v.Publisher)" -match 'Opera|Neon') {
        "$root\$($_.PSChildName) | $($v.DisplayName) | $($v.DisplayVersion) | $($v.Publisher) | $($v.InstallLocation) | $($v.UninstallString)"
      }
    }
  }
  '=== files'
  foreach ($d in (Join-Path $env:LOCALAPPDATA 'Programs'), $env:LOCALAPPDATA, $env:ProgramFiles, $env:APPDATA) {
    Get-ChildItem $d -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Opera|Neon' } | ForEach-Object { $_.FullName; Get-ChildItem $_.FullName -ErrorAction SilentlyContinue | Select-Object -First 15 | ForEach-Object { "   $($_.Name)" } }
  }
  '=== osquery programs'
  & $env:OSQI --json "SELECT name, version, publisher, install_location, identifying_number FROM programs WHERE name LIKE '%Opera%' OR name LIKE '%Neon%'"
  '=== osquery processes'
  & $env:OSQI --json "SELECT name, path FROM processes WHERE path LIKE '%Opera%' OR path LIKE '%Neon%'"
  '=== scheduled tasks and services'
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'Opera|Neon' } | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }
  Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Opera|Neon' } | ForEach-Object { $_.Name }
} *>&1 | Out-File -FilePath $out -Encoding ascii
& python (Join-Path $PSScriptRoot 'emit.py') $out
exit 0
