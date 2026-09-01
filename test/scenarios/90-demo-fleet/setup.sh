#!/bin/zsh
# Everything at once - one VM carrying the full demo narrative.
# Use this to generate realistic seed evidence for UP-4898.
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
# 11-perplexity-desktop is listed explicitly: it used to be the seventh cask inside
# 10-desktop-apps and was split out for its macOS >= 15 floor, so the demo fleet has to
# name it or it would quietly lose Perplexity Desktop from the table.
for s in 10-desktop-apps 11-perplexity-desktop 20-cli-agents 30-local-models 40-browser 60-persistence 50-autonomous; do
  echo "--- $s ---"; zsh "$D/$s/setup.sh" || echo "WARN: $s had failures"
done
