# 103-windows-vscode-agents -- agents that ship as VS Code extensions, on Windows.
#
# VS Code's user installer, then each extension by its marketplace id. vscode_extensions
# reports the same `name` on Windows as on Linux (survey run 40393754308), so these are the
# catalog's existing values read through the Windows branch.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

if (-not (Install-VSCode)) { exit 1 }
Install-VSCodeExtension @('saoudrizwan.claude-dev', 'Continue.continue',
                          'RooVeterinaryInc.roo-cline', 'kilocode.Kilo-Code',
                          'anthropic.claude-code', 'openai.chatgpt')
exit 0
