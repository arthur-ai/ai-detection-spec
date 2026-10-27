# 101-windows-cli-agents -- CLI agents installed as npm globals on Windows.
#
# Each npm value is the only witness for its agent here: nothing else in this scenario names
# Claude Code, Codex, Gemini CLI or Copilot CLI. The globals land under %APPDATA%\npm, the
# prefix npm itself defaults to and the one osquery's npm_packages searches; the runner image
# moves it elsewhere, so Reset-NpmPrefix moves it back.
#
# `codex --version` is what writes ~\.codex, as 71-linux-cli-agents runs it on Linux.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

Reset-NpmPrefix
Install-NpmGlobal @('@anthropic-ai/claude-code', '@openai/codex', '@google/gemini-cli',
                    '@github/copilot')
[void](Invoke-Try 'codex --version' (Join-Path $env:APPDATA 'npm\codex.cmd') @('--version'))
Write-Host "~\.codex exists: $(Test-Path (Join-Path $env:USERPROFILE '.codex'))"
exit 0
