# PROBE ONLY (review of #179, 2026-11-24): installs and prints what was left. Never merged.
. "$PSScriptRoot\..\..\lib\guest-windows.ps1"
function Note([string]$T, [string]$M) {
  $m = ($M -replace "`r?`n", ' ~ ')
  if ($m.Length -gt 3800) { $m = $m.Substring(0, 3800) }
  Write-Host "::notice title=$T::$m"
}
$before = Get-ChildItem $HOME -Force | ForEach-Object Name
$ukeys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
function Keys([string]$Pat) {
  $o = foreach ($k in $ukeys) { Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath
      if ("$($p.DisplayName) $($_.PSChildName)" -match $Pat) { "$k\$($_.PSChildName) [$($p.DisplayName)] [$($p.DisplayVersion)] [$($p.Publisher)] [$($p.InstallLocation)]" } } }
  return ($o -join ' ; ')
}
function Rows([string]$Tag) {
  $sql = Join-Path (Get-Location) 'osquery\dist\discovery-windows.sql'
  $out = Join-Path $env:RUNNER_TEMP "probe-$Tag.json"
  $osqi = $env:OSQI -replace '/', '\'
  & "$env:SystemRoot\System32\cmd.exe" /s /c "`"$osqi`" --json < `"$sql`" > `"$out`""
  $rows = & python "$PSScriptRoot\filter.py" $out
  $rows | ForEach-Object { Write-Host "  [$Tag] $_" }
  Note "rows-$Tag" (($rows | Select-Object -First 45) -join "`n")
}
function Procs { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -match 'Craft' }) }

# --- Craft Agents: the vendor's installer, then what is running and when ~\.craft-agent appears.
$dot = Join-Path $HOME '.craft-agent'
$ps1 = Join-Path $env:RUNNER_TEMP 'craft.ps1'
[void](Get-Download 'https://thecraftagents.com/install-app.ps1' $ps1)
$t0 = Get-Date
$r1 = Invoke-Bounded 'craft install-app.ps1' 15 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1)
$tInstalled = [int]((Get-Date) - $t0).TotalSeconds
$line = @(); $first = ''
for ($i = 0; $i -lt 36; $i++) {
  $ps = Procs
  $line += "t+$([int]((Get-Date) - $t0).TotalSeconds - $tInstalled)s procs=$($ps.Count) dot=$(Test-Path $dot)"
  if (-not $first -and $ps.Count) { $first = ($ps | ForEach-Object { "$($_.Name)|$($_.Path)" } | Sort-Object -Unique) -join ' ; ' }
  if ((Test-Path $dot) -and $i -ge 2) { break }
  Start-Sleep -Seconds 5
}
Note 'craft-timeline' "vendor_ps1=$r1 install_took=${tInstalled}s procs=$first :: $($line -join ' , ')"
$programs = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -ErrorAction SilentlyContinue | ForEach-Object Name
$exes = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Filter '*.exe' -Recurse -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object FullName
Note 'craft-files' "dot=$((Get-ChildItem $dot -Force -ErrorAction SilentlyContinue | ForEach-Object Name) -join ' ') programs=$($programs -join ' ; ') exes=$($exes -join ' ; ') keys=$(Keys 'Craft')"
Rows 'craft-running'
$log = @(); $quiet = 0
for ($i = 0; $i -lt 24 -and $quiet -lt 3; $i++) {
  $ps = Procs
  if ($ps.Count) {
    $quiet = 0; $log += "pass$i stopped=$($ps.Count)"
    $ps | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
  } else { $quiet++ }
  Start-Sleep -Seconds 5
}
Note 'craft-stop' "$($log -join ' , ') left=$((Procs).Count)"
Rows 'craft-stopped'

# --- Codewhale: the NSIS setup its docs give IT admins, silent.
$cws = Join-Path $env:RUNNER_TEMP 'CodeWhaleSetup.exe'
$r2 = $false
if (Get-Download 'https://github.com/codewhale-hq/CodeWhale/releases/latest/download/CodeWhaleSetup.exe' $cws) {
  $r2 = Invoke-Bounded 'CodeWhaleSetup /S' 10 $cws @('/S')
}
$cwd = Join-Path $env:LOCALAPPDATA 'Programs\CodeWhale'
$files = Get-ChildItem $cwd -Recurse -ErrorAction SilentlyContinue | Select-Object -First 25 | ForEach-Object FullName
Note 'codewhale-nsis' "rc=$r2 keys=$(Keys 'CodeWhale') files=$($files -join ' ; ') dot=$(Test-Path (Join-Path $HOME '.codewhale'))"
Rows 'codewhale-nsis'

# --- Codewhale through winget, if the runner has it.
$wg = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($wg) {
  $r3 = Invoke-Bounded 'winget install HunterBown.CodeWhale' 10 $wg.Source @('install', '--id', 'HunterBown.CodeWhale',
        '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
  $links = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links') -ErrorAction SilentlyContinue | ForEach-Object Name
  $pk = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -ErrorAction SilentlyContinue | ForEach-Object Name
  Note 'codewhale-winget' "winget=$($wg.Source) rc=$r3 keys=$(Keys 'CodeWhale') links=$($links -join ' ; ') packages=$($pk -join ' ; ')"
} else { Note 'codewhale-winget' 'no winget.exe on this runner' }

# --- Scoop: codewhale from the main bucket, octomind from Muvon's.
$si = Join-Path $env:RUNNER_TEMP 'scoop-install.ps1'
if (Get-Download 'https://get.scoop.sh' $si) {
  [void](Invoke-Bounded 'the Scoop installer' 10 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $si, '-RunAsAdmin'))
  $scoop = Join-Path $HOME 'scoop\shims\scoop.cmd'
  $cmd = "$env:SystemRoot\System32\cmd.exe"
  if (Test-Path $scoop) {
    [void](Invoke-Bounded 'scoop install codewhale' 10 $cmd @('/c', $scoop, 'install', 'codewhale'))
    [void](Invoke-Bounded 'scoop bucket add muvon' 5 $cmd @('/c', $scoop, 'bucket', 'add', 'muvon', 'https://github.com/Muvon/scoop-bucket'))
    [void](Invoke-Bounded 'scoop install muvon/octomind' 10 $cmd @('/c', $scoop, 'install', 'muvon/octomind'))
  }
  $sh = Get-ChildItem (Join-Path $HOME 'scoop\shims') -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'codew|octomind' } | ForEach-Object FullName
  $ap = Get-ChildItem (Join-Path $HOME 'scoop\apps') -ErrorAction SilentlyContinue | ForEach-Object Name
  Note 'scoop' "scoop=$(Test-Path $scoop) shims=$($sh -join ' ; ') apps=$($ap -join ' ; ') keys=$(Keys 'scoop|octomind')"
}

$after = Get-ChildItem $HOME -Force | ForEach-Object Name
Note 'home-new' (($after | Where-Object { $before -notcontains $_ }) -join ' ')
Rows 'final'
# SKIP, so nothing is asserted: the notices above are the result.
exit 3
