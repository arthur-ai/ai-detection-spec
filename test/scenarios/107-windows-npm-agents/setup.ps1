# 107-windows-npm-agents -- Cline, Continue and Kilo Code as npm globals on Windows.
#
# Apart from 101, which forbids cline and continue: its packages share a vendor or a word
# with these, and 101 is where that control is held. The same prefix handling as 101.
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

Reset-NpmPrefix
Install-NpmGlobal @('cline', '@continuedev/cli', '@kilocode/cli')
exit 0
