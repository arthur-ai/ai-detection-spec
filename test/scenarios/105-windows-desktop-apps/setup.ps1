# 105-windows-desktop-apps -- Claude Desktop, Cursor and Windsurf on Windows.
#
# Claude Desktop ships as a signed MSIX, which Server 2025 installs without the Store; its
# identity is the package family name. Cursor and Windsurf ship Inno Setup user installers,
# whose identity is the Uninstall key they write under HKEY_CURRENT_USER.
#
# LAUNCHED, BOTH OF THE ONES THAT NEED IT: Claude Desktop registers its browser bridge on
# first run, and a running Cursor is what process_paths reads. Windsurf is installed only.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$dl = Join-Path $env:RUNNER_TEMP 'desktop'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

$msix = Join-Path $dl 'claude.msix'
if (Get-Download 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect' $msix) {
  try { Add-AppxPackage -Path $msix } catch { Write-Host "WARN: Claude Desktop failed: $_" }
}
$cursor = Join-Path $dl 'cursor.exe'
if (Get-Download 'https://api2.cursor.sh/updates/download/golden/win32-x64-user/cursor/latest' $cursor) {
  [void](Install-Exe 'Cursor' $cursor $InnoSilent)
}
# Windsurf's update endpoint names the current user installer.
try {
  $ws = (Invoke-RestMethod 'https://windsurf-stable.codeium.com/api/update/win32-x64-user/stable/latest').url
  $windsurf = Join-Path $dl 'windsurf.exe'
  if (Get-Download $ws $windsurf) { [void](Install-Exe 'Windsurf' $windsurf $InnoSilent) }
} catch { Write-Host "WARN: Windsurf's update endpoint did not answer: $_" }

$pkg = Get-AppxPackage Claude -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
  $app = (Get-AppxPackageManifest $pkg).Package.Applications.Application.Id | Select-Object -First 1
  Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($pkg.PackageFamilyName)!$app"
}
$exe = Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe'
if (Test-Path $exe) { Start-Process $exe }
Start-Sleep -Seconds 30
exit 0
