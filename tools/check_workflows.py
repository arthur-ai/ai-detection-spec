#!/usr/bin/env python3
"""Parse every workflow file and assert it declares a name and at least one job.

A workflow that does not parse does not fail CI: it disappears from the checks list
entirely, so the pull request shows every remaining check green. That is worse than a
red build, and it is how a performance gate shipped without running. GitHub falls back
to displaying the filename when it cannot read `name`, which is the visible symptom.
"""
import pathlib
import sys

try:
    import yaml
except ImportError:
    print("skip: pyyaml not installed, cannot validate workflows")
    sys.exit(0)

failed = False
root = pathlib.Path(__file__).resolve().parent.parent / ".github" / "workflows"
for path in sorted(root.glob("*.y*ml")):
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        where = f" at line {mark.line + 1}" if mark else ""
        print(f"FAIL: {path.name} does not parse{where}: {getattr(exc, 'problem', exc)}")
        failed = True
        continue
    if not doc.get("name"):
        print(f"FAIL: {path.name} declares no name, so it lists by filename")
        failed = True
    if not doc.get("jobs"):
        print(f"FAIL: {path.name} declares no jobs, so it silently does nothing")
        failed = True

if not failed:
    print(f"workflows: ok, {len(list(root.glob('*.y*ml')))} parse and declare jobs")
sys.exit(1 if failed else 0)
