# 104-windows-browser -- the browser-agent extensions, matched by id, on Windows.
#
# 45-claude-extension's method, which its comments explain: the Web Store's signed CRX,
# unpacked into a real profile the way Chrome unpacks it (test/lib/unpack_crx.py), then
# registered by Chrome for Testing launched once with --load-extension. Branded Chrome 137
# and later refuse that flag. The profile is the one osquery reads for branded Chrome,
# %LOCALAPPDATA%\Google\Chrome\User Data.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

# Claude, HARPA AI, Monica, Sider, Merlin: every browser agent the catalog matches by id.
$ids = @('fcoeoabgfenejglbffodgkkbkcdhcgfn', 'eanggfilgoajaocelnaflolkadkeghjp',
         'ofpnmcalabcbjgholdjcjblkibolbppb', 'difoiogjjojoaoomphldepapgpbgkhkb',
         'camppjleccjaphfdbohjdohecfnoikec')
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
exit 0
