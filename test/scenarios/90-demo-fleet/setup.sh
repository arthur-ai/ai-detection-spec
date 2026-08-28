#!/bin/zsh
# Everything at once - one VM carrying the full demo narrative.
# Use this to generate realistic seed evidence for UP-4898.
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
for s in 10-desktop-apps 20-cli-agents 30-local-models 40-browser 60-persistence 50-autonomous; do
  echo "--- $s ---"; zsh "$D/$s/setup.sh" || echo "WARN: $s had failures"
done
