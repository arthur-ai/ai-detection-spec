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

$exe = Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe'
if (Test-Path $exe) { Start-Process $exe }
# THE BRIDGE NEEDS A CHROME PROFILE TO BRIDGE TO. Both survey runs had one, from Chrome for
# Testing, and Claude Desktop wrote the key within 30 seconds; here, with none, it ran for two
# minutes and wrote nothing (PR 127's second run). So Chrome runs once first, headless, which
# is enough to create its user data directory, and then the key is waited for.
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (Test-Path $chrome) {
  $p = Start-Process $chrome -PassThru -ArgumentList '--headless=new --no-first-run --no-default-browser-check --disable-gpu about:blank'
  Start-Sleep -Seconds 15
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $chrome } |
    Stop-Process -Force -ErrorAction SilentlyContinue
}
Write-Host "Chrome profile: $(Test-Path (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Local State'))"
$bridge = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_browser_extension'
$pkg = Get-AppxPackage Claude -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
  $app = (Get-AppxPackageManifest $pkg).Package.Applications.Application.Id | Select-Object -First 1
  Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($pkg.PackageFamilyName)!$app"
  foreach ($i in 1..60) {
    if (Test-Path $bridge) { break }
    Start-Sleep -Seconds 2
  }
  if (Test-Path $bridge) { Write-Host "Claude Desktop registered its bridge after about $(2 * $i)s" }
  else {
    Write-Host 'WARN: Claude Desktop registered no bridge in 120s. Its processes:'
    Get-Process claude -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $($_.Path)" }
  }
}
Start-Sleep -Seconds 10
exit 0
