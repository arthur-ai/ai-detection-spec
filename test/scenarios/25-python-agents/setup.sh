#!/bin/zsh
# Agents that ship on PyPI, installed the way people actually install Python CLI tools.
#
# This is the largest single blind spot the query had. python_packages is deliberately
# excluded for performance (15.6s, no push-down), and the design justified that with
# "zero Tier A matches" -- but that was measured on a machine with none of these
# installed. aider, litellm, crewai, langgraph, open-interpreter and most MCP servers
# ship on PyPI, and several ship ONLY there.
#
# uv is used rather than pipx because it is a single static binary with no Python
# prerequisite, so the scenario does not depend on whatever python3 the guest happens
# to have.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install uv
# --python 3.12 is required, not cosmetic: aider-chat depends on scipy, which has no
# wheel for the guest's Python 3.14 and falls back to a source build that dies on a
# missing OpenBLAS. A real user on 3.14 hits exactly this, so pinning keeps the scenario
# deterministic rather than hostage to whichever interpreter the image ships.
uv tool install --python 3.12 aider-chat || { echo "FAIL: aider-chat install failed" >&2; exit 1; }
uv tool install litellm                  || { echo "FAIL: litellm install failed" >&2; exit 1; }
uv tool list 2>/dev/null | sed 's/^/  /'
ls -d "$HOME/.local/share/uv/tools/"*/ 2>/dev/null | sed 's/^/  dir: /'
