# 102-windows-claude-native -- Claude Code from its own installer, installed and running.
#
# Apart from 101, because one binary name installed two ways cannot share a host: the npm
# global and the native installer both answer to `claude` (the 71/84 rule on Linux).
#
# THE INSTALLER WRITES ~\.local\bin\claude.exe, and the process runs from that file rather
# than from ~\.local\share\claude\versions\ as on Linux, so `binaries` and `process_paths`
# each take that path as a Windows value (survey run 40393754308).
#
# `claude mcp serve` is the running process: it serves MCP on stdin, and a hidden window's
# console never ends its input, so it runs until the job does.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

[void](Invoke-Retry 'the Claude Code installer' {
  Invoke-Try 'the Claude Code installer' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy',
    'Bypass', '-Command', 'irm https://claude.ai/install.ps1 | iex')
})
$claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
if (-not (Test-Path $claude)) {
  Write-Host "FAIL: the installer left no $claude"
  exit 1
}
Start-Process $claude -ArgumentList 'mcp serve' -WindowStyle Hidden
Start-Sleep -Seconds 10
exit 0
