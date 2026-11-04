#!/usr/bin/env python3
"""Decide what a diff can change, so CI pays only for that.

    python3 tools/ci_scope.py <base-ref-or-sha> <head-sha>
    python3 tools/ci_scope.py --paths README.md CLAUDE.md   # for tests
    python3 tools/ci_scope.py --scenarios <base> <head> [--summary <file>]
    python3 tools/ci_scope.py --scenarios --only 73-linux-deb 00-baseline   # a dispatch with names

Prints GITHUB_OUTPUT lines on stdout and the reason for each on stderr.

THE FIRST FORM ASKS WHETHER: `runtime=true` or `runtime=false`, for ci.yml, whose runtime
jobs are one runner each.

IT IS A DENY-LIST, AND THAT DIRECTION IS THE WHOLE SAFETY PROPERTY. An allow-list --
"run when osquery/queries/ or catalog/ changed" -- is a list that has to agree with the tree, and
a new directory nobody added to it would be SKIPPED rather than unmatched. That is the
`ext`-missing-from-`KIND_ROUTES` bug in a new place: invisible, and green. So the
question asked here is the other one, `is every changed path documentation`, and anything
unrecognised answers no and runs the suite.

WHY `.md`, AND WHAT ELSE. Every gate that READS a Markdown file -- check_doc_numbers,
check_workflows, agent_status, test_telemetry -- runs in the lint job, and lint is NOT
gated by this: it runs on every pull request as it always has, so documentation drift is
still caught on the commit that causes it. What is gated is the three things that need a
runner with osquery on it. runtime_inert() names the other paths none of those three
reaches -- a scenario's own files, the recorders, the scenario harnesses, the lint-only
checks, another workflow -- and test/test_ci_scope.py proves each against what the
runtime jobs actually run, the way it proves INERT for the scenario jobs.
`docs/blind-spots.yaml` is among them: tools/agent_status.py reads it, under lint. Until
2026-11-03 a one-file change to a Windows scenario's setup.ps1 booted all three runtime
VMs, twice.

NO DIFF MEANS RUN. A force-push, a new branch, a shallow clone that cannot reach the base
-- every one of them lands here as "cannot tell", and cannot-tell runs the suite. An
empty result must never be indistinguishable from a clean one, which in this file means a
diff nobody could compute must never read as a diff with nothing expensive in it.

THE SECOND FORM ASKS WHICH, for scenarios.yml, whose matrix is the bill: every scenario on
every macOS label and Linux image it lists. Each changed path is mapped to the scenarios that
can read it, the union runs, and every other scenario is excluded from its job's matrix. A
job that runs its platform's whole scenario tree through a harness instead of a matrix
declares that with `env: SCENARIO_PLATFORM:` and is handed the names to run instead.
The same direction holds: a path no rule below recognises runs EVERY scenario, so does any
diff that cannot be computed or parsed, and a scenario whose own files cannot be read is
selected by every rule that would have consulted them. The rules, and what each leans on:

  test/scenarios/<s>/    that scenario.
  SETUP_LIBS             the scenarios whose setup.sh sources it.
  HARNESS                the scenarios of the jobs that run it: a platform's whole tree.
  RECORDERS              one scenario per job, the one naming the most agents. They run
                         after a scenario's assertion and in collect, and decide what a
                         run records, never what it finds.
  SCOPER                 nothing. This file decides what runs and runs in no scenario;
                         test/test_ci_scope.py proves it under lint, and a matrix cannot.
  catalog/agents.yaml    the scenarios that must find a changed agent (must_find, as
                         tools/scenarios.py derives it), hold its lookalikes (forbid), or
                         observed it (observed.json); those carrying forbid_evidence, which
                         names no agent; and the `control` of each platform a changed agent
                         claims. Two agents whose order flipped are both changed:
                         bin/classify gives a row both match to the first. A change outside
                         `agents:` runs every scenario.
  rendered match SQL     nothing more when the catalog is in the same diff, since lint's
                         render_match.py --check holds them to it; otherwise the platform
                         that reads them.
  composed artifacts,    the platform that runs them. A query's platform is its own
  osquery/queries/*.sql  `-- platform:` line; `posix` and an unreadable one run both.
  deep artifact, pack,   the `deep: true` scenarios, the only ones that run osquery/bin/discover.
  osquery/bin/*
  scenarios.yml          compared parsed, job by job: a scenario job that changed runs its
                         list; a job that needs every scenario job, which only consumes
                         their uploads, one scenario per job; a job the scenario jobs need,
                         a job added or removed, or anything outside `jobs:` but `on:`,
                         `name:` and `concurrency:`, every scenario. A comment runs none;
                         a scenario added to a list runs alone.
  ci.yml                 every scenario when its lint job changed, which holds the gates the
                         catalog and rendered-SQL rules lean on; nothing otherwise, since
                         its other jobs define only themselves.
  other workflows        nothing. A workflow defines only its own jobs.
  NOT_ASSERTED           nothing: docs/blind-spots.yaml renders docs/limits.md, and
                         osquery/dist/fleet-policies.yml is checked under lint. No scenario reads
                         either.
  INERT                  nothing. test/test_ci_scope.py proves no scenario job reaches one.

ONE macOS LABEL ON A PULL REQUEST, the first its matrix lists, passed as `--event
pull_request`: the other labels are excluded by `os`, the push to main that follows the
merge runs every label and records what each produced, and so does the weekly run. A
pull request proves an identifier on a real install; which macOS versions carry it is
the observation's business, and observations are committed from main alone.
tools/check_workflows.py holds the first label to every scenario's `min_macos`, since
the job skips, green, a scenario its runner cannot host. The org's
plan allows five macOS jobs at once, and on 2026-11-03 a catalog pull request's two
macOS jobs waited 35 minutes behind full matrices for about a minute of work each.

WHAT THIS FORM CANNOT SEE, and the one thing it gives up: a changed signature that matches
rows -- in the classifier or in the rendered SQL its parity check compares against -- in a
scenario with no link to its agent. Nothing on a pull request asserts on that scenario, so
nothing there could fail. scenarios.yml runs every scenario weekly without calling this
file at all, which bounds that miss at a week.
"""
import argparse
import copy
import json
import pathlib
import re
import subprocess
import sys

import scenarios

ROOT = pathlib.Path(__file__).resolve().parent.parent

# A path is documentation if it matches one of these. Keep it short: every entry is a
# promise that no job gated by this file reads that path, and the promise is checked by
# eye, not by a tool.
DOC_SUFFIXES = (".md",)
DOC_PATHS = ("LICENSE", "NOTICE")

SCENARIOS_WORKFLOW = ".github/workflows/scenarios.yml"
CI_WORKFLOW = ".github/workflows/ci.yml"
CATALOG = "catalog/agents.yaml"

# Read by no job in scenarios.yml, directly or through anything those jobs run. A NEW
# check belongs here only once test/test_ci_scope.py agrees; until then a change to it
# runs every scenario, which costs minutes and nothing else.
INERT = frozenset({
    "osquery/test/check_names_line.py", "osquery/test/docker_states.sh",
    "osquery/test/lib/fake_docker.py", "osquery/test/lint.sh", "test/lib/fake_amplitude.py",
    "test/lib/vm.sh", "test/lint.sh", "test/run-ec2.sh", "test/test_conformance.py",
    "test/test_export.py", "tools/export.py",
    "schema/catalog.schema.json", "schema/evidence.schema.json",
    "test/run-gce.sh", "test/run.sh", "test/test_ci_scope.py", "test/test_matcher.py",
    # test/run-linux.sh is NOT here: scenarios.yml's container job runs it. See HARNESS.
    "test/test_telemetry.py", "osquery/tools/bundle.py", "tools/check_doc_numbers.py",
    # The spec's vectors: test/test_conformance.py reads them under lint, and bin/classify
    # is held to them there, never on a runner.
    "conformance/vectors.json",
    "osquery/tools/check_no_catalog.py", "osquery/tools/check_output.py", "osquery/tools/check_pack.py",
    "tools/check_workflows.py", "tools/gates.sh", "tools/validate_catalog.py",
})
# Read on a runner by nothing that asserts: each is checked by ci.yml's lint job instead.
NOT_ASSERTED = {
    "docs/blind-spots.yaml": "rendered into docs/limits.md; no scenario asserts on it",
    "osquery/dist/fleet-policies.yml": "checked by test_match_sql.py under lint; no scenario reads it",
}
# Sourced by scenario setup scripts and by nothing else a job runs, which
# test/test_ci_scope.py also proves. A change runs the scenarios that source it.
SETUP_LIBS = ("test/lib/guest.sh", "test/lib/guest-linux.sh", "test/lib/guest-windows.ps1",
              "test/lib/unpack_crx.py")

# A job may run its platform's scenarios through one of these instead of a matrix: one
# fresh container per scenario on one runner, so the org's concurrent-job cap stops
# deciding how long the suite takes. The job says so with `env: SCENARIO_PLATFORM:`, and
# that declaration is read here, by tools/check_workflows.py and by tools/agent_status.py,
# so the three cannot disagree about what CI runs. A change to the harness runs every
# scenario of its platform, since every one of them passes through it.
HARNESS_ENV = "SCENARIO_PLATFORM"
HARNESS = {"linux": "test/run-linux.sh"}

# Run by every scenario job AFTER its assertion, and by collect: they decide what a run
# RECORDS -- which identifiers, merged how, gated how -- and never what osqueryi finds or
# whether test/assert.sh passes, which test/test_ci_scope.py holds them to. So one scenario
# per job proves a change to them end to end: record, upload, merge, gate. The one naming
# the most agents, so the recorder meets real identifiers rather than a baseline's none;
# the weekly run records the rest. Both fell through to EVERY until 2026-11-03, when three
# pull requests to them each ran the full matrix on the branch and again on main: 204
# macOS jobs against the org's cap of five concurrent, and every catalog pull request that
# day queued behind them.
RECORDERS = ("tools/agent_status.py", "tools/merge_observations.py", "tools/observations.py")

# Decides what runs, and runs in no scenario: the scope job calls it before any matrix is
# spent, and test/test_ci_scope.py proves it under lint. A matrix run on a change to it
# proves nothing about it, since no scenario calls it -- and it forced the full matrix on
# 8 of 39 pushes to main between 2026-10-20 and 11-03 for that nothing.
SCOPER = "tools/ci_scope.py"

# Read by no runtime job in ci.yml, directly or through anything those jobs run, so a
# change to one decides `runtime` the way documentation does. NOT INERT: that set is what
# the SCENARIO jobs cannot reach, and the runtime jobs run several of its members
# (osquery/tools/bundle.py, check_pack.py). A scenario's own files and the other workflows
# are excused by rule in runtime_inert() rather than listed. Checked by a tool, not by
# eye: test/test_ci_scope.py seeds its reachability analysis from the runtime jobs' steps
# and fails on any member they reach.
RUNTIME_INERT = frozenset({
    SCOPER, *RECORDERS, *SETUP_LIBS, *HARNESS.values(), "docs/blind-spots.yaml",
    "test/assert.sh", "test/lib/assert.sh", "test/lib/vm.sh", "test/lib/fake_amplitude.py",
    "test/run.sh", "test/run-ec2.sh", "test/run-gce.sh", "test/lint.sh", "osquery/test/lint.sh",
    "test/test_ci_scope.py", "test/test_matcher.py", "test/test_telemetry.py",
    "test/test_export.py", "tools/export.py", "osquery/tools/check_no_catalog.py",
    "tools/check_workflows.py", "tools/validate_catalog.py", "tools/check_doc_numbers.py",
    "tools/gates.sh", "tools/scenarios.py",
})

# Rendered from the catalog by osquery/tools/render_match.py. `None` is every platform.
RENDERED = {"osquery/dist/signatures.sql": None,
            "osquery/dist/agents-darwin.sql": "darwin", "osquery/dist/agents-linux.sql": "linux",
            "osquery/dist/agents-windows.sql": "windows"}
# Which platform's jobs run a composed artifact.
COMPOSED = {"osquery/dist/discovery-darwin.sql": "darwin", "osquery/dist/discovery-linux.sql": "linux",
            "osquery/dist/discovery-windows.sql": "windows"}
# Run or read only by a `deep: true` scenario: osquery/bin/discover, the scanner it calls, and
# what it reads. ci.yml runs discover on every push, which is that workflow's own business;
# in scenarios.yml and test/run-linux.sh only the deep branch does. discover reads the pack
# only under --write today; the deep scenarios are the bound, not that flag.
DEEP_ONLY = {"osquery/bin/discover", "osquery/bin/container-scan",
             "osquery/dist/discovery-deep.sql", "osquery/dist/ai-detection-spec.conf"}

EVERY = None  # a selection of every scenario, which an empty set must never be mistaken for


def is_doc(path):
    return path.endswith(DOC_SUFFIXES) or path in DOC_PATHS


def runtime_inert(path):
    """True when no ci.yml runtime job can read `path`: documentation, a scenario's own
    files, a workflow other than ci.yml, or a RUNTIME_INERT member. Anything else runs."""
    return (is_doc(path) or path in RUNTIME_INERT
            or re.fullmatch(r"test/scenarios/[^/]+/.+", path) is not None
            or (path.startswith(".github/workflows/") and path != CI_WORKFLOW))


def changed(base, head):
    """The paths a diff touches, or None when the diff cannot be computed.

    None is not an empty list and the caller must not treat it as one -- see the module
    docstring. Returned rather than raised because "could not tell" is a normal state
    here (force-push, first push of a branch) rather than an error.

    --no-renames, because a rename is otherwise listed by its destination alone: a shared
    file moved into one scenario's directory would read as that scenario's own change.
    """
    if not base or set(base) == {"0"}:
        return None
    try:
        out = subprocess.run(["git", "diff", "--name-only", "--no-renames", f"{base}...{head}"],
                             capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        # Two-dot as a fallback: `a...b` needs a reachable merge base, which a shallow
        # fetch may not have, while `a b` needs only the two commits.
        try:
            out = subprocess.run(["git", "diff", "--name-only", "--no-renames", base, head],
                                 capture_output=True, text=True, check=True).stdout
        except subprocess.CalledProcessError as exc:
            print(f"cannot diff {base}..{head}: {exc.stderr.strip()}", file=sys.stderr)
            return None
    return [p for p in out.splitlines() if p]


def decide(paths):
    """(runtime, why). `paths is None` -- no computable diff -- runs the suite."""
    if paths is None:
        return True, "no diff could be computed, so the runtime gates run"
    if not paths:
        return True, "the diff is empty, which is not the same as nothing a runtime job reads"
    code = [p for p in paths if not runtime_inert(p)]
    if code:
        shown = ", ".join(sorted(code)[:3])
        more = f" (+{len(code) - 3} more)" if len(code) > 3 else ""
        return True, f"{len(code)} of {len(paths)} changed paths can reach a runtime job: {shown}{more}"
    return False, f"no runtime job reads any of the {len(paths)} changed paths; lint still runs"


# --- which scenarios ----------------------------------------------------------------------

def git_reader(base, head):
    """read(side, path) -> text, or None where the file does not exist on that side. A
    `head` of None reads the working tree, which is what --paths means by the head."""
    def read(side, path):
        if side == "head" and head is None:
            try:
                return (ROOT / path).read_text()
            except OSError:
                return None
        rev = base if side == "base" else head
        if not rev or set(rev) == {"0"}:
            return None
        out = subprocess.run(["git", "show", f"{rev}:{path}"], capture_output=True, text=True)
        return out.stdout if out.returncode == 0 else None
    return read


def output_key(prefix, job):
    """The GITHUB_OUTPUT name scenarios.yml reads for a job. tools/check_workflows.py asks
    this function too, so the writer and the reader cannot spell it differently."""
    return f"{prefix}_{job.replace('-', '_')}"


def matrix_lists(doc):
    """{job: [scenario, ...]} for every job in a parsed scenarios.yml with a scenario axis."""
    out = {}
    for job, spec in (doc.get("jobs") or {}).items():
        names = (((spec or {}).get("strategy") or {}).get("matrix") or {}).get("scenario")
        if isinstance(names, list):
            out[job] = list(names)
    return out


def harness_jobs(doc):
    """{job: platform} for every job in a parsed scenarios.yml that declares
    `env: SCENARIO_PLATFORM:`, meaning it runs that platform's whole scenario tree
    through HARNESS[platform] rather than a matrix list."""
    out = {}
    for job, spec in (doc.get("jobs") or {}).items():
        env = (spec or {}).get("env") if isinstance(spec, dict) else None
        if isinstance(env, dict) and env.get(HARNESS_ENV):
            out[job] = str(env[HARNESS_ENV])
    return out


def runner_platform(spec):
    """The platform a matrix job's runner hosts, read off its `container:` or its runner
    labels, or None when no label says. tools/check_workflows.py pairs each scenario with it
    and tools/agent_status.py derives the platforms CI runs from it: two copies of this
    mapping were how a new runner could pass one check and be invisible to the other."""
    if spec.get("container"):
        return "linux"
    labels = (((spec.get("strategy") or {}).get("matrix") or {}).get("os") or [])
    text = " ".join([str(spec.get("runs-on", ""))] + [str(x) for x in labels])
    if "macos" in text:
        return "darwin"
    if "ubuntu" in text or "fedora" in text:
        return "linux"
    if "windows" in text:
        return "windows"
    return None


def tree_scenarios(platform, root=ROOT):
    """Every scenario that declares `platform`, by tools/scenarios.py, which includes one
    whose expected.json cannot be read. `test/run-linux.sh --list` asks the same function."""
    return scenarios.on_platform(platform, root / "test" / "scenarios")


def job_scenarios(doc, root=ROOT):
    """{job: [scenario, ...]} for every job that runs scenarios: the matrix jobs' lists and
    the harness jobs' platform trees. tools/check_workflows.py and tools/agent_status.py
    ask this function too, so "what CI runs" has one answer."""
    out = matrix_lists(doc)
    for job, plat in harness_jobs(doc).items():
        out[job] = tree_scenarios(plat, root)
    return out


class Scope:
    def __init__(self, paths, read, yaml):
        self.paths, self.read, self.yaml = paths, read, yaml
        doc = yaml.safe_load(read("head", SCENARIOS_WORKFLOW) or "")
        self.doc = doc or {}
        self.jobs = job_scenarios(doc or {})
        self.harness = harness_jobs(doc or {})
        self.listed = set().union(*self.jobs.values()) if self.jobs else set()
        self._info = None

    @property
    def info(self):
        """{scenario: facts, or None when its expected.json cannot be read}. Loaded on
        first use: most diffs never need it."""
        if self._info is None:
            self._info = {name: self._facts(name) for name in sorted(self.listed)}
        return self._info

    def _expected(self, name):
        exp = json.loads(self.read("head", f"test/scenarios/{name}/expected.json") or "")
        if scenarios.shape_errors(name, exp):
            raise ValueError(f"tools/scenarios.py refuses {name}'s expected.json")
        return exp

    def _facts(self, name):
        """A scenario's facts, or None when its files cannot be read or are refused, or the
        catalog its must_find derives from cannot be: could-not-look runs."""
        try:
            exp = self._expected(name)
            obs = json.loads(self.read("head", f"test/scenarios/{name}/observed.json") or "{}")
            agents = self.yaml.safe_load(self.read("head", CATALOG) or "")["agents"]
            found = scenarios.must_find(name, self._expected, agents)
        except (ValueError, TypeError, KeyError, self.yaml.YAMLError):
            return None
        cls = exp["classified"]
        seen = {r.get("agent") for r in obs.get("identifiers", []) + obs.get("archived", [])}
        return {"platform": exp["platform"], "deep": bool(exp.get("deep")),
                "control": bool(exp.get("control")),
                "agents": found | set(cls.get("forbid") or []) | seen,
                "must_find": found,
                "any_agent": bool(cls.get("forbid_evidence"))}

    def where(self, test):
        """The scenarios whose facts pass `test`, and every one whose facts are unknown:
        could-not-look must not read as nothing-to-run."""
        return frozenset(n for n, i in self.info.items() if i is None or test(i))

    def on(self, platform):
        return self.where(lambda i: platform is None or i["platform"] == platform)

    def macos_labels(self, job):
        """The macOS labels on a matrix job's `os` axis, in the order listed."""
        spec = (self.doc.get("jobs") or {}).get(job) or {}
        labels = ((spec.get("strategy") or {}).get("matrix") or {}).get("os") or []
        return [str(l) for l in labels if "macos" in str(l)]

    def one_per_job(self):
        """One scenario from each job's list: the one with the most agents in must_find,
        ties broken by name. must_find and not the facts' `agents`, which a baseline's long
        forbid list would win while giving --record nothing to write. Every scenario of a
        job in which any facts could not be read: could-not-look must not read as
        nothing-to-run."""
        picked = set()
        for names in self.jobs.values():
            facts = {n: self.info.get(n) for n in names}
            if any(f is None for f in facts.values()):
                picked |= set(names)
            elif names:
                picked.add(sorted(names, key=lambda n: (-len(facts[n]["must_find"]), n))[0])
        return frozenset(picked)

    def sources(self, name, lib):
        # setup.sh, or setup.ps1 on Windows; `#` comments in both. Neither readable is
        # selected: could-not-look must not read as nothing-to-run.
        text = (self.read("head", f"test/scenarios/{name}/setup.sh")
                or self.read("head", f"test/scenarios/{name}/setup.ps1"))
        return text is None or any(lib in line for line in text.splitlines()
                                   if not line.lstrip().startswith("#"))

    def platforms(self, name):
        """The concrete platforms a `-- platform:` value names, through catalog/routes.yaml's
        groups, or None for a word it does not declare. `posix` is not every scenario once a
        third platform has some."""
        reg = self.yaml.safe_load(self.read("head", "catalog/routes.yaml") or "") or {}
        if name in (reg.get("platforms") or []):
            return [name]
        return (reg.get("platform_groups") or {}).get(name)

    # One rule per kind of path. Each returns (selection, why); EVERY is every scenario.
    def rule(self, path):
        if is_doc(path):
            return frozenset(), "documentation"
        if path in INERT:
            return frozenset(), "a check no scenario job runs"
        if path in NOT_ASSERTED:
            return frozenset(), NOT_ASSERTED[path]
        if path in RECORDERS:
            return (self.one_per_job(),
                    "a recorder, run after every job's assertion: one scenario per job proves it")
        if path == SCOPER:
            return frozenset(), "the scoper itself, which no scenario runs; lint proves it"
        m = re.fullmatch(r"test/scenarios/([^/]+)/.+", path)
        if m:
            name = m.group(1)
            if name in self.listed:
                return frozenset({name}), "the scenario's own files"
            return frozenset(), "a scenario no CI job lists"
        if path in SETUP_LIBS:
            lib = path.rsplit("/", 1)[-1]
            return (frozenset(n for n in self.listed if self.sources(n, lib)),
                    "sourced only by the setup scripts of these scenarios")
        if path in HARNESS.values():
            return (frozenset(n for job, plat in self.harness.items()
                              if HARNESS.get(plat) == path for n in self.jobs[job]),
                    "the harness its jobs run every scenario through")
        if path == SCENARIOS_WORKFLOW:
            return self._workflow()
        if path == CI_WORKFLOW:
            return self._ci()
        if path.startswith(".github/workflows/"):
            return frozenset(), "another workflow; it defines only its own jobs"
        if path == CATALOG:
            return self._catalog()
        if path in RENDERED:
            if CATALOG in self.paths:
                return frozenset(), "rendered from the catalog, which is scoped on its own"
            return self.on(RENDERED[path]), "rendered match SQL, without a catalog change"
        if path in COMPOSED:
            return self.on(COMPOSED[path]), f"run only by {COMPOSED[path]} scenarios"
        if path in DEEP_ONLY:
            return self.where(lambda i: i["deep"]), "run or read only by a `deep: true` scenario"
        if re.fullmatch(r"osquery/queries/[^/]+\.sql", path):
            text = self.read("head", path) or self.read("base", path) or ""
            plat = re.search(r"^-- platform:\s*(\w+)", text, re.M)
            plat = plat.group(1) if plat else None
            plats = self.platforms(plat) if plat else None
            if plats:
                return frozenset().union(*(self.on(p) for p in plats)), f"a {plat} query"
            return EVERY, f"a query whose platform is {plat or 'unreadable'}"
        return EVERY, "not a path this file can scope"

    def _parsed(self, path):
        """Both sides of a YAML file, parsed, or None where either side is missing."""
        base, head = self.read("base", path), self.read("head", path)
        if base is None or head is None:
            return None
        return self.yaml.safe_load(base) or {}, self.yaml.safe_load(head) or {}

    def _workflow(self):
        sides = self._parsed(SCENARIOS_WORKFLOW)
        if sides is None:
            return EVERY, "scenarios.yml has no base to compare against"
        b, h = sides

        def outside_jobs(doc):
            # WHEN A RUN STARTS AND WHAT IT IS CALLED are not what a job does: `on` (PyYAML
            # reads the key as the boolean True), `name` and `concurrency` are dropped. A
            # cron edit (PR #104, 2026-10-20) ran all 156 jobs twice. What is left -- `env`,
            # `permissions`, `defaults` -- every job reads.
            return {k: v for k, v in doc.items()
                    if k not in ("on", True, "name", "concurrency", "jobs")}

        def job(doc, name):
            # WHAT A JOB DOES, without its scenario list, which is scoped below.
            spec = copy.deepcopy((doc.get("jobs") or {}).get(name))
            if isinstance(spec, dict):
                ((spec.get("strategy") or {}).get("matrix") or {}).pop("scenario", None)
            return spec
        if outside_jobs(b) != outside_jobs(h):
            return EVERY, "scenarios.yml changed outside its jobs, which every job reads"
        b_jobs, h_jobs = b.get("jobs") or {}, h.get("jobs") or {}
        if set(b_jobs) != set(h_jobs):
            return EVERY, "scenarios.yml gained or lost a job"
        was = matrix_lists(b)
        sel = frozenset(n for jb, names in matrix_lists(h).items()
                        for n in names if n not in was.get(jb, []))
        changed = sorted(n for n in h_jobs if job(b, n) != job(h, n))
        if not changed:
            return sel, ("scenarios added to a matrix" if sel
                         else "scenarios.yml parses unchanged")
        # JOB BY JOB, placed by structure rather than by name, which is a list that has
        # to agree with the tree. A job that runs scenarios runs its list. A job that
        # needs every scenario job consumes their uploads and runs none, so one scenario
        # per job proves it: collect, 2026-11-03, ran all 34 macOS jobs twice for a change
        # to its own merge step. Any other job -- scope, which the scenario jobs need and
        # which decides what they run -- is every scenario.
        for n in changed:
            needs = (h_jobs[n] or {}).get("needs") or []
            needs = {needs} if isinstance(needs, str) else set(needs)
            if n in self.jobs:
                sel |= frozenset(self.jobs[n])
            elif self.jobs and set(self.jobs) <= needs:
                sel |= self.one_per_job()
            else:
                return EVERY, f"scenarios.yml job {n!r} changed, and the scenario jobs depend on it"
        return sel, f"scenarios.yml jobs changed: {', '.join(changed)}"

    def _ci(self):
        # ONLY THE LINT JOB REACHES A SCENARIO, and only by proxy: it runs the gates the
        # catalog and rendered-SQL rules lean on, so weakening it must not be cheap. Its
        # other jobs define only themselves, like any other workflow's.
        sides = self._parsed(CI_WORKFLOW)
        if sides is None:
            return EVERY, "ci.yml has no base to compare against"
        b, h = sides
        if (b.get("jobs") or {}).get("lint") != (h.get("jobs") or {}).get("lint"):
            return EVERY, "ci.yml's lint job changed, and it backs the catalog and rendered-SQL rules"
        return frozenset(), "ci.yml changed outside its lint job, which defines only its own jobs"

    def _catalog(self):
        base, head = self.read("base", CATALOG), self.read("head", CATALOG)
        if base is None or head is None:
            return EVERY, "the catalog has no base to compare against"
        b, h = self.yaml.safe_load(base), self.yaml.safe_load(head)
        if {k: v for k, v in b.items() if k != "agents"} != \
           {k: v for k, v in h.items() if k != "agents"}:
            return EVERY, "the catalog changed outside `agents:`"
        b_ids = [a["id"] for a in b.get("agents") or []]
        h_ids = [a["id"] for a in h.get("agents") or []]
        # ORDER DECIDES ONE THING: which of two agents claims a row both of their prefix or
        # glob values match, since bin/classify takes the first. So a pair whose order
        # flipped is a pair whose shared rows may change hands, and both count as changed:
        # the scenarios holding such a row observed whichever agent used to win it.
        now = {i: n for n, i in enumerate(i for i in h_ids if i in b_ids)}
        kept = [i for i in b_ids if i in now]
        flipped = {i for k, x in enumerate(kept) for y in kept[k + 1:]
                   if now[x] > now[y] for i in (x, y)}
        b_by_id = dict(zip(b_ids, b.get("agents") or []))
        h_by_id = dict(zip(h_ids, h.get("agents") or []))
        moved = {i for i in b_by_id.keys() | h_by_id.keys()
                 if b_by_id.get(i) != h_by_id.get(i)} | flipped
        if not moved:
            return frozenset(), "the catalog's agents parse unchanged"
        claims = {p for i in moved for a in (b_by_id.get(i), h_by_id.get(i)) if a
                  for p in a.get("platforms") or []}
        return (self.where(lambda i: bool(i["agents"] & moved) or i["any_agent"]
                           or (i["control"] and i["platform"] in claims)),
                f"agents changed or reordered: {', '.join(sorted(moved))}")

    def select(self):
        """(selection, [(path, selection, why)])."""
        lines, total = [], frozenset()
        for path in sorted(self.paths):
            try:
                sel, why = self.rule(path)
            except Exception as exc:  # a file this could not read is a file it cannot scope
                sel, why = EVERY, f"could not be read ({type(exc).__name__}: {exc})"
            lines.append((path, sel, why))
            total = EVERY if sel is EVERY or total is EVERY else total | sel
        return total, lines


def scenarios_outputs(paths, read, only=None, event=None):
    """(GITHUB_OUTPUT lines, report lines). Raises ImportError without PyYAML, which the
    workflow turns into a red scope job rather than a guess. `only` is a dispatch that
    named its scenarios: exactly those run, and a name no job lists is an error rather
    than a run of nothing. `event` is GitHub's event name; a pull request runs one macOS
    label (see the module docstring), and every other event every label."""
    import yaml
    scope = Scope(paths or [], read, yaml)
    every_because = named = None
    if only is not None:
        unknown = sorted(set(only) - scope.listed)
        if unknown:
            raise SystemExit(f"ci_scope: no job in scenarios.yml lists {', '.join(unknown)}")
        total, lines = frozenset(only), []
        named = f"dispatched with names: {', '.join(sorted(set(only)))}"
    elif paths is None:
        total, lines, every_because = EVERY, [], "no diff could be computed"
    elif not paths:
        total, lines, every_because = EVERY, [], "the diff is empty, which is not the same as nothing"
    else:
        total, lines = scope.select()
    run = scope.listed if total is EVERY else total & scope.listed
    out = [f"runtime={'true' if run else 'false'}"]
    report = []
    if named:
        report.append(named)
    if every_because:
        report.append(f"every scenario runs: {every_because}")
    for path, sel, why in lines:
        what = "every scenario" if sel is EVERY else (", ".join(sorted(sel)) or "nothing")
        report.append(f"{path}: {why} -> {what}")
    for job, names in sorted(scope.jobs.items()):
        keep = [n for n in names if n in run]
        out.append(f"{output_key('skip', job)}={'false' if keep else 'true'}")
        if job in scope.harness:
            # The harness is handed the names to run. Left unset, as on the weekly run, it
            # runs every scenario of its platform on disk.
            out.append(f"{output_key('run', job)}={' '.join(keep)}")
        else:
            drop = [{"scenario": n} for n in names if n not in run]
            # By `os`, which GitHub matches on that key alone, so every cell on a spare
            # label goes. Only when something runs: an empty matrix needs no label.
            spare = scope.macos_labels(job)[1:] if event == "pull_request" and keep else []
            drop += [{"os": label} for label in spare]
            if spare:
                report.append(f"{job}: a pull request runs one macOS label, "
                              f"{scope.macos_labels(job)[0]}; {', '.join(spare)} "
                              f"runs on the push to main")
            out.append(f"{output_key('exclude', job)}={json.dumps(drop, separators=(',', ':'))}")
        report.append(f"{job}: runs {len(keep)} of {len(names)}"
                      + (f": {', '.join(keep)}" if keep and len(keep) < len(names) else ""))
    return out, report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base", nargs="?")
    ap.add_argument("head", nargs="?", default="HEAD")
    ap.add_argument("--paths", nargs="*", default=None,
                    help="decide on this list instead of a git diff (tests)")
    ap.add_argument("--scenarios", action="store_true",
                    help="say which scenarios scenarios.yml runs, per job")
    ap.add_argument("--summary", help="with --scenarios: append the reasons here as Markdown")
    ap.add_argument("--only", nargs="+", metavar="SCENARIO",
                    help="with --scenarios: run exactly these, as a dispatch that named them")
    ap.add_argument("--event", help="with --scenarios: GitHub's event name; a pull request "
                                    "runs one macOS label")
    args = ap.parse_args()
    if args.only is not None and not args.scenarios:
        ap.error("--only needs --scenarios")
    paths = args.paths if args.paths is not None else changed(args.base, args.head)
    if not args.scenarios:
        runtime, why = decide(paths)
        print(f"runtime={'true' if runtime else 'false'}")
        print(why, file=sys.stderr)
        return
    # --paths has no base to diff a catalog or a workflow against, so those rules run
    # everything there, and its head is the working tree. So does --only, which reads no
    # diff at all.
    read = (git_reader(None, None) if args.paths is not None or args.only is not None
            else git_reader(args.base, args.head))
    out, report = scenarios_outputs(paths, read, only=args.only, event=args.event)
    print("\n".join(out))
    print("\n".join(report), file=sys.stderr)
    if args.summary:
        with open(args.summary, "a") as fh:
            fh.write("### Which scenarios this diff can move\n\n")
            fh.write("\n".join(f"- {line}" for line in report) + "\n")


if __name__ == "__main__":
    main()
