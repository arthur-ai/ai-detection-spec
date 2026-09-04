#!/bin/bash
# The Linux twin of 25-python-agents, including the part that matters most: IT INSTALLS
# LiteLLM ON PURPOSE AND ASSERTS IT IS NOT FOUND.
#
# LiteLLM was removed from the catalog because it is a gateway an agent calls THROUGH,
# not an agent -- but its fixture rows were kept and the assertion inverted, because
# deleting the evidence with the signature leaves nothing to tell "correctly not an agent"
# from "route quietly broken". That is the ambiguity the dropped `ext` kind hid behind for
# months, and it is worth a real install on Linux as much as on macOS.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs python3 || true

# uv as the user, so the tool directories land under /home/dana/.local/share/uv/tools/
# and exercise bin/classify's TOOL_DIR bridge under a Linux home root. aider installs as
# `aider-chat` while its state dir is ~/.aider, and the bridge is the only thing that
# makes those two the same agent.
try_user "the uv installer" 'curl -fsSL https://astral.sh/uv/install.sh | sh' || true
for pkg in aider-chat hermes-agent litellm; do
  try_user "uv tool install $pkg" \
    "\$HOME/.local/bin/uv tool install --python 3.12 $pkg" || true
done

# aider writes ~/.aider on a VERSION CHECK, not on a model call: is_first_run_of_new_version()
# writes installs.json, so --just-check-update needs no API key, no network credential and
# no repository. A first attempt used --version, which exits before anything is written and
# looked like an auth wall.
try_user "aider --just-check-update, which is what writes ~/.aider" \
  '$HOME/.local/bin/aider --just-check-update' || true
try_user "hermes --version" '$HOME/.local/bin/hermes --version' || true
echo "--- uv tool directories that landed:"
as_user_ls "$(getent passwd "$SCENARIO_USER" | cut -d: -f6)/.local/share/uv/tools" | head
