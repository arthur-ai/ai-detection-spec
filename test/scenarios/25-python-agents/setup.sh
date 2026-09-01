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
# Hermes Agent, the third route this agent ships through and the one that lands in the
# Python ecosystem. 21-cli-agents-homebrew installs it from the formula on a DIFFERENT
# machine, deliberately: both routes put a `hermes` on PATH, and two routes claiming one
# binary name cannot share a host.
#
# --python 3.12 IS LOAD-BEARING, exactly as it is for aider above, and for a reason read off
# the wheel rather than assumed: hermes-agent declares requires_python >=3.11,<3.14, and the
# guest ships 3.14. Without the pin uv resolves nothing and the install fails on a machine
# where the agent is perfectly installable.
#
# WARN rather than exit, unlike the two above. This install is the newest thing in the
# scenario and PyPI is the route the project has moved PAST -- 0.19.0 there against a
# Homebrew stable of 2026.8.31 -- so a resolution failure here is a fact about that
# distribution, not a reason to redden aider's coverage with it. The assertion is where a
# missing agent gets reported, because it names which one.
uv tool install --python 3.12 hermes-agent || echo "WARN: hermes-agent install failed"
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
# ~/.aider NEEDS NO CREDENTIALS, which is worth stating because the obvious assumption was
# that it did. Reading aider's own source settles it: Path.home()/".aider" holds
# installs.json, analytics.json and oauth-keys.env, and installs.json is written by
# is_first_run_of_new_version() -- a version check, not a model call.
#
# `--version` exits before that check runs, which is why the earlier attempt produced
# nothing. `--just-check-update` runs the check and exits, needing no API key, no network
# credential and no repository.
# uv installs into ~/.local/bin, which uv itself warns is NOT on PATH here. So the binary
# is addressed by path rather than by name -- `command -v aider` is false in this guest and
# was true on the CI runner, which is why this passed in CI and failed in the VM.
#
# And it cannot end on a false test. A SCRIPT EXITS WITH THE STATUS OF ITS LAST COMMAND, so
# `command -v aider && (...)` as the final line returns 1 when the binary is not on PATH --
# and run.sh reports "scenario setup failed (exit 1)" after every install has succeeded,
# naming nothing. Measured, because I first blamed `set -e` and that was wrong: the same
# line with anything after it exits 0.
AIDER="$HOME/.local/bin/aider"
[ -x "$AIDER" ] && { "$AIDER" --just-check-update >/dev/null 2>&1 || true; } || true
[ -d "$HOME/.aider" ] && echo "  ~/.aider created by the first-run check" || \
  echo "  ~/.aider still absent after --just-check-update"

# HERMES, INVOKED THE SAME WAY AND FOR THE SAME REASON. A uv tool install writes three
# commands into ~/.local/bin -- hermes, hermes-agent, hermes-acp -- so the binaries route is
# proven by the install alone. ~/.hermes is the one that is not: HERMES_HOME is created at
# install time only by the vendor's curl installer, which puts its checkout inside it. Under
# uv the code lives in the tool venv, so the directory can only appear on first run.
#
# NOT ASSERTED, for the same reason as aider: whether `--version` is enough to create it is
# unmeasured, and asserting it before knowing would be a guess wearing a test's clothes. The
# run prints what actually happened, so the gap stays visible either way.
HERMES="$HOME/.local/bin/hermes"
[ -x "$HERMES" ] && { "$HERMES" --version >/dev/null 2>&1 || true; } || true
ls -1 "$HOME/.local/bin/" 2>/dev/null | grep -i '^hermes' | sed 's/^/  bin: /'
[ -d "$HOME/.hermes" ] && echo "  ~/.hermes created by --version" || \
  echo "  ~/.hermes still absent after --version"
