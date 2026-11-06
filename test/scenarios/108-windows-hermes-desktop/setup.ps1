# 108-windows-hermes-desktop -- Hermes Desktop for Windows, the signed MSIX bundle.
#
# The vendor's download is an .appinstaller descriptor, which App Installer follows to the
# msixbundle it names. Both are read here as App Installer would read them: the stable
# feed first, then the bundle its MainBundle element points at, installed with
# Add-AppxPackage, which Server 2025 runs without the Store. The bundle carries the agent,
# Python and the CLI's execution aliases, so it is an install of Hermes and not a client.
#
# NOT LAUNCHED: the package family name is the identity, and it is read off `programs`
# installed or not running. A packaged app runs from C:\Program Files\WindowsApps, which is
# outside every home, so a running one would add no row anyway.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$dl = Join-Path $env:RUNNER_TEMP 'hermes-desktop'
New-Item -ItemType Directory -Force -Path $dl | Out-Null
$feed = Join-Path $dl 'stable.appinstaller'
if (-not (Get-Download 'https://hermes-assets.nousresearch.com/releases/win32/stable/stable.appinstaller' $feed)) {
  Write-Host 'WARN: the Hermes Desktop feed did not download'
  exit 0
}
$uri = ([xml](Get-Content -Raw $feed)).AppInstaller.MainBundle.Uri
Write-Host "bundle: $uri"
$bundle = Join-Path $dl 'hermes.msixbundle'
if ($uri -and (Get-Download $uri $bundle)) {
  try { Add-AppxPackage -Path $bundle } catch { Write-Host "WARN: Hermes Desktop failed: $_" }
}
Get-AppxPackage -Name 'NousResearch.*' | Format-List Name, PackageFamilyName, Publisher, Version
exit 0
