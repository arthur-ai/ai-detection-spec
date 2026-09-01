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
# litellm is installed DELIBERATELY and is NOT expected to be found: an LLM gateway an
# agent calls through is not an agent, and it was removed from the catalog for that. It
# stays here as a live negative control -- a real uv tool install that must produce a row
# and no finding. Remove it and nothing proves the classifier still declines it.
uv tool install litellm                  || { echo "FAIL: litellm install failed" >&2; exit 1; }
uv tool list 2>/dev/null | sed 's/^/  /'
ls -d "$HOME/.local/share/uv/tools/"*/ 2>/dev/null | sed 's/^/  dir: /'

# INVOKED, NOT JUST INSTALLED. A state directory does not exist until the agent runs once,
# which is why ~/.aider read DID NOT APPEAR while a scenario was installing aider on every run.
# `--version` is the smallest invocation that is not a no-op and needs no credentials.
#
# NOT ASSERTED. Whether this particular agent writes its state directory on --version is
# unmeasured, and asserting it before knowing would be a guess wearing a test's clothes.
# The run records what actually appeared; if the directory shows up, coverage reports it,
# and if it does not, the gap stays visible and honest.
command -v aider >/dev/null 2>&1 && (aider --version >/dev/null 2>&1 || true)
