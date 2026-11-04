# 104-windows-browser -- the browser-agent extensions, matched by id, on Windows.
#
# 45-claude-extension's method, which its comments explain: the Web Store's signed CRX,
# unpacked into a real profile the way Chrome unpacks it (test/lib/unpack_crx.py), then
# registered by Chrome for Testing launched once with --load-extension. Branded Chrome 137
# and later refuse that flag. The profile is the one osquery reads for branded Chrome,
# %LOCALAPPDATA%\Google\Chrome\User Data.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

# Every browser agent the catalog matches by id: extension-ids.txt is generated from it by
# tools/scenarios.py, which puts each agent in must_find through `every_extension`.
$ids = @(Get-Content (Join-Path $PSScriptRoot 'extension-ids.txt') |
  Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { ($_ -split ' ')[0] })
if ($ids.Count -eq 0) { Write-Host 'FAIL: extension-ids.txt lists no id'; exit 1 }
$udd = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
$dl = Join-Path $env:RUNNER_TEMP 'browser'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

$index = 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json'
try { $url = ((Invoke-RestMethod $index).channels.Stable.downloads.chrome | Where-Object { $_.platform -eq 'win64' }).url }
catch { Write-Host "FAIL: the Chrome for Testing index did not answer: $_"; exit 1 }
if (-not (Get-Download $url (Join-Path $dl 'cft.zip'))) { exit 1 }
# Windows' own tar, by path: run from the workflow's Git Bash, PATH finds MSYS's GNU tar
# first, which cannot read a zip.
& (Join-Path $env:SystemRoot 'System32\tar.exe') -xf (Join-Path $dl 'cft.zip') -C $dl
$chrome = Join-Path $dl 'chrome-win64\chrome.exe'
if (-not (Test-Path $chrome)) { Write-Host "FAIL: no Chrome for Testing at $chrome"; exit 1 }

# No answer for ANY id is the network, so SKIP. No answer for SOME is an extension the Web
# Store stopped serving, which must stay red: its agent's must_find fails and names it.
$dirs = @()
foreach ($id in $ids) {
  $crx = Join-Path $dl "$id.crx"
  $src = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=155.0&acceptformat=crx3&x=id%3D$id%26uc"
  if (-not (Get-Download $src $crx)) { continue }
  $ver = & python (Join-Path $PSScriptRoot '..\..\lib\unpack_crx.py') $crx $id (Join-Path $udd 'Default\Extensions')
  if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: could not unpack the CRX for $id"; exit 1 }
  $dirs += Join-Path $udd "Default\Extensions\$id\$($ver.Trim())_0"
  Write-Host "unpacked $id version $($ver.Trim())"
}
if ($dirs.Count -eq 0) { Exit-Skip 'the Web Store returned no CRX; no signed artifact to unpack' }

# One launch, with the flag, on a profile that does not exist yet; let it run, then stop it.
$p = Start-Process $chrome -PassThru -ArgumentList ('--headless=new --no-first-run ' +
  "--no-default-browser-check --disable-gpu `"--user-data-dir=$udd`" " +
  "`"--load-extension=$($dirs -join ',')`" about:blank")
Start-Sleep -Seconds 25
Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $chrome } |
  Stop-Process -Force
Start-Sleep -Seconds 3
if (-not (Test-Path (Join-Path $udd 'Default\Preferences'))) {
  Write-Host 'FAIL: Chrome for Testing wrote no Default\Preferences'
  exit 1
}

# THE OTHER END OF CLAUDE'S BRIDGE. Claude Desktop registers its native-messaging host under
# HKCU some time after its first launch -- with a Chrome profile carrying the Claude extension
# present, as here and in both survey runs. With neither (105-windows-desktop-apps, two runs)
# it registered nothing, so this is where the Windows nmh route is proved. Which of the two it
# needs is not measured.
$msix = Join-Path $dl 'claude.msix'
if (Get-Download 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect' $msix) {
  try { Add-AppxPackage -Path $msix } catch { Write-Host "WARN: Claude Desktop failed: $_" }
}
#
# READY MEANS THE MANIFEST, NOT THE KEY: the query follows the key's default value to the file
# it names. Waiting on the key alone, runs 41687070537 and 41691259793 logged it after 4s and
# then found no nmh row for it; whether the value or the file was late went unrecorded.
$bridge = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_browser_extension'
function Get-BridgeManifest {
  $m = (Get-ItemProperty $bridge -ErrorAction SilentlyContinue).'(default)'
  if ($m -and (Test-Path -LiteralPath $m -PathType Leaf)) { $m }
}
$pkg = Get-AppxPackage Claude -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
  $app = (Get-AppxPackageManifest $pkg).Package.Applications.Application.Id | Select-Object -First 1
  Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($pkg.PackageFamilyName)!$app"
  foreach ($i in 1..60) {
    if (Get-BridgeManifest) { break }
    Start-Sleep -Seconds 2
  }
  $manifest = Get-BridgeManifest
  if ($manifest) { Write-Host "Claude Desktop registered its bridge, $manifest, after about $(2 * $i)s" }
  else {
    $value = (Get-ItemProperty $bridge -ErrorAction SilentlyContinue).'(default)'
    Write-Host "WARN: Claude Desktop wrote no bridge manifest in 120s. Key: $(Test-Path $bridge), value: '$value'. Its processes:"
    Get-Process claude -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $($_.Path)" }
  }
}
exit 0
