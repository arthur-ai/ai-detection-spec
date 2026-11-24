# 114-windows-grok-bot -- Grok Bot on Windows, installed and running.
#
# Through the installer the app's update feed names, an electron-builder NSIS per-user
# setup, which writes ~\AppData\Local\Programs\Grok Bot and a GUID Uninstall key under
# HKEY_CURRENT_USER. Launched, because the running process is what process_paths reads.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

try {
  $url = (Invoke-RestMethod 'https://api2.cursor.sh/updates/api/update/win32-x64-user/sand/0.0.0/stable').url
  $exe = Join-Path $env:RUNNER_TEMP 'GrokBotSetup.exe'
  if (Get-Download $url $exe) { [void](Install-Exe 'Grok Bot' $exe '/S') }
} catch { Write-Host "WARN: Grok Bot's update feed did not answer: $_" }

$app = Join-Path $env:LOCALAPPDATA 'Programs\Grok Bot\Grok Bot.exe'
if (Test-Path $app) {
  Start-Process $app
  Start-Sleep -Seconds 20
} else {
  Write-Host "WARN: the installer left no $app"
}
exit 0
