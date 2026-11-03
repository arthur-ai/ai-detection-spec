# 103-windows-vscode-agents -- agents that ship as VS Code extensions, on Windows.
#
# VS Code's user installer, then each extension by its marketplace id. vscode_extensions
# reports the same `name` on Windows as on Linux (survey run 40393754308), so these are the
# catalog's existing values read through the Windows branch.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

if (-not (Install-VSCode)) { exit 1 }
Install-VSCodeExtension @('saoudrizwan.claude-dev', 'Continue.continue', 'kilocode.Kilo-Code',
                          'anthropic.claude-code', 'openai.chatgpt')

# ROO CODE IS UNPUBLISHED and still served by URL; 85-linux-vscode-agents says why.
$roo = Join-Path $env:RUNNER_TEMP 'roo-cline.vsix'
if (Get-Download 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/RooVeterinaryInc/vsextensions/roo-cline/3.54.0/vspackage' $roo -Compressed) {
  Install-VSCodeExtension @($roo)
}
exit 0
