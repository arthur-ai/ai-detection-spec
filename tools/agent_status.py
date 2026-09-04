#!/usr/bin/env python3
"""Report every agent in the catalog and what evidence backs it.

GENERATED, NEVER HAND-MAINTAINED. A hand-written coverage table is a second copy of
the catalog that drifts from the first, and this repo's whole argument is that a
plausible-looking wrong answer is the expensive kind. Everything here is read off
catalog/agents.yaml, test/fixtures/ and test/scenarios/ at the moment it runs.

Coverage is reported at two strengths, because they are not the same claim:

  scenario   a VM installed the real software and the classifier found it. This is the
             only evidence that survives the bot.molt.mac failure -- a vendor-documented
             identifier that matched nothing on any Mac.
  fixture    the classifier matched a row in test/fixtures/. The rows were captured from
             real machines, but nothing re-checks them against a current install, so a
             fixture proves the MATCHER works and cannot prove the IDENTIFIER is current.

An identifier with neither is not necessarily wrong. It is unexercised, which is a
different thing and is why it is named rather than hidden.
"""
import collections
import importlib.machinery      # NOT implied by importlib.util. Importing only .util
import importlib.util              # left importlib.machinery resolvable on a developer Mac,
                                   # where something else had already imported it, and
                                   # AttributeError on a clean runner -- which is where it
                                   # failed: every scenario job, in the recording step.
import json
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
ROUTES = classify_mod.load_routes()
REGISTRY = classify_mod.Registry(ROUTES)
# Declaration order, which is what the report renders in.
ALL_ROUTES = list(ROUTES["routes"])
# Routes that can only ever be credited at ROUTE level, never per value: a prefix or a
# path glob tells you the route fired, not which of its values did. `GLOB_ROUTES` was the
# old name and it under-described itself -- launchd_prefixes is a prefix, not a glob.
ROUTE_LEVEL_ONLY = {n for n, m in REGISTRY.match.items()
                    if m == "prefix" or m.startswith("home-")}


def _plain(block):
    """Make an `unverified` block JSON-safe without losing anything."""
    if not isinstance(block, dict):
        return block
    return {k: (v if isinstance(v, (str, int, float, bool, type(None))) else str(v))
            for k, v in block.items()}


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


def record(artifact, scenario_dir, os_version="", arch="", platform=""):
    """Write scenario/observed.json: which identifiers a REAL run actually matched.

    test/artifacts/ is gitignored and per-machine, so the raw output cannot back a
    committed document. This is the compact, reviewable residue of a run -- the
    observations layer of docs/signature-lifecycle.md, at its smallest useful size.
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
        was = {(r["agent"], r["route"], r["value"])
               for r in json.loads(out_path.read_text()).get("identifiers", [])
               if (r.get("platform"), r.get("os"), r.get("arch")) == plat}
        now = {(r["agent"], r["route"], r["value"]) for r in idents}
        lost = sorted(was - now)
        if lost:
            print(f"refusing to record {out_path.parent.name}: this run proves "
                  f"{len(lost)} fewer identifier(s) than the committed record:")
            for a, r, v in lost:
                print(f"  lost  {a} {r}:{v}")
            print("If the artifact is current and the loss is real, pass --allow-shrink.")
            sys.exit(1)

    # record() is called directly by test/test_matcher.py against a TemporaryDirectory, which
    # is not a scenario and gets no merge with a committed record.
    scen = pathlib.Path(scenario_dir).resolve()
    if scen.parent != (ROOT / "test" / "scenarios").resolve():
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
    for path in sorted((ROOT / "test" / "scenarios").glob("*/expected.json")):
        doc = json.loads(path.read_text())
        scenario_platform[path.parent.name] = doc.get("platform")
        block = doc.get("classified", {})
        for aid in block.get("must_find", []):
            scenarios[aid].add(path.parent.name)

    # Fixtures prove the MATCHER. A scenario's own output proves the IDENTIFIER, because
    # those rows came off a machine where the software was really installed. Same replay,
    # two sources, and the stronger one wins per identifier.
    values, routes, _ = replay(sorted((ROOT / "test" / "fixtures").glob("*.json")), catalog)
    # Keyed by scenario, so an identifier proved only outside CI can be told apart from
    # one a pull request would catch.
    seen_in = collections.defaultdict(set)      # (agent, route, value) -> {scenario}
    observed_os = set()
    for path in sorted((ROOT / "test" / "scenarios").glob("*/observed.json")):
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
    for path in sorted((ROOT / "test" / "scenarios").glob("*/expected.json")):
        name = path.parent.name
        if name not in in_ci:
            continue
        for aid in json.loads(path.read_text()).get("classified", {}).get("must_find", []):
            asserted_by[aid].add(name)
    # A CI scenario that has never RECORDED contributes nothing to the numbers below, so
    # the count is pessimistic until each has run once. Absence of an observation is not
    # absence of a test, and reporting the total without saying which scenarios are
    # missing would present a floor as a measurement.
    recorded = {p.parent.name for p in (ROOT / "test" / "scenarios").glob("*/observed.json")}
    unrecorded = sorted(in_ci - recorded)

    agents = []
    retired_of = {a["id"]: {str(v) for v in a.get("retired", [])} for a in catalog["agents"]}
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
                elif str(value) in retired_of.get(aid, ()):
                    state = "alias"
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
            # The recorded exception, when this agent is not backed by a real install.
            # validate_catalog.py refuses an agent that has neither.
            #
            # `raised` is coerced to str because PyYAML resolves an unquoted YYYY-MM-DD to a
            # datetime.date, which json.dumps cannot serialise -- so --json died while
            # --write and --check, which never touch the field, both passed. Fixed here
            # rather than by quoting the value in the catalog: a contributor writing a bare
            # date is doing nothing wrong, and the tool should not break on it.
            "unverified": _plain(agent.get("unverified")),
        })
    # What the suite cannot prove, carried alongside what it can. A coverage report that
    # lists only successes is the same failure mode as an empty result on a clean machine:
    # it reads as complete when it is merely silent.
    limits = []
    for path in sorted((ROOT / "test" / "scenarios").glob("*/*.json")):
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
    "alias": "alias (fixture)",
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
    # instead -- see platform_badges() -- which is where an embarrassing zero belongs.
    n = sum(1 for i in ids if i["state"] not in ("alias", "no-ci-platform"))
    covered = sum(1 for i in ids if i["state"] in ("ci-install", "ci-fixture"))
    # Green only at complete. Anything less is amber -- a badge that reads green at 90%
    # trains the reader to stop looking at the number beside it.
    colour = "2E7D57" if covered == n else "A26A16"
    return covered, n, colour


def platform_badges(data):
    """Per-platform coverage, as (platform, covered, coverable, has_ci) rows.

    ALWAYS RENDERED, even at zero. `no-ci-platform` is a new place a guess could hide, and
    this is one of the two things that stops it: the number sits on the generated front
    page where a zero is visible, rather than being absorbed into a single figure that
    reads complete. The other is --gate, which fails the moment a platform joins the CI
    matrix with identifiers uncovered.
    """
    plats = ci_platforms()
    rows = []
    for plat in sorted(REGISTRY.platforms):
        ids = [i for a in data["agents"] for i in a["identifiers"]
               if plat in i.get("platforms", [])]
        n = sum(1 for i in ids if i["state"] not in ("alias", "no-ci-platform"))
        # OBSERVED ON THIS PLATFORM, not merely coverable on it. A fixture is deliberately
        # not counted here: it proves the matcher resolves an identifier, which is a claim
        # about code and not about any platform's software.
        covered = sum(1 for i in ids if plat in i.get("observed_on", []))
        if ids:
            rows.append((plat, covered, n, plat in plats))
    return rows


def rewrite_badge(data, text):
    covered, n, colour = badge_for(data)
    return BADGE.sub(lambda m: f"{m.group(1)}{covered}{m.group(3)}{n}{m.group(5)}{colour}", text)


def grade(agent):
    """A real install is the STANDARD. Everything else is an exception.

    Deliberately binary at the top level. Reporting three peer grades invited reading
    "fixture only" as a second kind of pass, and it is not one: a fixture proves the
    matcher works against a row somebody captured once, and says nothing about whether
    the identifier is still what the software installs today.
    """
    return "standard" if agent["scenarios"] else "exception"


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
        "> **This page is generated.** `tools/agent_status.py` counts it from",
        "> `catalog/agents.yaml`, `catalog/routes.yaml`, the test fixtures, and what each",
        "> CI scenario actually matched. Lint fails when it drifts, so it cannot describe",
        "> a catalog that has moved on without it. Nothing here is typed by hand.",
        "",
        # PER PLATFORM, ALWAYS, EVEN AT ZERO.
        #
        # One number across platforms is the shape of claim this repo exists to avoid: a
        # portable identifier observed on macOS says nothing about Linux, so averaging
        # them puts a confident face on an untested platform. `observed_on` is what this
        # counts, which is why a `posix` route proved only on a Mac shows here as covered
        # for darwin and NOT for linux.
        "### Coverage per platform",
        "",
        "A route's platform is where an identifier can be observed. This table counts "
        "where one **actually was** -- so a portable identifier proved on one platform "
        "does not count for the other, because the route being portable is not evidence "
        "that the software is.",
        "",
        "| platform | covered | coverable | CI runs it |",
        "|---|---|---|---|",
        *[f"| `{plat}` | {cov} | {tot} | {'yes' if ci else '**no**'} |"
          for plat, cov, tot, ci in platform_badges(data)],
        "",
        *(["A platform with no CI runner has its identifiers counted as "
           "`NO CI PLATFORM` and excluded from the badge above, the same way a retired "
           "alias is: no test can cover them, so counting them either way would be a "
           "claim nobody can act on. They are named here instead.", ""]
          if any(not ci for _, _, _, ci in platform_badges(data)) else []),
        # One line, not two. The policy and the current state were being stated separately
        # and adjacently, which read as emphasis rather than as information.
        ("**A real install is the standard, and every entry meets it.** A CI scenario installs "
         "the real software and asserts the classifier finds it. Anything less would be an "
         "exception recorded in the catalog with a reason, an evidence grade and a date; there "
         "are none open."
         if not (len(agents) - n_scen) else
         "**A real install is the standard. Everything else is an exception, and every "
         "exception is recorded.**"),
        "",
        (f"| | entries | |\n|---|---:|---|\n"
         f"| **standard** | {n_scen} | a CI scenario installs the real software and asserts "
         f"the classifier finds it |\n"
         f"| **exception** | {len(agents) - n_scen} | recorded in the catalog with a reason, an "
         f"evidence grade and the date it was raised |"
         if len(agents) - n_scen else None),
        # Only describe a split when there IS one. "15 entries, 15 of them agents" says the
        # same thing twice, and reads as though something is being held back.
        (f"{len(agents)} agents carrying {n_ident} identifiers."
         if not n_tools else
         f"{len(agents)} entries carrying {n_ident} identifiers &mdash; "
         f"**{len(agents) - n_tools} agents** and **{n_tools} not**."),
        "",
        "## 🧪 Why a real install is the bar",
        "",
        "`bot.molt.mac` was read off OpenClaw's own Homebrew metadata and matched nothing on any",
        "Mac. `aider` installs as `aider-chat` under `uv` and `pipx` while its state directory is",
        "`~/.aider`, so evidence and signature never met. Both were silent, both survived review,",
        "and neither survived contact with an actual install. Nothing short of installing the",
        "software catches that class of error.",
        "",
        f"## 📊 {n_ci}/{n_ident - n_st('alias')} identifiers are covered by a CI test",
        "",
        "**Measured per identifier, and only counting tests CI actually runs.** Two things make",
        "that different from \"has anyone tested this\". An entry passes when a scenario finds it,",
        "but `expected.json` names the *agent* and never the identifier that matched — so an entry",
        "could look verified while carrying identifiers nothing had exercised. And a scenario that",
        "runs only on a maintainer's Mac catches nothing on a pull request: `45-claude-extension`",
        "sat in exactly that state, passing locally and absent from the CI matrix.",
        "",
        "Each scenario records what it actually matched in its own `observed.json`, and",
        "`tools/check_workflows.py` fails if a scenario is missing from the matrix, so the two",
        "cannot drift apart again.",
        "",
        f"| | identifiers | |",
        "|---|---:|---|",
        f"| **CI: real install** | {n_st('ci-install')} | a scenario in the `scenarios.yml` matrix "
        f"installs the software and asserts the classifier finds it |",
        f"| **CI: fixture** | {n_st('ci-fixture')} | matched a captured row by `test_matcher.py`, "
        f"which runs on **every pull request**. A weaker claim than a real install and a faster "
        f"cadence — different axes |",
        f"| **local only** | {n_st('local-only')} | proved only by a scenario CI does not run. "
        f"Catches nothing on a pull request |",
        f"| **did not appear** ⚠ | {n_st('tested-absent')} | a CI scenario installed the "
        f"agent and this identifier never showed up. Usually installed by another route |",
        f"| **no test** | {n_st('none')} | nothing exercises it at all |",
        (f"| _retired alias_ | _{n_st('alias')}_ | _excluded from the count. Nothing installs "
         f"these any more, so no scenario can cover one; the fixture row is the only evidence "
         f"there is, and it proves the alias still resolves_ |"
         if n_st("alias") else None),
        # The floor note is optional, so it carries its OWN leading blank rather than being
        # bracketed by two: dropped, it used to leave the pair behind as a triple newline.
        *((["", "> **This number is a floor.** `" + "`, `".join(data["ci_unrecorded"])
            + "` run in CI and have recorded nothing yet, so identifiers they cover still "
              "count as *no test*. Absence of an observation is not absence of a test; the "
              "count corrects itself once each scenario has run."])
          if data.get("ci_unrecorded") else []),
        "",
        "`tools/validate_catalog.py` refuses an agent that is neither covered by a scenario nor",
        "carrying an `unverified` block, so an unverified signature cannot enter quietly.",
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
                    "| name | evidence | identifiers | scenarios |", "|---|---|---|---|"]
            for a in sorted(by_class[cls], key=lambda x: x["id"]):
                MARK = {"ci-install": "**`%s`**", "ci-fixture": "`%s`", "alias": "~~`%s`~~",
                        "local-only": "_`%s`_", "tested-absent": "%s ⚠", "none": "%s"}
                ids = ", ".join(MARK[i["state"]] % i["value"]
                                for i in a["identifiers"]) or "--"
                mark = "real install" if grade(a) == "standard" else "**exception**"
                out.append(f"| **{a['name']}** | {mark} | {ids} | "
                           f"{', '.join(a['scenarios']) or '--'} |")
            out.append("")

    out += ["> **`bold`** = CI installs it for real. `code` = CI fixture only. ~~`struck`~~ = "
            "retired alias, uninstallable by design. ⚠ = a scenario installed this agent and "
            "the identifier did not appear. plain = nothing tests it.", ""]

    exceptions = [a for a in sorted(agents, key=lambda x: x["id"]) if not a["scenarios"]]
    if exceptions:
        out += ["## The exception register", "",
                "Every agent not backed by a real install, and why. `belongs_in` names the",
                "scenario that should cover it, which makes this a work list rather than an",
                "excuse list. `blocker` appears only where something genuinely stands in the way",
                "-- its absence means the only thing missing is the work.", "",
                "| agent | evidence held | reason | belongs in | blocker |",
                "|---|---|---|---|---|"]
        for a in exceptions:
            e = a["unverified"] or {}
            out.append(f"| **{a['name']}** | {e.get('evidence','?')} | {e.get('reason','?')} "
                       f"| {e.get('belongs_in') or '--'} | {e.get('blocker') or '--'} |")
        out.append("")

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
        record(sys.argv[i + 1], sys.argv[i + 2], opt("--os"), opt("--arch"),
               opt("--platform"))
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
        # The exception list can shrink silently and never grow silently: an entry whose
        # identifier IS now covered is itself a failure, so a reason cannot outlive the gap
        # it excused. That is the property that stops such a list becoming a dumping ground.
        catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
        excused = {(e["agent"], e["route"], str(e["value"])): e
                   for e in catalog.get("untested", [])}
        bad = []
        for agent in data["agents"]:
            for i in agent["identifiers"]:
                key = (agent["id"], i["route"], i["value"])
                covered = i["state"] in ("ci-install", "ci-fixture", "alias")
                if not covered and key not in excused:
                    bad.append(f"{agent['id']}: {i['route']}:{i['value']} is {i['state']} "
                               f"-- no CI test covers it. Cover it, remove it, or record "
                               f"why under `untested:` with a reason and a raised date.")
                if covered and key in excused:
                    bad.append(f"{agent['id']}: {i['route']}:{i['value']} is listed under "
                               f"`untested:` but IS covered ({i['state']}). Delete the "
                               f"entry -- a reason must not outlive the gap it excused.")
        for k in excused:
            if not any(a["id"] == k[0] for a in data["agents"]):
                bad.append(f"`untested:` names {k[0]}, which is not an agent in the catalog")
        if bad:
            print("catalog-gate: FAIL")
            for b in bad:
                print(f"  {b}")
            sys.exit(1)
        # The same numbers as every badge, from badge_for, so the gate cannot say "all 40"
        # while the page beside it says 38/38.
        covered, n, _ = badge_for(data)
        aliases = sum(1 for a in data["agents"] for i in a["identifiers"]
                      if i["state"] == "alias")
        print(f"catalog-gate: ok, {covered}/{n} identifiers are covered by a CI test"
              + (f", {aliases} retired alias(es) excluded" if aliases else "")
              + (f", {len(excused)} excused" if excused else ""))
        return

    if "--check" in sys.argv:
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
                std = grade(a) == "standard"
                mark = "real install" if std else "EXCEPTION"
                print(f"    {a['name']:<22} {mark:<13} {len(a['identifiers'])} identifiers"
                      + (f"  [{', '.join(a['scenarios'])}]" if std else ""))
                if not std:
                    exc = a["unverified"] or {}
                    print(f"        {exc.get('evidence','?')}: {exc.get('reason','?')}")
                    if exc.get("blocker"):
                        print(f"        blocked: {exc['blocker']}")
                    if exc.get("belongs_in"):
                        print(f"        belongs in: {exc['belongs_in']}")
                for i in a["identifiers"]:
                    print(f"        {STATE_LABEL[i['state']]:<17} {i['route']}: {i['value']}")

    n_exc = len(agents) - n_scen
    print(f"\n{len(agents)} entries: {len(agents) - n_tools} agents and {n_tools} "
          f"supporting tools. {n_ident} identifiers.")
    print(f"  standard  {n_scen:>3}  backed by a real install")
    print(f"  exception {n_exc:>3}  recorded, with a reason")
    n = lambda s: sum(1 for a in agents for i in a["identifiers"] if i["state"] == s)
    covered = n("ci-install") + n("ci-fixture")
    # Retired aliases are out of the denominator. No install produces them, so including
    # them would cap the number below 100% for a reason nobody can act on.
    coverable = n_ident - n("alias")
    print(f"\nIDENTIFIERS COVERED BY A CI TEST   {covered}/{coverable}"
          f"   ({100 * covered // coverable}%)")
    print(f"  CI: real install {n('ci-install'):>3}  a scenario in the scenarios.yml matrix "
          f"installs the\n{'':>21}  software and asserts the classifier finds it")
    print(f"  CI: fixture      {n('ci-fixture'):>3}  matched a captured row by test_matcher, "
          f"which ci.yml runs\n{'':>21}  on every pull request. Proves the matcher, not "
          f"that the\n{'':>21}  identifier is current")
    print(f"  LOCAL ONLY       {n('local-only'):>3}  proved only by a scenario CI does not "
          f"run. Catches nothing\n{'':>21}  on a pull request")
    print(f"  DID NOT APPEAR   {n('tested-absent'):>3}  a CI scenario installed the agent and "
          f"this identifier\n{'':>21}  never showed up -- usually installed by another route")
    print(f"  NO TEST          {n('none'):>3}  nothing exercises it")
    if n("alias"):
        print(f"\n  {n('alias')} retired alias(es) are excluded: nothing installs them any "
              f"more, so no\n  scenario can cover one. Their fixture rows are the only "
              f"evidence there is.")
    if data.get("ci_unrecorded"):
        print(f"\n  THIS IS A FLOOR. {len(data['ci_unrecorded'])} scenario(s) run in CI and have "
              f"recorded nothing yet, so\n  identifiers they cover still count as NO TEST: "
              f"{', '.join(data['ci_unrecorded'])}")


if __name__ == "__main__":
    main()
