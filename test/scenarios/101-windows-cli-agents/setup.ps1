# 101-windows-cli-agents -- CLI agents installed as npm globals on Windows.
#
# Each npm value is the only witness for its agent here: nothing else in this scenario names
# Claude Code, Codex, Gemini CLI or Copilot CLI. The globals land under %APPDATA%\npm, the
# prefix npm itself defaults to and the one osquery's npm_packages searches; the runner image
# moves it elsewhere, so Reset-NpmPrefix moves it back.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

Reset-NpmPrefix
Install-NpmGlobal @('@anthropic-ai/claude-code', '@openai/codex', '@google/gemini-cli',
                    '@github/copilot')
exit 0
