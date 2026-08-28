#!/usr/bin/env bash
# Static checks on the query and scenarios. No VM, no network — runs in about a second,
# so CI can gate on it and a VM run never burns 20 minutes on a typo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

for q in "$HERE"/../queries/*.sql; do
python3 - "$q" <<'PY' || fail=1
import re, sys
raw = open(sys.argv[1]).read()
sql = "\n".join(l for l in raw.splitlines() if not l.strip().startswith("--"))

if ";" in sql:
    print(f"FAIL: {sys.argv[1].split('/')[-1]}: a query fragment must not contain a semicolon. "
          "The build joins files with UNION ALL; a stray semicolon ends the composed "
          "query early and silently turns the rest into a second statement."); sys.exit(1)
stmts = [sql]

# A UNION ALL arm with the wrong column count is the failure mode this guards. osqueryi
# does reject it, but only after a VM boot and an osquery install — about twenty minutes
# later than here.
widths = []
for part in re.split(r"\bUNION ALL\b", stmts[0]):
    if "SELECT" not in part.upper(): continue
    frag = part[part.upper().index("SELECT"):]
    frag = frag[:re.search(r"\bFROM\b", frag, re.I).start()]
    # Commas inside string literals are not column separators. Counting them is how
    # this check first reported a false positive on `CASE WHEN .. THEN ',<all_urls>'`.
    depth = 0; n = 1; instr = False
    for ch in frag:
        if ch == "'": instr = not instr
        elif instr: continue
        elif ch == "(": depth += 1
        elif ch == ")": depth -= 1
        elif ch == "," and depth == 0: n += 1
    widths.append((re.search(r"'(\w+)'", frag).group(1), n))

bad = [(k, v) for k, v in widths if v != 6]
if bad:
    print(f"FAIL: {sys.argv[1].split('/')[-1]}: wrong column count (want 6): {bad}"); sys.exit(1)
print(f"ok: {sys.argv[1].split('/')[-1]}: {len(widths)} branches, 6 columns each")

# Two UNION ALLs with nothing between them. Removing a branch and leaving its keyword
# behind is a syntax error osqueryi only reports at runtime -- and the failing query then
# returns instantly, which reads as a SPEEDUP if you happen to be timing it.
if re.search(r"UNION\s+ALL\s+UNION\s+ALL", sql, re.I):
    print("FAIL: two consecutive UNION ALL - a branch was removed without its keyword"); sys.exit(1)
if re.search(r"UNION\s+ALL\s*;?\s*$", sql.strip(), re.I):
    print("FAIL: trailing UNION ALL with no branch after it"); sys.exit(1)

# Semicolons inside comments break naive statement splitting in the EA wrapper.
for i, l in enumerate(raw.splitlines(), 1):
    if l.strip().startswith("--") and ";" in l:
        print(f"FAIL: semicolon in comment at line {i}"); sys.exit(1)
PY
done

python3 - "$HERE" <<'PY' || fail=1
import glob, json, os, sys
here = sys.argv[1]
KINDS = {"app","npm","brew","daemon","port","ext","file","nmh","model"}
covered, bad = set(), False
for f in sorted(glob.glob(os.path.join(here, "scenarios/*/expected.json"))):
    name = os.path.basename(os.path.dirname(f))
    d = json.load(open(f))
    counts = d.get("counts", {})
    missing = KINDS - set(counts)
    if missing:
        print(f"FAIL: {name} does not pin {sorted(missing)}"); bad = True
    for k, v in counts.items():
        if k not in KINDS:
            print(f"FAIL: {name} pins unknown kind {k!r}"); bad = True
        if isinstance(v, str) and not v.startswith(">="):
            print(f"FAIL: {name}.{k} = {v!r}, want an int or '>=N'"); bad = True
        if (isinstance(v, int) and v > 0) or isinstance(v, str):
            covered.add(k)
    if not os.access(os.path.join(os.path.dirname(f), "setup.sh"), os.X_OK):
        print(f"FAIL: {name}/setup.sh is not executable"); bad = True

# Every kind must be exercised somewhere, or a branch ships untested — which is the exact
# state four of these were in before this harness existed.
never = KINDS - covered
if never:
    print(f"FAIL: no scenario exercises {sorted(never)}"); bad = True
if bad: sys.exit(1)
print(f"ok: {len(KINDS)} kinds, every one exercised by at least one scenario")
PY

# The scenario scripts are zsh because that is macOS's default shell and they only
# ever run there. The linter itself runs anywhere, so require zsh explicitly rather
# than letting every check dissolve into "command not found" and still look like a
# syntax error in the scripts.
if ! command -v zsh >/dev/null; then
  echo "FAIL: zsh not found. It is needed to syntax-check the scenario scripts."
  echo "      macOS ships it; on Debian/Ubuntu: sudo apt-get install -y zsh"
  fail=1
else
  for f in "$HERE"/scenarios/*/setup.sh "$HERE"/lib/guest.sh; do
    zsh -n "$f" || { echo "FAIL: zsh syntax in $f"; fail=1; }
  done
fi
for f in "$HERE"/run.sh "$HERE"/lib/vm.sh "$HERE"/lib/assert.sh ; do
  bash -n "$f" || { echo "FAIL: bash syntax in $f"; fail=1; }
done
python3 "$HERE/../tools/validate_catalog.py" || fail=1
python3 "$HERE/../tools/build.py" --check || fail=1
python3 "$HERE/../test/test_matcher.py" >/dev/null || { echo "FAIL: matcher tests"; fail=1; }
python3 "$HERE/../tools/check_workflows.py" || fail=1
python3 "$HERE/../tools/check_no_catalog.py" || fail=1

[ "$fail" -eq 0 ] && echo "lint: PASS" || echo "lint: FAIL"
exit "$fail"
