#!/usr/bin/env bash
# Static checks on the catalog, the matcher, the scenarios and the repo's own gates, then
# osquery/test/lint.sh for the osquery binding. No VM, and no network beyond a loopback socket
# the telemetry suite binds for itself — 11.4s measured here, so CI can gate on it and a VM
# run never burns 20 minutes on a typo. It was about one second before test_telemetry.py
# joined it, and most of the difference is that suite waiting out a sender it has pointed
# at an endpoint which never answers. That wait is the assertion: shortening it would mean
# not proving the bound.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
# A TEST RUN IS NOT A USE, and bin/classify sends one usage event per run. `CI` already
# suppresses it on a runner, but a scenario guest is a fresh VM or container that inherits
# nothing, and a maintainer's own machine has no CI set at all -- so the suite would post
# an event for every fixture it classifies and the field data would be mostly us. Set
# explicitly rather than relied upon: see docs/telemetry.md.
export AI_DISCOVERY_TELEMETRY=0

# THE CHECKER IS CHOSEN BY THE SHEBANG, not by one rule for every scenario.
#
# The macOS scenarios are zsh because that is macOS's default shell; the Linux ones are
# bash because that is what a Linux runner and a container both have. Checking a bash
# script with `zsh -n` mostly works, which is the problem -- it would pass until someone
# used a bash-only construct, and then report a syntax error in the wrong dialect.
#
# zsh is still REQUIRED rather than skipped when missing: letting the check dissolve into
# "command not found" would leave every macOS scenario unchecked while the suite stayed
# green. The linter runs on ubuntu in CI, which is why ci.yml apt-installs zsh.
if ! command -v zsh >/dev/null; then
  echo "FAIL: zsh not found. It is needed to syntax-check the macOS scenario scripts."
  echo "      macOS ships it; on Debian/Ubuntu: sudo apt-get install -y zsh"
  fail=1
else
  for f in "$HERE"/scenarios/*/setup.sh "$HERE"/lib/guest.sh "$HERE"/lib/guest-linux.sh; do
    case "$(head -1 "$f")" in
      *zsh*)  zsh -n  "$f" || { echo "FAIL: zsh syntax in $f";  fail=1; } ;;
      *bash*) bash -n "$f" || { echo "FAIL: bash syntax in $f"; fail=1; } ;;
      *) echo "FAIL: $f has no zsh or bash shebang, so nothing can syntax-check it"
         fail=1 ;;
    esac
  done
fi
for f in "$HERE"/run.sh "$HERE"/run-ec2.sh "$HERE"/run-gce.sh "$HERE"/lib/vm.sh "$HERE"/lib/assert.sh ; do
  bash -n "$f" || { echo "FAIL: bash syntax in $f"; fail=1; }
done

# ONE WAY TO BECOME THE SCENARIO USER, and only one.
#
# test/lib/guest-linux.sh had two: as_user, which scrubs the environment with `env -i`, and
# try_user, which had grown its own `su - "$user" -c`. Fixing one and not the other cost
# three CI rounds, because the scenarios that used the wrong one failed with an error
# (EACCES on $XDG_CONFIG_HOME) that pointed at the tool rather than at the helper. Any new
# `su` in that file is that mistake again.
# CODE ONLY, not the comments that explain the mistake -- two of the three matches were
# the note describing the wrong form, and a check that counts its own documentation is a
# check nobody can satisfy.
_su_count=$(grep -vE '^\s*#' "$HERE/lib/guest-linux.sh" \
            | grep -cE '(^|[^a-z_-])su ' || true)
if [ "${_su_count:-0}" -gt 1 ]; then
  echo "FAIL: guest-linux.sh invokes \`su\` $_su_count times. as_user is the only place"
  echo "      that should: it is what scrubs the environment, and a second copy leaks the"
  echo "      caller's XDG_* to the scenario user. Route it through as_user."
  fail=1
else
  echo "guest-linux.sh: one way to become the scenario user"
fi

# ONE retry, IN TWO FILES. lib/guest.sh is the only file run.sh copies into a macOS guest,
# so the helper cannot be shared by sourcing, and two copies that drift is the shape of the
# su bug above. Held byte-identical instead, from `retry() {` to its closing brace.
_retry_body() { sed -n '/^retry() {$/,/^}$/p' "$1"; }
_retry_mac=$(_retry_body "$HERE/lib/guest.sh")
if [ -z "$_retry_mac" ] || [ "$_retry_mac" != "$(_retry_body "$HERE/lib/guest-linux.sh")" ]; then
  echo "FAIL: retry() in lib/guest.sh and lib/guest-linux.sh differ, or one is missing."
  echo "      They are one helper in two files; change both."
  fail=1
else
  echo "guest.sh, guest-linux.sh: one retry"
fi

# test/lib/assert.sh is sourced by test/assert.sh, test/run.sh and test/run-gce.sh. `bash -n`
# cannot see a function that is missing, and a scenario found exactly that: assert_match_sql
# was dropped in an edit, the file parsed, and every scenario went red at "command not found".
# The library sets -e, so the lookup runs with it switched back off and reports its own
# status; as an `&&` list under -e the failure came back as 0 and the check never fired.
_fns_missing="$(bash -c '. "'"$HERE"'/lib/assert.sh"; set +e; m=""
  for f in assert_counts assert_classified assert_match_sql; do
    type -t "$f" >/dev/null 2>&1 || m="$m $f"; done; printf "%s" "$m"')"
[ -z "$_fns_missing" ] \
  || { echo "FAIL: test/lib/assert.sh no longer defines:$_fns_missing (test/assert.sh calls them)"; fail=1; }

# THE MATCHER AND THE CATALOG TOOLS NEVER READ osquery/. They work on evidence rows from any
# binding; a check that needs the binding's files belongs to osquery/test/lint.sh. Code only:
# a docstring or comment may say where rows come from.
python3 - "$HERE/.." <<'BOUNDARY' || fail=1
import ast, pathlib, sys
root = pathlib.Path(sys.argv[1])
NEUTRAL = ["bin/classify", "tools/validate_catalog.py", "tools/agent_status.py",
           "tools/merge_observations.py", "tools/successor_candidates.py"]
bad = []
for name in NEUTRAL:
    tree = ast.parse((root / name).read_text())
    docs = {id(n.body[0].value) for n in ast.walk(tree)
            if isinstance(n, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))
            and n.body and isinstance(n.body[0], ast.Expr)
            and isinstance(n.body[0].value, ast.Constant)}
    for n in ast.walk(tree):
        if (isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docs
                and (n.value == "osquery" or n.value.startswith("osquery/"))):
            bad.append(f"{name}:{n.lineno}: names {n.value!r}")
for b in bad:
    print(f"FAIL: boundary -- {b}. The matcher and the catalog tools read no binding's files.")
if bad:
    sys.exit(1)
print(f"boundary: ok, {len(NEUTRAL)} catalog and matcher files name nothing under osquery/")
BOUNDARY

# The osquery binding's own checks: queries, artifacts, the endpoint scripts and the bundle.
"$HERE/../osquery/test/lint.sh" || fail=1

python3 "$HERE/../tools/validate_catalog.py" || fail=1
python3 "$HERE/../test/test_matcher.py" >/dev/null || { echo "FAIL: matcher tests"; fail=1; }
python3 "$HERE/../test/test_telemetry.py" >/dev/null || { echo "FAIL: telemetry tests"; fail=1; }
python3 "$HERE/../test/test_ci_scope.py" >/dev/null || { echo "FAIL: ci scope tests"; fail=1; }
python3 "$HERE/../tools/check_workflows.py" || fail=1
# docs/agents.md is generated from the catalog and its coverage, exactly as osquery/dist/ is
# generated from osquery/queries/. Gated here so a contributor sees it locally in seconds rather
# than finding out from a red PR -- and so the doc cannot quietly describe a catalog that
# has moved on without it, which is the same failure this repo keeps having in other forms.
# A SUBMODULE YOU DID NOT IMPORT. `import importlib.util` leaves importlib.machinery
# resolvable on a developer Mac -- something in site-packages has already imported it -- and
# raises AttributeError on a clean interpreter. Verified: `python3 -S -c "import
# importlib.util; importlib.machinery.SourceFileLoader"` fails here, plain python3 does not.
#
# It cost every scenario job in one CI run, in the step that records coverage, and no gate
# could have caught it because the local interpreter resolves the name perfectly.
python3 - "$HERE/.." <<'PYEOF' || fail=1
import ast, pathlib, sys

# Submodules that are NOT loaded by importing the parent package. os.path is absent from
# this list on purpose: it is bound as an attribute of os at interpreter start.
LAZY = {"importlib": {"machinery", "util", "resources", "metadata", "abc"},
        "concurrent": {"futures"},
        "xml": {"etree", "dom", "sax"},
        "collections": {"abc"}}
bad = []
# RECURSIVE, because the files this was written for moved a level down into osquery/tools/;
# a `*/*.py` glob kept passing after they had left its reach.
# TRACKED FILES ONLY. A recursive glob from the root also reads .claude/worktrees -- other
# checkouts of this repo -- and any venv or test artifact, so another worktree's bug could
# turn this lint red. Without git (a tarball), fall back to the glob minus hidden trees.
import subprocess
_root = pathlib.Path(sys.argv[1])
_ls = subprocess.run(["git", "-C", str(_root), "ls-files", "*.py"],
                     capture_output=True, text=True)
if _ls.returncode == 0:
    paths = [_root / p for p in sorted(_ls.stdout.split())]
else:
    paths = [p for p in sorted(_root.glob("**/*.py"))
             if not any(part.startswith(".") for part in p.relative_to(_root).parts)]
if not any(p.name == "render_match.py" for p in paths):
    print("FAIL: lazy imports: render_match.py is not among the files scanned, so the "
          "glob has lost the tree it was written for")
    sys.exit(1)
for path in paths:
    tree = ast.parse(path.read_text())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                imported.add(a.name)
                imported.add(a.name.split(".")[0])
    for node in ast.walk(tree):
        # Match the shape `parent.child.something`, i.e. Attribute(Attribute(Name)).
        if not (isinstance(node, ast.Attribute)
                and isinstance(node.value, ast.Attribute)
                and isinstance(node.value.value, ast.Name)):
            continue
        parent, child = node.value.value.id, node.value.attr
        if child in LAZY.get(parent, ()) and f"{parent}.{child}" not in imported:
            bad.append(f"{path}:{node.lineno}: uses {parent}.{child} but never "
                       f"imports it. Resolvable here, AttributeError on a clean "
                       f"interpreter -- add `import {parent}.{child}`.")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PYEOF

# --pending-ok ON BOTH, AND IT IS NOT A WEAKENING. This file is static: it reads the
# observations committed to the tree, and those are written by scenarios.yml's `collect`
# job, which is main-only so that a pull request cannot move recorded coverage. On the PR
# that ADDS a signature the observations therefore predate it, and a correctly covered
# identifier is indistinguishable here from one a scenario ran and failed to produce.
#
# Left strict, that made every signature PR red by construction, and the only available
# fix was to merge it anyway -- which teaches people that this red means nothing, and the
# next red is read the same way.
#
# What lint still refuses is the part it CAN answer: an identifier no CI scenario even
# claims. What it defers is whether a claimed one appeared, which is settled by the
# `coverage` job in scenarios.yml against that run's own observations. Both halves are
# gates, neither is advisory, and tools/agent_status.py's _pending() carries the argument.
python3 "$HERE/../tools/agent_status.py" --check --pending-ok || fail=1
# Nothing ships in the catalog without a real test.
python3 "$HERE/../tools/agent_status.py" --gate --pending-ok || fail=1
# Prose goes stale silently; generated pages cannot. This checks the numbers a human wrote.
python3 "$HERE/../tools/check_doc_numbers.py" || fail=1
# --json separately, because it exercises a code path --check does not. An unquoted
# YYYY-MM-DD in the catalog resolves to a datetime.date, which json.dumps cannot
# serialise -- so --json died while --check and --write, which never read the field,
# both passed clean. One gate per output format, or a format breaks unobserved.
python3 "$HERE/../tools/agent_status.py" --json >/dev/null \
  || { echo "FAIL: agent_status.py --json does not serialise"; fail=1; }

[ "$fail" -eq 0 ] && echo "lint: PASS" || echo "lint: FAIL"
exit "$fail"
