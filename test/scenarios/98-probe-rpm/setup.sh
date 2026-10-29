#!/bin/bash
# THROWAWAY PROBE, never merged: 96's setup and assertion, reported through annotations,
# because the container job's log is not readable from where this was written.
HERE="$(cd "$(dirname "$0")" && pwd)"
main() {
  bash -x "$HERE/../96-linux-cli-agents-npm/setup.sh"; echo "setup rc=$?"
  ls -la /root/.qoder 2>&1; ls /usr/local/lib/node_modules /usr/local/lib/node_modules/@* 2>&1
  node --version 2>&1; npm --version 2>&1; which node npm 2>&1
  osqueryi --json < "$HERE/../../../osquery/dist/discovery-linux.sql" > /tmp/o96.json 2>/tmp/e96.txt; echo "osq rc=$?"
  head -c 600 /tmp/e96.txt
  python3 -c 'import json,sys; rows=json.load(open("/tmp/o96.json")); [print(r["kind"], r["id"]) for r in rows if r["kind"] in ("npm","file") and ("qoder" in r["id"] or "@" in r["id"])]'
  "$HERE/../../assert.sh" /tmp/o96.json "$HERE/../96-linux-cli-agents-npm/expected.json"; echo "assert rc=$?"
}
main 2>&1 | grep -v -E '^\+\+* (retry|try|sudo_maybe|local|for wait|\[|echo)' | tail -150 > /tmp/probe.out
python3 "$HERE/emit.py" /tmp/probe.out
exit 0
