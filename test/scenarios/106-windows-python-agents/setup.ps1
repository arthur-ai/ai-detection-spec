# 106-windows-python-agents -- aider, installed from PyPI by pipx and by uv, on Windows.
#
# Each tool directory is named for the PACKAGE, aider-chat, and bin/classify's tool-dir match
# reads that name back (SPEC.md 6.4.6). Both installers, so both Windows layouts are proved:
# pipx's ~\AppData\Local\pipx\pipx\venvs\ and uv's ~\AppData\Roaming\uv\tools\.
#
# pipx ON ITS DEFAULTS: the runner image sets PIPX_HOME and PIPX_BIN_DIR machine-wide, to a
# directory under no home. And `--force` for uv, whose launcher would otherwise collide with
# the one pipx already wrote to ~\.local\bin (survey run 40396366136).
. (Join-Path $PSScriptRoot '..\..\lib\guest-windows.ps1')

Remove-Item Env:PIPX_HOME, Env:PIPX_BIN_DIR -ErrorAction SilentlyContinue
[void](Invoke-Try 'installing pipx and uv' 'python' @('-m', 'pip', 'install', '--quiet',
                                                      '--upgrade', 'pipx', 'uv'))
[void](Invoke-Retry 'pipx install aider-chat' {
  Invoke-Try 'pipx install aider-chat' 'python' @('-m', 'pipx', 'install', 'aider-chat')
})
[void](Invoke-Retry 'uv tool install aider-chat' {
  Invoke-Try 'uv tool install aider-chat' 'python' @('-m', 'uv', 'tool', 'install', '--force',
                                                     'aider-chat')
})
# `aider --just-check-update` is what writes ~\.aider, as 72-linux-python-agents runs it.
[void](Invoke-Try 'aider --just-check-update' (Join-Path $env:USERPROFILE '.local\bin\aider.exe') @('--just-check-update'))
Write-Host "~\.aider exists: $(Test-Path (Join-Path $env:USERPROFILE '.aider'))"
exit 0
