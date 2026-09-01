#!/usr/bin/env python3
"""Parse every workflow file; assert it declares a name and jobs, and that the repo files
its steps invoke actually exist.

A workflow that does not parse does not fail CI: it disappears from the checks list
entirely, so the pull request shows every remaining check green. That is worse than a
red build, and it is how a performance gate shipped without running. GitHub falls back
to displaying the filename when it cannot read `name`, which is the visible symptom.

THE SECOND CHECK EXISTS BECAUSE NOT EVERY WORKFLOW RUNS PER PULL REQUEST. scenarios.yml
runs on dispatch and on a schedule, so a step of it can reference a file that a pull
request deleted while every check on that pull request stays green. That happened:
tools/measure_payload.py was removed, scenarios.yml still called it, CI was green, and the
next scheduled matrix failed on "[Errno 2] No such file or directory" -- caught only
because the release checklist says to read the last Scenarios run before tagging.

A checklist catches that once. This catches it every time.
"""
import pathlib
import re
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

    # Every repo-relative script a `run:` block invokes must exist. Deliberately narrow:
    # only paths under directories this repo owns, and skipped where the step is plainly
    # creating the file rather than running it.
    repo = root.parent.parent
    owned = r"(?:tools|test|bin|dist|queries|catalog)"
    steps = [s for job in doc.get("jobs", {}).values() for s in job.get("steps", [])]
    for step in steps:
        run = step.get("run", "") or ""
        for match in re.finditer(rf"(?<![\w./-])({owned}/[\w./-]+)", run):
            ref = match.group(1).rstrip(".,;:\"'")
            if ref.endswith("/") or "*" in ref:
                continue
            if re.search(rf"(?:>|>>|-o|--output|cp\s+\S+\s+){re.escape(ref)}", run):
                continue
            if not (repo / ref).exists():
                print(f"FAIL: {path.name} step {step.get('name', '?')!r} invokes {ref}, "
                      f"which does not exist. A workflow that does not run per pull "
                      f"request fails on a schedule instead.")
                failed = True

# EVERY SCENARIO DIRECTORY IS EITHER IN THE CI MATRIX OR EXPLICITLY EXCLUDED.
#
# The matrix names scenarios as strings, and the step that runs them is templated --
# `test/scenarios/${{ matrix.scenario }}/setup.sh` -- so the path check above cannot see
# them. That gap let a DELETED scenario sit in the matrix, where CI would have failed
# trying to run it, and let a scenario exist with no CI coverage at all. The second is the
# worse one: it looked tested, because a local VM run had passed it.
EXCLUDED = {
    "90-demo-fleet": "a demo fleet, not a regression test: it installs the whole catalogue "
                     "to populate a walkthrough, and asserts breadth rather than a signature",
}
_doc = yaml.safe_load((root / "scenarios.yml").read_text())
_matrix = set(_doc["jobs"]["scenario"]["strategy"]["matrix"]["scenario"])
_on_disk = {d.name for d in (repo / "test" / "scenarios").iterdir() if d.is_dir()}
for _name in sorted(_matrix - _on_disk):
    print(f"FAIL: scenarios.yml runs {_name!r}, which is not a directory under "
          f"test/scenarios/. CI would fail trying to run it.")
    failed = True
for _name in sorted(_on_disk - _matrix - set(EXCLUDED)):
    print(f"FAIL: test/scenarios/{_name}/ is not in the scenarios.yml matrix and is not "
          f"EXCLUDED. It would never run in CI, while looking tested to anyone who ran it "
          f"locally.")
    failed = True

if not failed:
    print(f"workflows: ok, {len(list(root.glob('*.y*ml')))} parse and declare jobs, "
          f"every referenced path exists, {len(_matrix)} scenarios in CI "
          f"({len(EXCLUDED)} excluded by name)")
sys.exit(1 if failed else 0)
