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
import json
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
# The recording step must pass --os and --arch. Without them the step still succeeds and
# still writes an observation -- just one that cannot say which platform produced it, which
# is the entire reason the os matrix axis exists. That is exactly how it shipped: the edit
# adding the flags aborted, the matrix edit landed, and eleven CI runs recorded no platform
# at all while looking perfectly healthy.
#
# EVERY RECORDING STEP, not the first one. This checked `_sc.index("--record")` -- the
# first occurrence only -- while three jobs record: macOS, Linux and Fedora. A flag dropped
# from the second or third was invisible to it, which is the same shape as the bug it was
# written for. Anchored on the invocation rather than the bare flag, because the commit
# message at the foot of the collect job also contains the words "--record".
_sc = (root / "scenarios.yml").read_text()
_steps = [m.end() for m in re.finditer(r"agent_status\.py --record \S+\.json", _sc)]
if not _steps:
    print("FAIL: scenarios.yml records no observations at all. Coverage would freeze at "
          "whatever is committed, while every run looked green.")
    failed = True
for _n, _at in enumerate(_steps, 1):
    _step = _sc[_at:][:400]
    for _flag in ("--os", "--arch", "--run-id"):
        if _flag not in _step:
            print(f"FAIL: scenarios.yml recording step {_n} of {len(_steps)} omits "
                  f"{_flag}. The step succeeds and writes a record that cannot say which "
                  f"platform or which run produced it -- which is the whole point of the "
                  f"os matrix axis, and of being able to prove an identifier was once "
                  f"real after CI stops reproducing it.")
            failed = True

_doc = yaml.safe_load((root / "scenarios.yml").read_text())

# EVERY JOB'S MATRIX, NOT ONE NAMED JOB.
#
# This used to read jobs.scenario.strategy.matrix.scenario and nothing else. The moment a
# second job existed -- and Linux needs two, because `container:` applies per job -- every
# scenario under them would have been invisible to the on-disk check below. That is the
# direction this comment already calls "the worse one": it looks tested.
_jobs = {}
for _job, _spec in _doc["jobs"].items():
    _names = (((_spec.get("strategy") or {}).get("matrix") or {}).get("scenario"))
    if _names:
        _jobs[_job] = set(_names)
_matrix = set().union(*_jobs.values()) if _jobs else set()

# WHICH PLATFORM EACH JOB CAN ACTUALLY RUN, read off the job rather than assumed. A
# scenario listed under a job whose runner cannot host it is the failure a flat set check
# cannot see: the name is present, the suite looks complete, and every run of it skips.
def _job_platform(spec):
    if spec.get("container"):
        return "linux"
    runs = str(spec.get("runs-on", ""))
    labels = (((spec.get("strategy") or {}).get("matrix") or {}).get("os") or [])
    text = " ".join([runs] + [str(x) for x in labels])
    if "macos" in text:
        return "darwin"
    if "ubuntu" in text or "fedora" in text:
        return "linux"
    return None

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

# The pairing, in the direction that matters: a scenario's declared platform must match
# the platform of every job that lists it.
for _job, _names in sorted(_jobs.items()):
    _plat = _job_platform(_doc["jobs"][_job])
    if _plat is None:
        print(f"FAIL: scenarios.yml job {_job!r} has a scenario matrix but no runner this "
              f"check can read a platform from. Add the label or the container image.")
        failed = True
        continue
    for _name in sorted(_names & _on_disk):
        _exp = repo / "test" / "scenarios" / _name / "expected.json"
        if not _exp.exists():
            continue
        _want = json.loads(_exp.read_text()).get("platform")
        if _want != _plat:
            print(f"FAIL: {_name} declares platform {_want!r} but job {_job!r} runs on "
                  f"{_plat}. It would skip on every run while looking scheduled.")
            failed = True

# A `deep: true` SCENARIO MUST BE UNDER A JOB THAT RUNS THE DEEP ARTIFACT, and a job that
# runs it must have one.
#
# `image` rows come from dist/discovery-deep.sql and from nowhere else -- no composed
# artifact carries containers.sql, because it is `expensive`. So a deep scenario listed
# under a job whose query step runs only the composed artifact fails on the image count,
# on a runner, with a message about a row count rather than about the artifact. This moves
# it to lint, where the person who moved the scenario can see why.
#
# The reverse is checked too: a `--deep` branch no scenario reaches is payload nobody can
# read, which is what happened to the retired `model` branch and to the dropped `ext` kind.
for _job, _names in sorted(_jobs.items()):
    _runs = " ".join(_s.get("run", "") or "" for _s in _doc["jobs"][_job].get("steps", []))
    _honours = "--deep" in _runs
    _deep = set()
    for _name in sorted(_names & _on_disk):
        _exp = repo / "test" / "scenarios" / _name / "expected.json"
        if _exp.exists() and json.loads(_exp.read_text()).get("deep"):
            _deep.add(_name)
    for _name in sorted(_deep):
        if not _honours:
            print(f"FAIL: {_name} declares \"deep\": true but job {_job!r} runs only the "
                  f"composed artifact. It would fail on the image count instead of here.")
            failed = True
    if _honours and not _deep:
        print(f"FAIL: scenarios.yml job {_job!r} runs the deep artifact and no scenario it "
              f"lists declares \"deep\": true -- a branch nothing reaches.")
        failed = True

# EVERY INPUT THE GENERATED DOC IS BUILT FROM MUST BE IN docs.yml's PATH TRIGGER.
#
# THIS IS THE ONE THAT FAILS BY GOING QUIET, which is this repo's signature failure mode.
# docs/agents.md is regenerated by a push-triggered workflow with a `paths:` filter. If an
# input is missing from that filter, the doc simply stops being regenerated when that input
# changes -- no error, no red build, just a page that describes a catalog which has moved
# on. `--check` in lint catches the drift eventually, but only once someone happens to
# change something else that IS in the filter.
_docs = root / "docs.yml"
if _docs.exists():
    _dd = yaml.safe_load(_docs.read_text())
    # `on` is parsed by PyYAML as the boolean True, which is a YAML 1.1 quirk worth
    # knowing before debugging a KeyError here.
    _trig = _dd.get("on") or _dd.get(True) or {}
    _paths = ((_trig.get("push") or {}).get("paths")) or []
    # Read the inputs off agent_status.py rather than listing them here, so this check
    # cannot fall behind the thing it checks.
    _st = (repo / "tools" / "agent_status.py").read_text()
    _needed = set()
    for _m in re.finditer(r'ROOT\s*/\s*"([^"]+)"(?:\s*/\s*"([^"]+)")?(?:\s*/\s*"([^"]+)")?',
                          _st):
        _parts = [x for x in _m.groups() if x]
        if _parts and _parts[0] in ("catalog", "docs", "test", "bin"):
            _needed.add("/".join(_parts))
    for _need in sorted(_needed):
        # docs/agents.md is the OUTPUT, and docs/ is deliberately excluded from the
        # trigger so the commit this workflow pushes does not re-trigger it.
        if _need.startswith("docs/agents.md"):
            continue
        # Compare on the LITERAL prefix of each trigger path -- everything up to its
        # first glob -- so `test/scenarios/*/expected.json` is understood to cover
        # `test/scenarios`, and `catalog/**` to cover `catalog/agents.yaml`. Either
        # direction counts: the trigger may be broader than the input or narrower.
        _covered = False
        for pth in _paths:
            _lit = str(pth).split("*")[0].rstrip("/")
            if _lit and (_need.startswith(_lit) or _lit.startswith(_need)):
                _covered = True
                break
        if not _covered:
            print(f"FAIL: docs.yml's path trigger does not cover {_need!r}, which "
                  f"tools/agent_status.py reads to render docs/agents.md. The doc would "
                  f"silently stop being regenerated when that file changes.")
            failed = True

# --- the release skill's asset list, against what release.yml actually uploads -------------
# A CHECKLIST CATCHES THAT ONCE; THIS CATCHES IT EVERY TIME -- the same argument as the trigger
# check above, and it has already been paid for. The skill told a releaser to expect NINE assets
# and to treat a missing one as a broken release; the one-file bundles made it eleven and nothing
# said so. check_doc_numbers.py reads README, CLAUDE and CONTRIBUTING and checks CATALOG numbers,
# and no gate reads .claude/ at all -- so the one number a releaser verifies the release against
# was the one number nothing derived.
_NUMWORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
             "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
             "fourteen": 14, "fifteen": 15, "sixteen": 16}
# root is .github/workflows, so the repo root is two up. This read root.parent and the
# block skipped itself in silence -- the shape it exists to catch, found by mutating the
# count and watching the gate stay green.
_skill = root.parent.parent / ".claude" / "skills" / "release" / "SKILL.md"
_rel = root / "release.yml"
if _skill.exists() and _rel.exists():
    _run = ""
    for _job in (yaml.safe_load(_rel.read_text()) or {}).get("jobs", {}).values():
        for _step in _job.get("steps", []):
            if "gh release upload" in str(_step.get("run", "")):
                _run = str(_step["run"])
    # Basenames, because the skill names what lands on the release page and the workflow names
    # where each file came from -- artifacts/ai-discovery-darwin.sh uploads as its own name.
    _uploaded = {t.rsplit("/", 1)[-1]
                 for t in re.findall(r"[\w./-]+\.(?:sql|conf|yaml|sh)\b", _run)}
    _uploaded |= {t.rsplit("/", 1)[-1] for t in re.findall(r"\bbin/[\w-]+", _run)}
    _claim = re.search(r"\*\*(\w+) assets\*\*(.*?)\.\n", _skill.read_text(), re.S)
    if not _run:
        print("FAIL: release.yml has no step running `gh release upload`. The release skill "
              "tells a releaser to check the attached assets against a list; nothing produces "
              "them any more.")
        failed = True
    elif not _claim:
        print("FAIL: the release skill no longer states an asset count. It is the check a "
              "releaser runs against a published release; derive it or drop the instruction.")
        failed = True
    else:
        _word = _claim.group(1).lower()
        _said = _NUMWORDS.get(_word, int(_word) if _word.isdigit() else None)
        _named = set(re.findall(r"`([\w.-]+)`", _claim.group(2)))
        if _named != _uploaded:
            print(f"FAIL: the release skill names assets release.yml does not upload, or "
                  f"misses some: only in the skill {sorted(_named - _uploaded)}, only in the "
                  f"workflow {sorted(_uploaded - _named)}.")
            failed = True
        elif _said != len(_uploaded):
            print(f"FAIL: the release skill says {_claim.group(1)!r} assets and release.yml "
                  f"uploads {len(_uploaded)}. A releaser checks a published release against "
                  f"that number.")
            failed = True

if not failed:
    print(f"workflows: ok, {len(list(root.glob('*.y*ml')))} parse and declare jobs, "
          f"every referenced path exists, {len(_matrix)} scenarios across "
          f"{len(_jobs)} job(s) in CI ({len(EXCLUDED)} excluded by name)")
sys.exit(1 if failed else 0)
