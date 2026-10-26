# Helpers for the Windows scenarios' setup.ps1, which dot-source this file. Windows
# PowerShell 5.1, the one every Windows machine has, and ASCII only: 5.1 reads a BOM-less
# script as ANSI. Defines functions and does nothing else when sourced.
#
# THE CONTRACT IS guest-linux.sh's. An install that fails WARNS and carries its own output,
# so the assertion names the missing agent instead of an aborted setup naming none; exit 3
# is SKIP, for an environment that cannot host the scenario, and never what running out of
# retries means. test/lint.sh holds Invoke-Retry's schedule and messages to retry()'s.
#
# EVERY setup.ps1 ENDS IN AN EXPLICIT `exit`. Run with -File, a script that falls off its
# end exits 0 whatever its last command did.
#
# A HELPER THAT RETURNS A VERDICT PRINTS WITH Write-Host. Whatever reaches the pipeline joins
# the return value, and a warning line beside $false is a non-empty array, which `if` reads
# as success.

$ProgressPreference = 'SilentlyContinue'   # 5.1 draws a progress bar per download, slowly

function Invoke-Retry([string]$Label, [scriptblock]$Body) {
  foreach ($wait in 15, 45, 'done') {
    if (& $Body) { return $true }
    if ($wait -eq 'done') { break }
    [Console]::Error.WriteLine("      retrying $Label in ${wait}s"); Start-Sleep -Seconds $wait
  }
  [Console]::Error.WriteLine("WARN: $Label failed after three attempts")
  return $false
}

# Run a native command; on failure say so WITH its output and exit code, because a warning
# with no reason is indistinguishable from one nobody can act on. True on exit 0.
function Invoke-Try([string]$Label, [string]$Exe, [string[]]$ArgList) {
  $out = & $Exe @ArgList 2>&1 | Out-String
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    Write-Host "WARN: $Label failed (exit $rc). Its output follows, because a warning with no"
    Write-Host "      reason is indistinguishable from one nobody can act on:"
    $out.TrimEnd() -split "`r?`n" | ForEach-Object { Write-Host "      $_" }
  }
  return ($rc -eq 0)
}

# curl.exe, the real one: in 5.1 `curl` is an alias for Invoke-WebRequest.
function Get-Download([string]$Url, [string]$Dest) {
  Invoke-Retry "downloading $Url" {
    Invoke-Try "downloading $Url" 'curl.exe' @('--retry', '2', '-fsSL', '-A',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', '-o', $Dest, $Url)
  }
}

# An installer, waited for. 3010 is Windows Installer's "succeeded, reboot required".
function Install-Exe([string]$Label, [string]$Path, [string]$ArgLine) {
  $p = Start-Process -FilePath $Path -ArgumentList $ArgLine -Wait -PassThru
  if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    Write-Host "WARN: $Label failed (installer exit $($p.ExitCode))"
    return $false
  }
  return $true
}

# Inno Setup's silent flags, which the VS Code family's user installers take.
$InnoSilent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /MERGETASKS=!runcode'

# npm's own default global prefix, %APPDATA%\npm, which is where osquery's npm_packages
# looks. The runner image moves it to C:\npm\prefix, where no global would be read, and
# through the environment: `npm config set prefix` left it there (survey run 40396366136).
# Children inherit this process's variable. Prints what npm resolves, so a prefix that did
# not move says so here rather than as four missing globals at the assertion.
function Reset-NpmPrefix {
  $prefix = Join-Path $env:APPDATA 'npm'
  New-Item -ItemType Directory -Force -Path $prefix | Out-Null
  $env:NPM_CONFIG_PREFIX = $prefix
  Write-Host "npm prefix: $(& npm.cmd config get prefix)"
}

function Install-NpmGlobal([string[]]$Packages) {
  foreach ($pkg in $Packages) {
    [void](Invoke-Retry "npm install -g $pkg" {
      Invoke-Try "npm install -g $pkg" 'npm.cmd' @('install', '-g', '--no-fund', '--no-audit', $pkg)
    })
  }
}

function Install-VSCode {
  $exe = Join-Path $env:RUNNER_TEMP 'vscode-setup.exe'
  if (-not (Get-Download 'https://update.code.visualstudio.com/latest/win32-x64-user/stable' $exe)) { return $false }
  return (Install-Exe 'VS Code' $exe $InnoSilent)
}

function Install-VSCodeExtension([string[]]$Ids) {
  $code = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
  foreach ($id in $Ids) {
    [void](Invoke-Retry "installing $id" {
      Invoke-Try "installing $id" $code @('--install-extension', $id, '--force')
    })
  }
}

# A local, non-administrator account with a real profile. A first logon is what creates the
# profile; Start-Process -Credential starts the secondary-logon service it needs.
function New-ScenarioUser([string]$Name) {
  $pw = ConvertTo-SecureString ('Scenario-' + [guid]::NewGuid().ToString('N') + '!') -AsPlainText -Force
  New-LocalUser -Name $Name -Password $pw -PasswordNeverExpires | Out-Null
  $cred = New-Object System.Management.Automation.PSCredential($Name, $pw)
  [void](Start-Process cmd.exe -ArgumentList '/c exit 0' -Credential $cred -LoadUserProfile `
                       -WorkingDirectory 'C:\' -Wait -PassThru)
  return $cred
}

# A command line run as that user, waited for, with their profile and hive loaded.
function Invoke-AsUser([System.Management.Automation.PSCredential]$Cred, [string]$CmdLine) {
  $p = Start-Process cmd.exe -ArgumentList "/c $CmdLine" -Credential $Cred -LoadUserProfile `
                     -WorkingDirectory 'C:\' -Wait -PassThru
  return ($p.ExitCode -eq 0)
}

# SKIP: the environment cannot host this scenario, said with the reason.
function Exit-Skip([string]$Why) {
  Write-Host "SKIP: $Why"
  exit 3
}

# `--os` and `--arch` for tools/agent_status.py --record. The build, not the UBR: a monthly
# cumulative update would otherwise split one OS into twelve. The arch is the machine's, read
# where emulation cannot rename it, in uname's spelling.
function Get-ScenarioOs {
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $edition = if ($cv.InstallationType -eq 'Server') { 'server' } else { 'client' }
  $caption = (Get-CimInstance Win32_OperatingSystem).Caption
  $release = if ($caption -match '(20\d\d|10|11)\b') { $Matches[1] } else { 'unknown' }
  $native = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
  $arch = @{ AMD64 = 'x86_64'; ARM64 = 'arm64' }[$native]
  if (-not $arch) { $arch = $native.ToLower() }
  Write-Output "WIN_OS=windows-$edition-$release-$($cv.CurrentBuild)"
  Write-Output "WIN_ARCH=$arch"
}
