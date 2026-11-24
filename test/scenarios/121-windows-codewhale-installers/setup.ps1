# 121-windows-codewhale-installers -- Codewhale through the two Windows installers that write
# an Uninstall key, installed and not run. Read off probe run 45468880057 on windows-2025.
#
#   CodeWhaleSetup.exe  its NSIS installer, silent (/S): per user, under
#                       %LOCALAPPDATA%\Programs\CodeWhale, and the key `CodeWhale` under HKCU
#   winget              HunterBown.CodeWhale, a portable package: a key named for the package
#                       and its source, and files where no query reads
#
# SEPARATE from 120-windows-craft-octomind-npm, where npm's package is Codewhale's only
# witness. The two installers share this host because each leaves a key of its own, which
# expected.json holds by name.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

$keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
# An attempt counts only if it left its key; 84 says why.
$setup = Join-Path $env:RUNNER_TEMP 'CodeWhaleSetup.exe'
[void](Invoke-Retry 'the Codewhale setup' {
  (Get-Download 'https://github.com/codewhale-hq/CodeWhale/releases/latest/download/CodeWhaleSetup.exe' $setup) -and
  (Invoke-Bounded 'the Codewhale setup' 10 $setup @('/S')) -and
  (Test-Path (Join-Path $keys 'CodeWhale'))
})

# By the key and not winget's exit code: a second attempt at an installed package exits
# non-zero. Without winget this WARNs, and the assertion names the missing key.
$wg = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($wg) {
  [void](Invoke-Retry 'winget install HunterBown.CodeWhale' {
    [void](Invoke-Bounded 'winget install HunterBown.CodeWhale' 10 $wg.Source @('install',
           '--id', 'HunterBown.CodeWhale', '--exact', '--source', 'winget',
           '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'))
    @(Get-ChildItem $keys | Where-Object { $_.PSChildName -like 'HunterBown.CodeWhale_*' }).Count -gt 0
  })
} else { Write-Host 'WARN: no winget.exe on this runner' }

# For the log: each key, and the one file of the setup's install the enumeration reads.
Get-ChildItem $keys | Where-Object { ($_.GetValue('DisplayName') -match 'CodeWhale') } |
  ForEach-Object { Write-Host "  uninstall: $($_.PSChildName) = $($_.GetValue('DisplayName')) $($_.GetValue('DisplayVersion'))" }
$un = Join-Path $env:LOCALAPPDATA 'Programs\CodeWhale\Uninstall.exe'
if (Test-Path $un) { Write-Host "  landed: $un" } else { Write-Host "WARN: no $un" }
exit 0
