#!/bin/zsh
# Demo row: Ollama (23 devices) + demo step 2, expanding to show real local models.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew

# Both install shapes, deliberately. homebrew_packages covers formulae AND casks - it has
# a `type` column - so this exercises both the Cellar and the Caskroom path in one run.
# (This originally existed because we believed casks were unmodelled. They are not.)
brew install --cask ollama-app
brew install ollama || true          # may warn about the shared `ollama` symlink

# `open -a` needs an Aqua session and there isn't one over SSH, so start the server
# directly. This opens the listener on 11434 and creates ~/.ollama. The launchd job is
# a first-GUI-launch side effect and is therefore NOT asserted by this scenario.
OLLAMA="$(command -v ollama || echo /Applications/Ollama.app/Contents/Resources/ollama)"
"$OLLAMA" serve >/tmp/ollama.log 2>&1 &
for i in $(seq 1 30); do curl -fsS http://127.0.0.1:11434/ >/dev/null 2>&1 && break; sleep 2; done
curl -fsS http://127.0.0.1:11434/ >/dev/null || { echo "FAIL: ollama never listened on 11434" >&2; exit 1; }

"$OLLAMA" pull llama3.2:1b                                                  # library namespace
"$OLLAMA" pull hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M || true    # NON-library namespace
sleep 5
