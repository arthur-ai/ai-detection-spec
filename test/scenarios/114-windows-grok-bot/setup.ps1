# 114-windows-grok-bot -- Grok Bot on Windows, installed and running.
#
# Through the installer the app's update feed names, an electron-builder NSIS per-user
# setup, which writes ~\AppData\Local\Programs\Grok Bot and a GUID Uninstall key under
# HKEY_CURRENT_USER. Launched, because the running process is what process_paths reads.
#
# BOUNDED, NOT Install-Exe, for the reason 111's header gives: Start-Process -Wait waits for
# every process an installer starts.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

# The feed is retried like a download. Invoke-Retry reads its body's output as the verdict,
# so the URL comes back through $script:url and the reason for a failure through Write-Host.
$feed = 'https://api2.cursor.sh/updates/api/update/win32-x64-user/sand/0.0.0/stable'
$script:url = ''
$named = Invoke-Retry "reading Grok Bot's update feed" {
  try { $script:url = [string](Invoke-RestMethod $feed).url }
  catch { Write-Host "  the update feed: $_" }
  [bool]$script:url
}
$exe = Join-Path $env:RUNNER_TEMP 'GrokBotSetup.exe'
if (-not $named) {
  Write-Host "WARN: Grok Bot's update feed named no installer"
} elseif (Get-Download $script:url $exe) {
  [void](Invoke-Bounded 'the Grok Bot installer' 10 $exe @('/S'))
}

$app = Join-Path $env:LOCALAPPDATA 'Programs\Grok Bot\Grok Bot.exe'
if (Test-Path $app) {
  Start-Process $app
  Start-Sleep -Seconds 20
} else {
  Write-Host "WARN: the installer left no $app"
}
exit 0
