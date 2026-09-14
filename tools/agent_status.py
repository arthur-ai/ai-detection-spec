#!/usr/bin/env python3
"""Report every agent in the catalog and what evidence backs it.

GENERATED, NEVER HAND-MAINTAINED. A hand-written coverage table is a second copy of
the catalog that drifts from the first, and this repo's whole argument is that a
plausible-looking wrong answer is the expensive kind. Everything here is read off
catalog/agents.yaml, test/fixtures/ and test/scenarios/ at the moment it runs.

COVERAGE MEANS ONE THING: a CI scenario installed the real software and the classifier
found it. That is the only evidence that survives the bot.molt.mac failure -- a
vendor-documented identifier that matched nothing on any Mac.

A hand-written fixture proves the MATCHER and credits no coverage, because nothing on a
row says whether a machine ever produced it. Only test/fixtures/captured/ can, and it
holds rows from a named CI run. An identifier with neither is named rather than hidden.
"""
import collections
import importlib.machinery      # NOT implied by importlib.util. Importing only .util
import importlib.util              # left importlib.machinery resolvable on a developer Mac,
                                   # where something else had already imported it, and
                                   # AttributeError on a clean runner -- which is where it
                                   # failed: every scenario job, in the recording step.
import json
import os
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Import the shipping matcher rather than reimplementing its normalisation. image_repo()
# records four rules read off real rows; a second copy here would drift from it silently,
# and this file would then report coverage the classifier does not actually have.
_spec = importlib.util.spec_from_loader(
    "classify", importlib.machinery.SourceFileLoader("classify", str(ROOT / "bin" / "classify")))
classify_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(classify_mod)

# THE ROUTE VOCABULARY COMES FROM catalog/routes.yaml, not from three lists here.
#
# EXACT_KINDS, GLOB_ROUTES and ALL_ROUTES used to sit at this spot -- three of the five
# hardcoded copies that had to agree with bin/classify and test/lint.sh. ALL_ROUTES also
# fixed the report's column order, which is now the registry's declaration order, so the
# page and the matcher cannot disagree about what a route even is.
# THE SCENARIOS ROOT, named once. It was written out six times, and one of those spellings
# gates whether record() merges with a committed observation and runs the coverage shrink
# guard at all -- so the guard could not be tested, because a test had nowhere to put a
# fixture that record() would accept as a scenario. test/test_matcher.py repoints this.
SCENARIOS = ROOT / "test" / "scenarios"

# THE TWO FIXTURE ROOTS, and the difference between them is evidentiary rather than tidy.
# Named here for the same reason SCENARIOS is: test/test_matcher.py repoints them, which is
# the only way to exercise a credit path whose directory is empty in the tree.
FIXTURES = ROOT / "test" / "fixtures"
FIXTURES_CAPTURED = FIXTURES / "captured"


def coverage_fixtures():
    """Fixture files whose rows may credit COVERAGE, not merely prove the matcher.

    Only rows a named CI run really produced. See collect() for why provenance lives in
    the path rather than on the row.
    """
    return sorted(FIXTURES_CAPTURED.glob("*.json")) if FIXTURES_CAPTURED.is_dir() else []


ROUTES = classify_mod.load_routes()
REGISTRY = classify_mod.Registry(ROUTES)
# Declaration order, which is what the report renders in.
ALL_ROUTES = list(ROUTES["routes"])
# Routes that can only ever be credited at ROUTE level, never per value: a prefix or a
# path glob tells you the route fired, not which of its values did. `GLOB_ROUTES` was the
# old name and it under-described itself -- launchd_prefixes is a prefix, not a glob.
ROUTE_LEVEL_ONLY = {n for n, m in REGISTRY.match.items()
                    if m == "prefix" or m.startswith("home-")}


def replay(paths, catalog):
    """Classify rows from `paths` and record what each finding was matched ON.

    Not merely that an agent was found -- which identifier proved it. An evidence row
    carries the raw row, so the identifier is recovered by kind: the exact kinds compare
    whole, images normalise through the shipping matcher, and the glob routes can only be
    credited at route level because a path does not name the pattern that matched it.
    """
    values = collections.defaultdict(set)
    routes = collections.defaultdict(set)
    # THE VERSION THAT PRODUCED THE IDENTIFIER. Rows already carry it and the recorder was
    # discarding it, which is what made "does this identifier still exist in the current
    # release" unanswerable from the record -- the exact question a catalog of evolving
    # agents has to answer. OpenClaw is why: moltbot -> clawdbot -> openclaw, three names
    # across three versions, all still catalogued.
    seen_ver = {}
    by_id = {a["id"]: a for a in catalog["agents"]}
    def agent_of(aid):
        return by_id.get(aid, {})
    for path in paths:
        rows = json.loads(path.read_text())
        rows = rows["findings"] if isinstance(rows, dict) else rows
        # classify() returns findings as {agent id: [(meta, row), ...]}, not a list.
        for aid, matched in classify_mod.classify(rows, catalog, ROUTES)[0].items():
            agent = by_id.get(aid, {})
            for _meta, ev in matched:
                kind, ident, loc = ev.get("kind"), ev.get("id", ""), ev.get("loc", "")
                ver = ev.get("ver", "")

                def credit(route, value, exact_value=True):
                    values[aid].add((route, str(value)))
                    routes[aid].add(route)
                    # A version is only recorded where the row actually carries one AND
                    # the credit names the exact identifier. A path glob names no version
                    # and inventing one would be worse than leaving it out.
                    if exact_value and ver:
                        seen_ver[(aid, route, str(value))] = ver

                # RESOLVE WHICH ROUTE, AND WHICH VALUE, ACTUALLY MATCHED -- generically,
                # from the registry, rather than one branch per kind.
                #
                # Crediting a whole route group was a false positive with a very
                # plausible face: 25-python-agents matched aider on
                # ~/.local/share/uv/tools/aider-chat/ and this recorded
                # `state_dirs: ~/.aider` as observed in a real install -- an identifier
                # that appears NOWHERE in that run's output. The report then showed the
                # strongest possible evidence for a path no machine had produced.
                for route in REGISTRY.kind_routes.get(kind, []):
                    mode = REGISTRY.match[route]
                    listed = [str(v) for v in agent.get(route, [])]
                    if mode == "exact":
                        if str(ident) in listed:
                            credit(route, ident)
                        else:
                            # A trailing `*` is a prefix form; credit the value as
                            # written, because that is what the catalog carries and what
                            # record() looks up.
                            for value in listed:
                                if value.endswith("*") and str(ident).startswith(value[:-1]):
                                    credit(route, value, exact_value=False)
                    elif mode == "exact-normalised":
                        for repo in classify_mod.image_repos(ident):
                            if repo in listed:
                                credit(route, repo)
                    elif mode == "prefix":
                        for value in listed:
                            if str(ident).startswith(value):
                                credit(route, value, exact_value=False)
                    elif mode.startswith("home-"):
                        # THE SAME FUNCTION bin/classify MATCHES WITH, not a copy of it.
                        # This was a hand-built `^/Users/[^/]+/` regex under a comment
                        # claiming the two "cannot disagree" -- and it would have
                        # disagreed the moment the matcher learned /home and /root,
                        # reporting Linux coverage as absent while the classifier found
                        # it. That is the silent-disagreement shape this repo is built
                        # around.
                        for value in listed:
                            pat = classify_mod.home_pattern(value, mode)
                            if pat.match(ident) or pat.match(loc):
                                credit(route, value, exact_value=False)

                # A pipx/uv tool directory names its PACKAGE, which is why classify
                # checks the package routes for it and not the path globs.
                tool = (classify_mod.TOOL_DIR.match(ident)
                        or classify_mod.TOOL_DIR.match(loc))
                if tool:
                    name = tool.group(1)
                    bridged = [r for r, m in REGISTRY.match.items() if m == "tool-dir"]
                    bridged += [r for r, m in REGISTRY.match.items()
                                if m == "exact" and REGISTRY.routes[r]["kind"] == "npm"]
                    for route in bridged:
                        if name in [str(v) for v in agent.get(route, [])]:
                            credit(route, name)
    return values, routes, seen_ver


def record(artifact, scenario_dir, os_version="", arch="", platform="", run_id=""):
    """Write scenario/observed.json: which identifiers a REAL run actually matched.

    test/artifacts/ is gitignored and per-machine, so the raw output cannot back a
    committed document. This is the compact, reviewable residue of a run -- the
    observations layer of docs/signature-lifecycle-v1.md, at its smallest useful size.

    `run_id` IS THE FIELD THAT MAKES PROOF OUTLIVE THE RUN. Without it an observation
    from a CI runner cannot be told from one a maintainer produced on their own Mac, and
    that distinction is what a superseded record rests on: once CI stops reproducing an
    identifier, the only thing standing behind the catalog entry is the record of the run
    that last produced it. A record with no run names no run.

    Empty off CI, and that is deliberate rather than a fallback -- a local `--record` has
    no run to name, and inventing one would manufacture exactly the provenance this field
    exists to carry.
    """
    catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    values, routes, seen_ver = replay([pathlib.Path(artifact)], catalog)
    idents = []
    for agent in catalog["agents"]:
        aid = agent["id"]
        for route in ALL_ROUTES:
            for value in agent.get(route, []):
                value = str(value)
                if route in ROUTE_LEVEL_ONLY or value.endswith("*"):
                    proven = (route, value) in values[aid]
                else:
                    key = classify_mod.image_repo(value) if route == "images" else value
                    proven = (route, key) in values[aid]
                if proven:
                    rec = {"agent": aid, "route": route, "value": value}
                    # Version, OS and arch: an identifier is a fact about ONE build on ONE
                    # platform, and a record that omits which cannot answer whether the
                    # current release still emits it. Only recorded where the row actually
                    # carries a version -- a path glob names no version, and inventing one
                    # would be worse than leaving it out.
                    ver = seen_ver.get((aid, route, value)) or seen_ver.get(
                        (aid, route,
                         classify_mod.image_repo(value) if route == "images" else value))
                    if ver:
                        rec["agent_version"] = ver
                    # PLATFORM BESIDE os, NOT INSTEAD OF IT. `os` holds "14.8.7" or
                    # "24.04" -- a release, which names a platform family only if you
                    # already know whose numbering that is. Coverage is counted per
                    # platform now, so the family is recorded rather than inferred from a
                    # version string.
                    if platform:
                        rec["platform"] = platform
                    if os_version:
                        rec["os"] = os_version
                    if arch:
                        rec["arch"] = arch
                    # LAST, and outside the merge key on purpose. Two runs on the same
                    # (platform, os, arch) are the same observation re-proved, not two
                    # observations -- so the run id must not split them, or every nightly
                    # run would append a duplicate record instead of refreshing one.
                    if run_id:
                        rec["run"] = str(run_id)
                    idents.append(rec)
    # Sort once, before either write path below can use it.
    idents.sort(key=lambda r: (r["agent"], r["route"], r["value"]))

    out_path = pathlib.Path(scenario_dir) / "observed.json"

    # MERGE BY PLATFORM. A scenario runs on more than one macOS version now, so a run adds
    # its own platform's records and leaves every other platform's alone. Overwriting would
    # mean the last job to finish decided what the whole scenario had ever proved.
    plat = (platform or None, os_version or None, arch or None)
    kept = []
    if out_path.exists():
        for r in json.loads(out_path.read_text()).get("identifiers", []):
            if (r.get("platform"), r.get("os"), r.get("arch")) != plat:
                kept.append(r)

    # A RUN THAT PROVES LESS THAN THE COMMITTED RECORD IS ALMOST ALWAYS A STALE ARTIFACT,
    # not a regression. Re-recording from test/artifacts/ after the scenario had changed
    # silently dropped codex's ~/.codex and took coverage from 38/38 to 37/38 -- a real
    # identifier, proved by CI, erased by replaying an older local file over it.
    #
    # Genuine shrinkage happens (an identifier removed from the catalog, a route that
    # stopped being produced) so this is refusable rather than forbidden -- but it has to be
    # said out loud, because the silent version costs coverage nobody notices losing.
    if out_path.exists() and "--allow-shrink" not in sys.argv:
        committed = json.loads(out_path.read_text()).get("identifiers", [])
        was = {(r["agent"], r["route"], r["value"]) for r in committed
               if (r.get("platform"), r.get("os"), r.get("arch")) == plat}
        now = {(r["agent"], r["route"], r["value"]) for r in idents}
        lost = sorted(was - now)
        if lost:
            print(f"refusing to record {out_path.parent.name}: this run proves "
                  f"{len(lost)} fewer identifier(s) than the committed record:")
            for a, r, v in lost:
                print(f"  lost  {a} {r}:{v}")
            # NAME THE KEY IT COMPARED ON, and the keys the file holds. The message used
            # to say WHAT was lost and not WHICH record it was judged against.
            #
            # THAT COST A LONG DETOUR AND THE GUARD WAS RIGHT. A CI job refused with
            # `lost aider state_dirs:~/.aider` against a branch file whose records were
            # all arch=aarch64, on a runner reporting x86_64 -- so the filtered set looked
            # like it had to be empty and the guard looked broken.
            #
            # It was not. A `pull_request` job checks out the MERGE of the branch into
            # main, not the branch, and main's copy of that file already carried x86_64
            # records from an earlier run on main. The guard filtered to x86_64, found
            # them, and correctly reported one fewer. The mistake was the forensics:
            # comparing against `git show <branch>:...` when CI had never read that file.
            #
            # These two lines would have said so immediately, which is the whole reason
            # they are here. test/test_matcher.py pins the scoping in both directions,
            # using the same two-key file that caused the confusion.
            keys = sorted({(r.get("platform"), r.get("os"), r.get("arch"))
                           for r in committed})
            print(f"  compared on (platform, os, arch) = {plat}, against "
                  f"{len(was)} of {len(committed)} committed record(s)")
            print(f"  keys in the committed file: {keys}")
            print("If the artifact is current and the loss is real, pass --allow-shrink.")
            sys.exit(1)

    # record() is called directly by test/test_matcher.py against a TemporaryDirectory, which
    # is not a scenario and gets no merge with a committed record.
    scen = pathlib.Path(scenario_dir).resolve()
    if scen.parent != SCENARIOS.resolve():
        print(f"recorded {len(idents)} identifiers observed by {scen.name} "
              f"(not a scenario directory)")
        out_path.write_text(json.dumps({"scenario": scen.name, "identifiers": idents},
                                       indent=2) + "\n")
        return

    out = out_path
    # Sorted and undated: this file is committed and compared, so it must change only
    # when what the run OBSERVED changes.
    idents = kept + idents
    idents.sort(key=lambda r: (r["agent"], r["route"], r["value"],
                               r.get("platform") or "", r.get("os") or "",
                               r.get("arch") or ""))
    out.write_text(json.dumps({"scenario": pathlib.Path(scenario_dir).name,
                               "identifiers": idents}, indent=2) + "\n")
    print(f"recorded {len(idents)} identifiers observed by {out.parent.name}")


def ci_scenarios():
    """Scenarios that actually run in CI, read off scenarios.yml.

    The distinction this whole report now turns on: a scenario that only ever runs on a
    maintainer's Mac catches nothing on a pull request. 45-claude-extension was in exactly
    that state -- passing locally, absent from the matrix -- which is why the metric is
    "does CI test this" rather than "has anyone ever tested this".
    """
    return set().union(*_ci_jobs().values()) if _ci_jobs() else set()


def _ci_jobs():
    """{job name: set of scenarios}, across EVERY job that has a scenario matrix.

    This read one named job before Linux, which would have made every scenario under a
    second job invisible to the coverage report -- counted as "no CI test covers it" while
    CI ran it on a schedule. tools/check_workflows.py asserts the same set from the other
    side.
    """
    wf = ROOT / ".github" / "workflows" / "scenarios.yml"
    if not wf.exists():
        return {}
    doc = yaml.safe_load(wf.read_text())
    out = {}
    for job, spec in (doc.get("jobs") or {}).items():
        names = ((spec.get("strategy") or {}).get("matrix") or {}).get("scenario")
        if names:
            out[job] = set(names)
    return out


def ci_platforms():
    """Which platforms CI actually runs, derived from the jobs' runners.

    THE POINT OF DERIVING IT: an identifier for a platform CI does not run is not
    "untested through neglect", it is untested because there is no runner. Those two need
    different words, or the second silently becomes an excuse for the first -- so the gate
    reports `no-ci-platform` for them, counts them, and names them, and starts FAILING the
    moment that platform joins the matrix.
    """
    wf = ROOT / ".github" / "workflows" / "scenarios.yml"
    if not wf.exists():
        return set()
    doc = yaml.safe_load(wf.read_text())
    plats = set()
    for spec in (doc.get("jobs") or {}).values():
        if not ((spec.get("strategy") or {}).get("matrix") or {}).get("scenario"):
            continue
        if spec.get("container"):
            plats.add("linux")
            continue
        text = " ".join([str(spec.get("runs-on", ""))]
                        + [str(x) for x in
                           (((spec.get("strategy") or {}).get("matrix") or {})
                            .get("os") or [])])
        if "macos" in text:
            plats.add("darwin")
        if "ubuntu" in text or "fedora" in text:
            plats.add("linux")
    return plats


def collect():
    catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())

    scenarios = collections.defaultdict(set)
    # A scenario's platform is declared in its own expected.json, which is also what
    # test/lint.sh and tools/check_workflows.py read. Taken from there rather than from an
    # observation's `os` field, because "24.04" names a platform family only to a reader
    # who already knows whose numbering that is.
    scenario_platform = {}
    for path in sorted(SCENARIOS.glob("*/expected.json")):
        doc = json.loads(path.read_text())
        scenario_platform[path.parent.name] = doc.get("platform")
        block = doc.get("classified", {})
        for aid in block.get("must_find", []):
            scenarios[aid].add(path.parent.name)

    # A FIXTURE PROVES THE MATCHER AND NO LONGER PROVES AN IDENTIFIER, and the difference
    # is provenance the tree could not see. `test/fixtures/*.json` is hand-written: the row
    # for `bot.molt.mac` was added with bin/classify itself, never captured from a machine,
    # and there is no field on a row that tells that apart from one a runner produced. So
    # counting fixtures as coverage credited an identifier on the strength of a string
    # somebody typed -- the exact claim this repo refuses everywhere else.
    #
    # Provenance is the PATH, not a key on the row, because bin/classify echoes evidence
    # rows verbatim and a `captured_from` key would leak into classifier output for
    # something that has nothing to do with the payload contract. A file under
    # `captured/` holds rows a named CI run really produced, so its rows may credit
    # coverage; anything else may not.
    #
    # `captured/` is EMPTY today, and deliberately: nothing writes it yet. The flow that
    # does -- a rename's successor landing as a reviewable pull request -- is
    # docs/signature-lifecycle-v2.md's other half. The reader is here so the door it opens
    # is the one the design describes, rather than a second mechanism invented later.
    values, routes, _ = replay(coverage_fixtures(), catalog)
    # Keyed by scenario, so an identifier proved only outside CI can be told apart from
    # one a pull request would catch.
    seen_in = collections.defaultdict(set)      # (agent, route, value) -> {scenario}
    observed_os = set()
    for path in sorted(SCENARIOS.glob("*/observed.json")):
        doc = json.loads(path.read_text())
        for rec in doc.get("identifiers", []):
            seen_in[(rec["agent"], rec["route"], rec["value"])].add(doc["scenario"])
            if rec.get("os"):
                observed_os.add(rec["os"])
    in_ci = ci_scenarios()
    in_ci_platforms = ci_platforms()
    # Route -> the platforms it can fire on, from the registry. An identifier's platform
    # is its route's platform: there is nowhere else it could come from, which is why this
    # needed no new field in catalog/agents.yaml.
    route_platforms = {n: set(REGISTRY.expand(r["platform"]))
                       for n, r in REGISTRY.routes.items()}
    # Which agents each CI scenario claims to install, from its own expectations. An
    # identifier of such an agent that the run did NOT produce was reached by the suite and
    # failed to appear -- worth naming separately from one nothing has ever tried.
    asserted_by = collections.defaultdict(set)      # agent id -> {scenario}
    for path in sorted(SCENARIOS.glob("*/expected.json")):
        name = path.parent.name
        if name not in in_ci:
            continue
        for aid in json.loads(path.read_text()).get("classified", {}).get("must_find", []):
            asserted_by[aid].add(name)
    # A CI scenario that has never RECORDED contributes nothing to the numbers below, so
    # the count is pessimistic until each has run once. Absence of an observation is not
    # absence of a test, and reporting the total without saying which scenarios are
    # missing would present a floor as a measurement.
    recorded = {p.parent.name for p in SCENARIOS.glob("*/observed.json")}
    unrecorded = sorted(in_ci - recorded)

    agents = []
    # SUPERSEDED VALUES COME FROM AN ARCHIVED OBSERVATION, not from a label. `retired:`
    # was a list of strings a person typed, and it exempted every one of them from the
    # coverage gate -- which is how two identifiers naming a release that was never
    # published sat excluded from the badge for months. A value is superseded here only if
    # a run once produced it and that record was archived when it stopped.
    #
    # Keyed on (route, value), never value alone: OpenClaw ships an npm package and a
    # Homebrew cask both called `openclaw`, so a value-keyed label would supersede one by
    # superseding the other. Same lesson as the coverage credits.
    superseded_of = {a["id"]: {(str(s["route"]), str(s["value"]))
                               for s in a.get("superseded", [])}
                     for a in catalog["agents"]}
    for agent in catalog["agents"]:
        aid = agent["id"]
        idents = []
        for route in ALL_ROUTES:
            for value in agent.get(route, []):
                value = str(value)
                if route in ROUTE_LEVEL_ONLY or value.endswith("*"):
                    proven = route in routes[aid]       # route-level only
                    precision = "route"
                else:
                    key = classify_mod.image_repo(value) if route == "images" else value
                    proven = (route, key) in values[aid]
                    precision = "exact"
                scens = sorted(seen_in.get((aid, route, value), ()))
                ci_scens = [s for s in scens if s in in_ci]
                # A fixture IS a CI test: ci.yml runs test/lint.sh, which runs
                # test_matcher.py, on every pull request. It is a weaker CLAIM than a real
                # install and a stronger CADENCE -- those are different axes and the report
                # keeps them apart.
                # A RETIRED ALIAS IS NOT A GAP. Nothing installs it any more, so no
                # scenario can ever cover it, and a fixture is the only evidence that
                # exists rather than a lesser one. Counting it as a shortfall would make
                # the report demand something impossible -- and, worse, invite someone to
                # "fix" it by deleting the alias, which is the one thing that would break
                # detection on the machines it exists for.
                # COVERAGE WINS OVER THE ALIAS LABEL. `retired` says an identifier comes
                # from an earlier release, not that it cannot be tested -- and
                # 56-openclaw-retired-names disproved that by installing clawdbot and
                # moltbot for real. Checking `retired` first excluded them from the
                # denominator while a scenario was proving them, which understated the
                # coverage and mislabelled the evidence.
                # THE ORDER IS THE MEANING. Real-install evidence outranks everything;
                # a retired alias comes next because nothing can install it any more.
                #
                # `no-ci-platform` sits below both and above every "we tried and it did
                # not appear" state, because it is not a failure to observe -- it is the
                # absence of a runner. Naming it separately is what stops it becoming an
                # excuse for the states beneath it, and the two defences against that are
                # written into --gate and into the per-platform breakdown the report
                # always prints: an embarrassing zero is on the generated front page, and
                # the gate FAILS the instant that platform joins the CI matrix with
                # identifiers still uncovered.
                if ci_scens:
                    state = "ci-install"
                elif (route, str(value)) in superseded_of.get(aid, ()):
                    state = "superseded"
                elif proven:
                    state = "ci-fixture"
                elif not (route_platforms.get(route, set()) & in_ci_platforms):
                    state = "no-ci-platform"
                elif scens:
                    state = "local-only"
                # .get() on a defaultdict does NOT create the default, so a brand-new
                # agent that no scenario asserts yet returned None and crashed the whole
                # report -- adding one entry to the catalog broke the page that describes
                # the catalog. Found by simulating exactly the change this tooling exists
                # to survive.
                elif asserted_by[aid] - set(unrecorded):
                    # A scenario installed this agent and this identifier never showed up.
                    state = "tested-absent"
                else:
                    state = "none"
                idents.append({"route": route, "value": value,
                               "fixture": proven, "real": bool(scens),
                               "scenarios": scens, "ci_scenarios": ci_scens,
                               "reached_by": sorted(asserted_by[aid] - set(unrecorded)),
                               # The platforms this identifier can be observed on --
                               # its route's platforms, because that is the only place
                               # the information exists. This is what makes per-platform
                               # coverage countable without a new catalog field.
                               "platforms": sorted(route_platforms.get(route, ())),
                               # WHICH PLATFORMS ACTUALLY OBSERVED IT, as opposed to
                               # which could. A `posix` identifier proved on macOS says
                               # nothing about Linux -- the route is portable, the
                               # observation is not -- so crediting it to both would put
                               # a confident face on an untested platform. That is the
                               # whole failure mode the per-platform breakdown exists to
                               # expose, so it must not be the thing computing it.
                               "observed_on": sorted(
                                   {scenario_platform.get(sc) for sc in ci_scens}
                                   - {None}),
                               "state": state, "precision": precision})
        agents.append({
            "id": aid, "name": agent["name"], "classification": agent["classification"],
            "scenarios": sorted(scenarios.get(aid, ())),
            "identifiers": idents,
        })
    # What the suite cannot prove, carried alongside what it can. A coverage report that
    # lists only successes is the same failure mode as an empty result on a clean machine:
    # it reads as complete when it is merely silent.
    limits = []
    for path in sorted(SCENARIOS.glob("*/*.json")):
        doc = json.loads(path.read_text())
        name = path.parent.name
        for gap in doc.get("known_gaps", []):
            limits.append({"scenario": name, "kind": "gap", "text": gap})
        if path.name == "requires.json" and doc.get("why"):
            limits.append({"scenario": name, "kind": "skip", "text": doc["why"],
                           "min_macos": doc.get("min_macos")})

    # THE GENERAL LIMITS LIVE IN ONE FILE, docs/blind-spots.yaml. They used to live in
    # README and be parsed back out of it, which meant the same thirteen rows existed in two
    # places and the one a reader met first was whichever page they opened. The data is the
    # data now; README points at this report.
    blind = yaml.safe_load((ROOT / "docs" / "blind-spots.yaml").read_text())["blind_spots"]

    return {"observed_os": sorted(observed_os), "blind_spots": blind, "ci_unrecorded": unrecorded,
            "removed": catalog.get("removed", []),
            "classifications": catalog["classifications"],
            "not_agents": list(catalog.get("not_agents", ())),
            "agents": agents, "limits": limits}


STATE_LABEL = {
    "ci-install": "CI: real install",
    "ci-fixture": "CI: fixture",
    "superseded": "superseded",
    # Not a failure to observe: there is no runner for that platform. Named rather than
    # folded into NO TEST, because the two need different actions -- one is a test to
    # write, the other is a platform to add to the matrix.
    "no-ci-platform": "NO CI PLATFORM",
    "tested-absent": "DID NOT APPEAR",
    "local-only": "LOCAL ONLY",
    "none": "NO TEST",
}
ROUTE_LABEL = {"bundle_ids": "bundle id", "homebrew": "homebrew", "npm": "npm",
               "pypi": "PyPI", "binaries": "binary", "state_dirs": "state dir",
               "launchd_prefixes": "launchd", "ports": "port", "model_stores": "model store",
               "native_messaging_hosts": "native msg", "images": "image",
               "extension_ids": "extension id"}
DOC = ROOT / "docs" / "agents.md"
README = ROOT / "README.md"
# THERE IS NO "last verified" FILE ANY MORE, and the reason is worth keeping: it could not
# work the way it was built. record() runs on each scenario's own runner and wrote the dates
# there, but only observed-* is uploaded as an artifact -- so the collect job never saw them
# and the committed file stayed frozen at whatever the commit that introduced it contained.
# The rendered table named one scenario at one date forever, which read as "everything else
# is unverified" when the whole suite runs on every push and nightly.
#
# The question it meant to answer is answered better elsewhere: the workflow's own run
# history says when a scenario last ran, and observed.json says what it proved.
# The coverage badge is GENERATED, for the same reason the doc is: a number written by hand
# in a README is a claim nothing checks, and this one sits at the top of the page where it is
# read first and verified least.
BADGE = re.compile(r"(identifiers_covered_by_a_CI_test-)(\d+)(%2F)(\d+)(-)([0-9A-Fa-f]{6})")


def badge_for(data):
    """The one place the coverage numbers are computed. Every badge uses it.

    A RETIRED ALIAS IS OUT OF BOTH HALVES. Nothing installs it any more, so no CI test can
    cover it -- counting it in the numerator would claim a test that does not exist, and
    counting it only in the denominator would cap the figure below complete for a reason
    nobody can act on. It is excluded, and the report says how many were excluded.

    Two badges disagreed before this existed: README read 40/40 by counting aliases as
    covered, and the report read 38/40 by counting them only in the denominator. Both were
    drawn from the same data and neither was right.
    """
    ids = [i for a in data["agents"] for i in a["identifiers"]]
    # A NO-CI-PLATFORM IDENTIFIER IS OUT OF BOTH HALVES, for the same reason a retired
    # alias is: no test can cover it, so counting it in the numerator would claim one that
    # does not exist, and counting it only in the denominator would cap the figure below
    # complete for a reason nobody can act on. It is counted and named in the breakdown
    # instead: the identifier table below names every route and the platforms it was
    # observed on, which is a fact someone can act on rather than a score to read.
    n = sum(1 for i in ids if i["state"] not in ("superseded", "no-ci-platform"))
    covered = sum(1 for i in ids if i["state"] in ("ci-install", "ci-fixture"))
    # Green only at complete. Anything less is amber -- a badge that reads green at 90%
    # trains the reader to stop looking at the number beside it.
    colour = "2E7D57" if covered == n else "A26A16"
    return covered, n, colour


def rewrite_badge(data, text):
    covered, n, colour = badge_for(data)
    return BADGE.sub(lambda m: f"{m.group(1)}{covered}{m.group(3)}{n}{m.group(5)}{colour}", text)


def markdown(data):  # noqa: C901
    """Render docs/agents.md.

    DETERMINISTIC ON PURPOSE -- no timestamp, no run id, nothing that changes when the
    inputs did not. --check compares this against the committed file, so anything varying
    per run would make the gate fire on every push and teach people to ignore it. If this
    file's diff is non-empty, the catalog or its coverage genuinely moved.
    """
    agents = data["agents"]
    n_ident = sum(len(a["identifiers"]) for a in agents)
    n_fix = sum(1 for a in agents for i in a["identifiers"] if i["fixture"])
    n_scen = sum(1 for a in agents if a["scenarios"])
    na = set(data.get("not_agents", ()))
    n_tools = sum(1 for a in agents if a["classification"] in na)
    n_st = lambda s: sum(1 for a in agents for i in a["identifiers"] if i["state"] == s)
    n_ci = n_st("ci-install") + n_st("ci-fixture")

    # DISTINCT identifiers that only a fixture proves, counted once. The first version of
    # this summed the per-platform fixture counts and divided by the number of rows, which
    # gave the right answer only because the single fixture-only identifier happens to sit
    # on a portable route and so appeared in both rows. A platform-specific fixture would
    # have made it wrong, and silently.
    n_fixture_only = n_st("ci-fixture")
    _fx_phrase = ("identifier is fixture-only, so it sits" if n_fixture_only == 1
                  else "identifiers are fixture-only, so they sit")

    _fx = [i["value"] for a in agents for i in a["identifiers"]
           if i["state"] == "ci-fixture"]
    _fx_is = "is" if len(_fx) == 1 else "are"
    _fx_names = ", ".join(f"`{v}`" for v in sorted(_fx))

    out = [
        "<!-- GENERATED BY tools/agent_status.py -- DO NOT EDIT.",
        "     Regenerate with `python3 tools/agent_status.py --write`.",
        "     CI fails if this file does not match the catalog. -->",
        "",
        "<div align=\"center\">",
        "",
        "# 🔎 What we detect, and what proves it",
        "",
        "Every AI agent this repo finds, every identifier it is matched on,",
        "and the CI test behind each one.",
        "",
        f"![agents](https://img.shields.io/badge/agents-{len(agents)}-1D4E89)",
        f"![identifiers](https://img.shields.io/badge/identifiers-{n_ident}-1D4E89)",
        f"![covered](https://img.shields.io/badge/covered_by_a_CI_test-"
        f"{badge_for(data)[0]}%2F{badge_for(data)[1]}-{badge_for(data)[2]})",
        f"![real install](https://img.shields.io/badge/by_real_install-{n_st('ci-install')}"
        f"-2E7D57)",
        "",
        "</div>",
        "",
        "> **Generated** from `catalog/agents.yaml`, `catalog/routes.yaml`, the fixtures and",
        "> what each CI scenario actually matched. Lint fails when it drifts.",
        "",
        # ONE INDICATOR, AND IT IS A GATE RATHER THAN A PROGRESS BAR.
        #
        # A per-platform table stood here, reporting `darwin 41/45` and `linux 18/25` beside
        # a badge reading 48/48. Every number was right and the three together were
        # unreadable: figures that look like they should agree, counting different things,
        # two of them permanently short of their own totals by design.
        #
        # A fraction invites "91% done". This is not progress -- anything below complete is
        # a red build, which --check enforces -- so there is ONE number, it always reads
        # complete, and the platform detail moved to the per-identifier table below, where
        # it is a fact someone can act on instead of a score to interpret.
        # SAID ONCE. Three statements stood here in a row -- the coverage fact, then "a real
        # install is the standard, and every entry meets it", then a count of agents and
        # identifiers the badges above already carried. All three were true and the second
        # and third added nothing, which reads as emphasis rather than as information.
        # THE STRONG CLAIM ONLY WHEN IT IS TRUE. This read "covered by a CI test that
        # installs the real software -- 48 of 48" directly above "47 are proved by a real
        # install", which is a contradiction of exactly one: the headline was counting
        # every covered identifier and describing only the real-install ones.
        ((f"**Every identifier is proved by a real install in CI** — {n_ci} of "
          f"{n_ident - n_st('superseded')}.")
         if n_ci == n_st("ci-install") else
         (f"**Every identifier is covered by a CI test** — {n_ci} of "
          f"{n_ident - n_st('superseded')}, {n_st('ci-install')} of them by a real "
          f"install."))
        + (f" {n_st('superseded')} superseded identifier(s) are excluded: the release that "
           f"produced them is gone, and each names the run that last did."
           if n_st("superseded") else "")
        + " Anything below complete is a red build, so there is no partial number to read"
          " here.",
        "",
        # Only describe a split when there IS one. Without one this restated the badges.
        (f"{len(agents)} entries carrying {n_ident} identifiers &mdash; "
         f"**{len(agents) - n_tools} agents** and **{n_tools} not**." if n_tools else None),
        "## 🧪 Why a real install is the bar",
        "",
        "`bot.molt.mac` came off OpenClaw's own Homebrew metadata and matched nothing on any",
        "Mac. `aider` installs as `aider-chat` under `uv` and `pipx` while its state directory",
        "is `~/.aider`, so evidence and signature never met. Both were silent and both survived",
        "review.",
        "",
        "Coverage is counted **per identifier**, from what each scenario recorded in its own",
        "`observed.json`, and only from scenarios in the CI matrix — an agent can pass while",
        "carrying an identifier nothing exercised.",
        "",
        # A TABLE OF ZEROS IS A CONFUSING STAT. This listed all six states with a count
        # each, and five of them are zero and must stay zero -- `--check` fails the build
        # if `local only`, `did not appear` or `no test` is ever anything else. So it read
        # as a scoreboard when it is a gate, and the one non-zero row invited the question
        # "what is that 1 doing there".
        #
        # The states still exist and still label each identifier in the tables below. What
        # goes is presenting them as a distribution.
        # NOTHING RESTATES THE SPLIT. "47 are proved by a real install" stood here while
        # the headline above already read "47 of them by a real install"; the only thing
        # left worth saying is which identifier is the exception, and why.
        # NO EXPLANATION IS WRITTEN IN HERE, because the last one outlived its own fact.
        # It read "no scenario can emit an `image` row at all" -- true while containers.sql
        # reached nobody, false the day 79-linux-image began asserting against
        # bin/discover --deep. A generated page is the wrong place for a standing excuse:
        # this names the identifier and where its evidence comes from, and the sentence
        # disappears on its own when a real install records one.
        *([f"**The remaining {n_st('ci-fixture')} {_fx_is} {_fx_names}**, whose recorded "
           f"evidence is a captured row rather than a live install -- "
           f"`test/docker_states.sh` serves real images through a fake socket and asserts "
           f"the real runner and matcher claim the catalogued one and decline the rest. "
           f"A CI scenario that installs it for real has not recorded an observation yet.",
           ""]
          if n_st("ci-fixture") else []),
        # The floor note names scenarios in CI that have recorded nothing yet -- but only
        # where that actually costs coverage. It used to fire for ANY unrecorded scenario,
        # including `76-linux-systemd`, which asserts no identifiers at all, so it warned
        # that a number was a floor while the table beside it read zero.
        *((["> **This number is a floor.** `" + "`, `".join(data["ci_unrecorded"])
            + "` are in the CI matrix and have recorded nothing yet. Absence of an "
              "observation is not absence of a test, and the count corrects itself once "
              "each has run.", ""])
          if data.get("ci_unrecorded") and n_st("none") + n_st("tested-absent") else []),
        "`tools/validate_catalog.py` refuses an agent no scenario installs. There is no block",
        "that buys an exception, so an unproved signature cannot enter at all.",
        "",
    ]

    by_class = {}
    for a in agents:
        by_class.setdefault(a["classification"], []).append(a)

    for group, want_agent, blurb in (
            ("Agents", True,
             "Software that acts on the user's behalf. This is what the catalog is for."),
            ("Model runners", False,
             "**Not agents, and not language models either.** These serve models on the "
             "machine; an agent is what drives one. Counted separately so the agent number "
             "means what it says. The *models* they hold are a different thing again and "
             "appear as `kind=model` rows from the `model_stores` route.")):
        classes = [c for c in data["classifications"]
                   if c in by_class and (c not in na) == want_agent]
        if not classes:
            continue
        n = sum(len(by_class[c]) for c in classes)
        out += [f"# {group} ({n})", "", blurb, ""]
        for cls in classes:
            out += [f"## {cls}", "",
                    # NO `evidence` COLUMN. It held "real install" for every row and could
                    # hold nothing else once the exception register went -- a column with
                    # one possible value reads as a distinction being drawn when none is.
                    "| name | identifiers | scenarios |", "|---|---|---|"]
            for a in sorted(by_class[cls], key=lambda x: x["id"]):
                # `no-ci-platform` WAS MISSING FROM THIS DICT, and would have raised a
                # KeyError the first time an identifier reached that state -- the page that
                # describes the catalog, crashed by a catalog entry. It never fired only
                # because every route has a runner today.
                MARK = {"ci-install": "**`%s`**", "ci-fixture": "`%s`",
                        "superseded": "~~`%s`~~", "local-only": "_`%s`_",
                        "no-ci-platform": "%s ∅", "tested-absent": "%s ⚠", "none": "%s"}
                ids = ", ".join(MARK[i["state"]] % i["value"]
                                for i in a["identifiers"]) or "--"
                out.append(f"| **{a['name']}** | {ids} | "
                           f"{', '.join(a['scenarios']) or '--'} |")
            out.append("")

    out += ["> **`bold`** = CI installs it for real. `code` = CI fixture only. ~~`struck`~~ = "
"superseded: a run proved it and the current release no longer emits it. "
            "∅ = no CI runner for its platform. ⚠ = a scenario installed this agent and "
            "the identifier did not appear. plain = nothing tests it.", ""]


    unex = [(a, i) for a in sorted(agents, key=lambda x: x["id"])
            for i in a["identifiers"]
            if i["state"] in ("none", "local-only", "tested-absent")]
    if unex:
        out += ["## ⚠️ Identifiers that did not pass", "",
                "Every one is work, and the middle column says what kind. **did not appear** "
                "means a scenario installed the agent and this identifier never showed up — "
                "the suite reached it and it did not reproduce, usually because the scenario "
                "installs by a different route, or because the artifact only exists once the "
                "agent has run.", "",
                "| agent | route | identifier | state | reached by |", "|---|---|---|---|---|"]
        LABEL = {"local-only": "local only", "tested-absent": "did not appear",
                 "none": "no test"}
        out += [f"| {a['name']} | {ROUTE_LABEL.get(i['route'], i['route'])} | `{i['value']}` | "
                f"{LABEL[i['state']]} | {', '.join(i.get('reached_by') or []) or '--'} |"
                for a, i in unex]
        out.append("")

    if data.get("blind_spots"):
        out += ["## 🚧 What osquery cannot see", "",
                "These are properties of the platform and the tables, not of any one scenario, so",
                "they are stated once. No amount of test coverage moves them.", "",
                "| blind spot | why |", "|---|---|"]
        out += [f"| {b['spot']} | {b['why']} |" for b in data["blind_spots"]]
        out.append("")

    # ONE ROW PER GAP, and only for a gap. This section used to render every known_gaps
    # entry as its own bold heading and paragraph, and most of them were not coverage gaps
    # at all: a solved trap already commented in setup.sh, a correction to an earlier
    # version of this file, a safety warning about a script, a cross-reference to the
    # scenario that does cover the thing. Those belong next to the code they describe, and
    # that is where they went. What is left is the claim this section can actually make --
    # the software installed and the identifier matched, and something about HOW it was
    # installed or exercised still falls short of the real thing. That claim is worth
    # keeping: no table catches it, and a report of successes alone reads as complete when
    # it is merely silent.
    gaps = [l for l in data["limits"] if l["kind"] == "gap"]
    skips = [l for l in data["limits"] if l["kind"] == "skip"]
    if gaps or skips:
        out += ["## 🧩 What the scenarios do not prove", "",
                "The install succeeded and the identifier matched. These are the ways it still "
                "falls short of the real thing -- each one fixable by work, none of them "
                "catchable by a table of counts.", ""]
    if gaps:
        # GROUPED BY TEXT, not by scenario. Scenarios that install account-gated software
        # hit one identical wall; printing it once under all their names says so, and
        # printing it per scenario made the section look longer than the problem is.
        grouped = {}
        for l in gaps:
            grouped.setdefault(l["text"], []).append(l["scenario"])
        out += ["| scenario | not proven |", "|---|---|"]
        out += [f"| {', '.join(scens)} | {text.replace('|', chr(92) + '|')} |"
                for text, scens in grouped.items()]
        out.append("")
    if skips:
        # ONE LINE. The full reason lives in each requires.json, which is the file that
        # enforces it; repeating it here made two runner facts look like two defects.
        by_ver = {}
        for l in skips:
            by_ver.setdefault(l.get("min_macos"), []).append(l["scenario"])
        for ver, scens in sorted(by_ver.items(), key=lambda kv: (kv[0] is None, kv[0])):
            need = f"macOS {ver} or newer" if ver else "a newer runner"
            out += [f"{', '.join('`' + s + '`' for s in scens)} need {need}, so CI skips "
                    f"them on older runners rather than failing them. Each scenario's "
                    f"`requires.json` carries the reason.", ""]

    # LAST, NOT FIRST. This is the scope rule, and it reads better as the thing you check a
    # surprising row against than as a preamble to be got through: a reader arrives wanting
    # the table, and meets the boundary argument once they have seen what is in it.
    out += ["## 🎯 What counts as an agent", "",
            "**An agent acts on the user's behalf.** That is the only test.", "",
            "Two easier questions are deliberately not the test: *is this AI software?* and "
            "*can we detect it?* Everything in the table below answers yes to both, which is "
            "why the pull to include it is real. None of it acts for the user, so none of it "
            "is counted: a model server or a client library sitting on a Mac is not an "
            "agent running there, and reporting it as one inflates the finding.", "",
            "| removed | what it actually is |", "|---|---|",
            *(f"| `{r['id']}` | {r['what_it_is']} |" for r in data.get("removed", [])),
            "",
            "Each keeps its fixture rows, with the assertion inverted to *must not match*. "
            "Deleting the evidence with the signature would leave nothing to tell *correctly "
            "not an agent* from *route quietly broken*.", "",
            "One boundary is contested rather than settled. **Desktop assistant** is counted "
            "as an agent: the old definition read *no autonomous execution*, which stopped "
            "being true when these clients gained MCP and began running tools locally. "
            "Overstating an agent is the safer error for an inventory than missing one, but "
            "it is a judgement, not a fact.", ""]

    return "\n".join(x for x in out if x is not None).rstrip() + "\n"


def main():
    data = collect()
    if "--record" in sys.argv:
        i = sys.argv.index("--record")
        def opt(flag):
            return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else ""
        # --run-id falls back to GITHUB_RUN_ID so a workflow that forgets the flag still
        # records provenance. NOT the other way round: an explicit flag wins, because
        # test/run.sh drives a VM whose run id is the host's, not the guest's.
        record(sys.argv[i + 1], sys.argv[i + 2], opt("--os"), opt("--arch"),
               opt("--platform"), opt("--run-id") or os.environ.get("GITHUB_RUN_ID", ""))
        return
    if "--json" in sys.argv:
        print(json.dumps(data, indent=2))
        return
    if "--markdown" in sys.argv:
        print(markdown(data), end="")
        return
    if "--write" in sys.argv:
        DOC.parent.mkdir(exist_ok=True)
        DOC.write_text(markdown(data))
        out = [str(DOC.relative_to(ROOT))]
        if README.exists():
            before = README.read_text()
            after = rewrite_badge(data, before)
            if after != before:
                README.write_text(after)
                out.append("README.md badge")
        print("wrote " + ", ".join(out))
        return
    if "--gate" in sys.argv:
        # NOTHING SHIPS IN THE CATALOG WITHOUT A REAL TEST. Fails on any identifier no CI
        # test covers, unless the catalog carries a dated reason for it.
        #
        # NO EXCUSE LIST. `untested:` let an identifier no test covers ship on a reason
        # and a date, and it held nothing for its entire life -- while remaining the one
        # way past this gate that did not require a machine to have produced the value.
        # An identifier is covered, or it is not here.
        bad = []
        for agent in data["agents"]:
            for i in agent["identifiers"]:
                if i["state"] not in ("ci-install", "ci-fixture", "superseded"):
                    bad.append(f"{agent['id']}: {i['route']}:{i['value']} is {i['state']} "
                               f"-- no CI test covers it. Cover it, or remove it: an "
                               f"identifier no test can produce is a guess with a comment "
                               f"beside it, and the two are indistinguishable.")
        if bad:
            print("catalog-gate: FAIL")
            for b in bad:
                print(f"  {b}")
            sys.exit(1)
        # The same numbers as every badge, from badge_for, so the gate cannot say "all 40"
        # while the page beside it says 38/38.
        covered, n, _ = badge_for(data)
        aliases = sum(1 for a in data["agents"] for i in a["identifiers"]
                      if i["state"] == "superseded")
        print(f"catalog-gate: ok, {covered}/{n} identifiers are covered by a CI test"
              + (f", {aliases} superseded excluded" if aliases else ""))
        return

    if "--check" in sys.argv:
        # ANYTHING BELOW COMPLETE IS A RED BUILD, checked before staleness because a
        # correctly-generated page reporting partial coverage is still a failure.
        #
        # --gate already refuses an identifier no CI test covers, but it ACCEPTS an
        # `untested:` entry as an excuse -- so coverage could sit at 47/48 with a reason
        # recorded and every check green. That is the state this repo has no use for: the
        # figure is a gate, not a progress bar, and a page that can say "91%" invites
        # someone to read it as progress rather than as breakage.
        #
        # So the excuse mechanism no longer buys a green build. It still buys a REASON,
        # which is the part worth keeping: the failure below names the identifiers, and
        # `untested:` says why each one is there for whoever reads it.
        covered, coverable, _ = badge_for(data)
        if covered != coverable:
            short = [(a["id"], i["route"], i["value"], i["state"])
                     for a in data["agents"] for i in a["identifiers"]
                     if i["state"] not in ("ci-install", "ci-fixture", "superseded")]
            print(f"agent-status: FAIL -- coverage is {covered}/{coverable}, not complete.")
            for aid, route, value, state in short:
                print(f"  {aid}: {route}:{value} is {state}")
            print("  Every identifier must be covered by a CI test. Cover it, or remove it "
                  "-- an identifier no test can produce is a guess with a comment beside it.")
            sys.exit(1)
        want = markdown(data)
        have = DOC.read_text() if DOC.exists() else ""
        if README.exists() and rewrite_badge(data, README.read_text()) != README.read_text():
            c, n, _ = badge_for(data)
            print(f"agent-status: FAIL -- README's coverage badge is stale. It should read "
                  f"{c}/{n}.")
            print("  Fix: python3 tools/agent_status.py --write")
            sys.exit(1)
        if want != have:
            print("agent-status: FAIL -- docs/agents.md is stale.")
            print("  The catalog or its test coverage changed and the doc was not regenerated.")
            print("  Fix: python3 tools/agent_status.py --write")
            sys.exit(1)
        print("agent-status: ok, docs/agents.md matches the catalog")
        return

    agents = data["agents"]
    n_ident = sum(len(a["identifiers"]) for a in agents)
    n_fix = sum(1 for a in agents for i in a["identifiers"] if i["fixture"])
    n_scen = sum(1 for a in agents if a["scenarios"])
    na = set(data.get("not_agents", ()))
    n_tools = sum(1 for a in agents if a["classification"] in na)

    by_class = collections.defaultdict(list)
    for a in agents:
        by_class[a["classification"]].append(a)

    # Two top-level groups, not one list with a tag. A container runtime listed among
    # agents reads as an agent however it is labelled, and the count that matters to
    # someone asking "what AI is on this Mac" is the agent count.
    for group, want_agent in (("AGENTS", True), ("NOT AGENTS", False)):
        classes = [c for c in data["classifications"]
                   if c in by_class and (c not in na) == want_agent]
        if not classes:
            continue
        print(f"\n{'=' * 62}\n{group}\n{'=' * 62}")
        for cls in classes:
            print(f"\n  {cls}")
            for a in sorted(by_class[cls], key=lambda x: x["id"]):
                print(f"    {a['name']:<22} {len(a['identifiers'])} identifiers"
                      + (f"  [{', '.join(a['scenarios'])}]" if a["scenarios"] else ""))
                for i in a["identifiers"]:
                    print(f"        {STATE_LABEL[i['state']]:<17} {i['route']}: {i['value']}")

    print(f"\n{len(agents)} entries: {len(agents) - n_tools} agents and {n_tools} "
          f"supporting tools. {n_ident} identifiers.")
    print("  every one backed by a real install, or validate_catalog would have failed")
    n = lambda s: sum(1 for a in agents for i in a["identifiers"] if i["state"] == s)
    covered = n("ci-install") + n("ci-fixture")
    # Retired aliases are out of the denominator. No install produces them, so including
    # them would cap the number below 100% for a reason nobody can act on.
    coverable = n_ident - n("superseded")
    print(f"\nIDENTIFIERS COVERED BY A CI TEST   {covered}/{coverable}"
          f"   ({100 * covered // coverable}%)")
    # ONLY THE STATES THAT ARE ACTUALLY POPULATED, for the same reason the page no longer
    # prints the distribution: four of these are zero and must stay zero -- `--check` fails
    # the build otherwise -- so listing them reads as a scoreboard when it is a gate, and
    # the one non-zero row invites "what is that doing there".
    for state, note in (
            ("ci-install", "a scenario in the scenarios.yml matrix installs the software\n"
                           f"{'':>21}  and asserts the classifier finds it"),
            ("ci-fixture", "evidence is a captured row, not a live install. "
                           "test/docker_states.sh\n"
                           f"{'':>21}  asserts it on both platforms on every pull request"),
            ("local-only", "proved only by a scenario CI does not run"),
            ("tested-absent", "a CI scenario installed the agent and it never showed up"),
            ("none", "nothing exercises it")):
        if n(state):
            print(f"  {STATE_LABEL[state]:<17}{n(state):>3}  {note}")
    if n("superseded"):
        print(f"\n  {n('superseded')} superseded identifier(s) are excluded: nothing installs them any "
              f"more, so no\n  scenario can cover one. Their fixture rows are the only "
              f"evidence there is.")
    # Only where an unrecorded scenario actually costs coverage. It used to fire for any
    # scenario without an observation -- including one that asserts no identifiers at all,
    # so it announced a floor while every gap count read zero.
    if data.get("ci_unrecorded") and n("none") + n("tested-absent"):
        print(f"\n  THIS IS A FLOOR. {len(data['ci_unrecorded'])} scenario(s) are in the CI "
              f"matrix and have recorded\n  nothing yet: "
              f"{', '.join(data['ci_unrecorded'])}")


if __name__ == "__main__":
    main()
