#!/bin/bash
# PROBE ONLY (review of #179, 2026-11-24): installs and prints what was left. Never merged.
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
here="$(cd "$(dirname "$0")" && pwd)"
note() { echo "::notice title=$1::$(printf '%s' "$2" | tr '\n' '~' | cut -c1-3800)"; }
need_curl
ls -A ~ | sort > /tmp/home-before

echo "=== npm deepseek-tui: latest, and 0.8.39, the last version that declares a bin"
need_node 22
latest_ver=$(npm view deepseek-tui@latest version 2>&1 | tail -1)
latest_bin=$(npm view deepseek-tui@latest bin --json 2>&1 | tr -d '\n' | cut -c1-200)
old_bin=$(npm view deepseek-tui@0.8.39 bin --json 2>&1 | tr -d '\n' | cut -c1-200)
sudo_maybe npm install -g --no-fund --no-audit deepseek-tui@0.8.39 > /tmp/ds.log 2>&1; r1=$?; tail -8 /tmp/ds.log
root=$(npm root -g)
bins=$(ls -la "$(npm prefix -g)/bin" 2>&1 | grep -i deepseek | awk '{print $9,$10,$11}' | tr '\n' ' ')
pk=$(ls -la "$root/deepseek-tui/bin" 2>&1 | awk '{print $5,$9}' | tr '\n' ' ')
v=$(timeout 30 deepseek --version </dev/null 2>&1 | head -2 | tr '\n' ' ')
ls -A ~ | sort > /tmp/home-v
timeout 60 deepseek exec "say hi" </dev/null > /tmp/dsx.log 2>&1; rx=$?
ls -A ~ | sort > /tmp/home-x
timeout 30 deepseek -p "say hi" </dev/null > /tmp/dsp.log 2>&1; rp=$?
ls -A ~ | sort > /tmp/home-p
note deepseek-npm "rc=$r1 latest=$latest_ver latest_bin=$latest_bin old_bin=$old_bin bins=$bins pkgbin=$pk ver=$v new_after_version=$(comm -13 /tmp/home-before /tmp/home-v | tr '\n' ' ') exec_rc=$rx exec_out=$(tail -3 /tmp/dsx.log) new_after_exec=$(comm -13 /tmp/home-before /tmp/home-x | tr '\n' ' ') p_rc=$rp p_out=$(tail -2 /tmp/dsp.log) new_after_p=$(comm -13 /tmp/home-before /tmp/home-p | tr '\n' ' ')"
note deepseek-dirs "$(for d in ~/.deepseek ~/.codewhale ~/.config/deepseek* ~/.local/share/deepseek*; do [ -e "$d" ] && echo "$d: $(ls -A "$d" | head -15 | tr '\n' ' ')"; done) install_log=$(tail -4 /tmp/ds.log)"

sudo -n /usr/bin/osqueryi --json < osquery/dist/discovery-linux.sql > /tmp/probe.json 2>/dev/null
rows=$(python3 "$here/filter.py" /tmp/probe.json)
echo "$rows"
note rows-fast "$(echo "$rows" | head -40)"

echo "=== container images"
n=0
for img in ghcr.io/codewhale-hq/codewhale:latest ghcr.io/hmbown/codewhale:latest ghcr.io/muvon/octomind:latest; do
  n=$((n + 1))
  docker pull "$img" > /tmp/pull.log 2>&1; rc=$?; tail -2 /tmp/pull.log
  note "image-$n" "$img rc=$rc $(tail -1 /tmp/pull.log) size=$(docker image inspect "$img" --format '{{.Size}}' 2>&1) arch=$(docker image inspect "$img" --format '{{.Architecture}}' 2>&1) created=$(docker image inspect "$img" --format '{{.Created}}' 2>&1) tags=$(docker image inspect "$img" --format '{{.RepoTags}}' 2>&1) labels=$(docker image inspect "$img" --format '{{json .Config.Labels}}' 2>&1)"
done
docker images --format '  {{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}'
sudo -n osquery/bin/discover --deep > /tmp/deep.json 2>/tmp/deep.err; echo "deep rc=$?"; tail -3 /tmp/deep.err
rows=$(python3 "$here/filter.py" /tmp/deep.json)
echo "$rows"
note rows-deep "$(echo "$rows" | head -40)"
# SKIP, so nothing is asserted: the notices above are the result.
exit 3
