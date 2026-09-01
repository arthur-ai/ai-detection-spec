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
import importlib.util
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

# Routes whose catalog value is compared whole against a row's id, so an evidence row
# names the exact identifier that claimed it. The rest are globs and prefixes, which can
# only be credited at route level.
EXACT_KINDS = {"app": "bundle_ids", "brew": "homebrew", "port": "ports",
               "nmh": "native_messaging_hosts", "ext": "extension_ids"}
GLOB_ROUTES = {"state_dirs", "binaries", "model_stores", "launchd_prefixes"}
ALL_ROUTES = ["bundle_ids", "homebrew", "npm", "pypi", "binaries", "state_dirs",
              "launchd_prefixes", "ports", "model_stores", "native_messaging_hosts",
              "images", "extension_ids"]


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
    by_id = {a["id"]: a for a in catalog["agents"]}
    def agent_of(aid):
        return by_id.get(aid, {})
    for path in paths:
        rows = json.loads(path.read_text())
        rows = rows["findings"] if isinstance(rows, dict) else rows
        # classify() returns findings as {agent id: [(meta, row), ...]}, not a list.
        for aid, matched in classify_mod.classify(rows, catalog)[0].items():
            for _meta, ev in matched:
                kind, ident = ev.get("kind"), ev.get("id", "")
                if kind in EXACT_KINDS:
                    values[aid].add(ident)
                    routes[aid].add(EXACT_KINDS[kind])
                elif kind == "image":
                    for repo in classify_mod.image_repos(ident):
                        values[aid].add(repo)
                    routes[aid].add("images")
                elif kind == "npm":
                    values[aid].add(ident)
                    routes[aid].update(("npm", "pypi"))
                elif kind == "file":
                    # RESOLVE WHICH GLOB MATCHED. Crediting the whole route group here was
                    # a false positive with a very plausible face: 25-python-agents matched
                    # aider on ~/.local/share/uv/tools/aider-chat/ and this recorded
                    # `state_dirs: ~/.aider` as observed in a real install -- an identifier
                    # that appears NOWHERE in that run's output. The report then showed the
                    # strongest possible evidence for a path no machine had produced.
                    #
                    # Rebuilt the same way bin/classify builds it, so the two cannot
                    # disagree: ~/.openclaw matches /Users/<anyone>/.openclaw.
                    agent = by_id.get(aid, {})
                    loc = ev.get("loc", "")
                    for route in ("state_dirs", "binaries", "model_stores"):
                        for value in agent.get(route, []):
                            pat = re.compile(r"^/Users/[^/]+/" + re.escape(str(value)[2:]))
                            if pat.match(ident) or pat.match(loc):
                                values[aid].add(str(value))
                                routes[aid].add(route)
                    # A pipx/uv tool directory names its PACKAGE, which is why classify
                    # checks the npm and pypi routes for it and not the path globs.
                    tool = classify_mod.TOOL_DIR.match(ident) or classify_mod.TOOL_DIR.match(loc)
                    if tool:
                        name = tool.group(1)
                        for route in ("pypi", "npm"):
                            if name in [str(v) for v in agent.get(route, [])]:
                                values[aid].add(name)
                                routes[aid].add(route)
                elif kind == "daemon":
                    for value in agent_of(aid).get("launchd_prefixes", []):
                        if ident.startswith(str(value)):
                            values[aid].add(str(value))
                    routes[aid].add("launchd_prefixes")
    return values, routes


def record(artifact, scenario_dir):
    """Write scenario/observed.json: which identifiers a REAL run actually matched.

    test/artifacts/ is gitignored and per-machine, so the raw output cannot back a
    committed document. This is the compact, reviewable residue of a run -- the
    observations layer of docs/signature-lifecycle.md, at its smallest useful size.
    """
    catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    values, routes = replay([pathlib.Path(artifact)], catalog)
    idents = []
    for agent in catalog["agents"]:
        aid = agent["id"]
        for route in ALL_ROUTES:
            for value in agent.get(route, []):
                value = str(value)
                if route in GLOB_ROUTES or value.endswith("*"):
                    proven = route in routes[aid]
                else:
                    key = classify_mod.image_repo(value) if route == "images" else value
                    proven = key in values[aid]
                if proven:
                    idents.append({"agent": aid, "route": route, "value": value})
    out = pathlib.Path(scenario_dir) / "observed.json"
    # Sorted and undated: this file is committed and compared, so it must change only
    # when what the run OBSERVED changes.
    idents.sort(key=lambda r: (r["agent"], r["route"], r["value"]))
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
    wf = ROOT / ".github" / "workflows" / "scenarios.yml"
    if not wf.exists():
        return set()
    doc = yaml.safe_load(wf.read_text())
    return set(doc["jobs"]["scenario"]["strategy"]["matrix"]["scenario"])


def collect():
    catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())

    scenarios = collections.defaultdict(set)
    for path in sorted((ROOT / "test" / "scenarios").glob("*/expected.json")):
        block = json.loads(path.read_text()).get("classified", {})
        for aid in block.get("must_find", []):
            scenarios[aid].add(path.parent.name)

    # Fixtures prove the MATCHER. A scenario's own output proves the IDENTIFIER, because
    # those rows came off a machine where the software was really installed. Same replay,
    # two sources, and the stronger one wins per identifier.
    values, routes = replay(sorted((ROOT / "test" / "fixtures").glob("*.json")), catalog)
    # Keyed by scenario, so an identifier proved only outside CI can be told apart from
    # one a pull request would catch.
    seen_in = collections.defaultdict(set)      # (agent, route, value) -> {scenario}
    for path in sorted((ROOT / "test" / "scenarios").glob("*/observed.json")):
        doc = json.loads(path.read_text())
        for rec in doc.get("identifiers", []):
            seen_in[(rec["agent"], rec["route"], rec["value"])].add(doc["scenario"])
    in_ci = ci_scenarios()

    agents = []
    for agent in catalog["agents"]:
        aid = agent["id"]
        idents = []
        for route in ALL_ROUTES:
            for value in agent.get(route, []):
                value = str(value)
                if route in GLOB_ROUTES or value.endswith("*"):
                    proven = route in routes[aid]       # route-level only
                    precision = "route"
                else:
                    key = classify_mod.image_repo(value) if route == "images" else value
                    proven = key in values[aid]
                    precision = "exact"
                scens = sorted(seen_in.get((aid, route, value), ()))
                ci_scens = [s for s in scens if s in in_ci]
                # A fixture IS a CI test: ci.yml runs test/lint.sh, which runs
                # test_matcher.py, on every pull request. It is a weaker CLAIM than a real
                # install and a stronger CADENCE -- those are different axes and the report
                # keeps them apart.
                if ci_scens:
                    state = "ci-install"
                elif proven:
                    state = "ci-fixture"
                elif scens:
                    state = "local-only"
                else:
                    state = "none"
                idents.append({"route": route, "value": value,
                               "fixture": proven, "real": bool(scens),
                               "scenarios": scens, "ci_scenarios": ci_scens,
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
            limits.append({"scenario": name, "kind": "skip", "text": doc["why"]})

    # THE GENERAL LIMITS COME FROM README's "What it cannot see", which is the canonical
    # list and is written for a reader deciding whether to deploy this at all. They were
    # previously repeated inside individual scenarios' known_gaps, which made a property of
    # OSQUERY read as a property of one scenario -- "presence is all this proves" is not a
    # fact about the Claude extension, and stating it there implied the others prove more.
    blind = []
    readme = (ROOT / "README.md").read_text()
    if "## What it cannot see" in readme:
        section = readme.split("## What it cannot see", 1)[1].split("\n## ", 1)[0]
        for line in section.splitlines():
            line = line.strip()
            if not line.startswith("|") or line.startswith("|---") or "Blind spot" in line:
                continue
            cells = [c.strip() for c in line.strip("|").split("|")]
            if len(cells) == 2 and cells[0]:
                blind.append({"spot": cells[0], "why": cells[1]})

    return {"blind_spots": blind,
            "classifications": catalog["classifications"],
            "not_agents": list(catalog.get("not_agents", ())),
            "agents": agents, "limits": limits}


STATE_LABEL = {
    "ci-install": "CI: real install",
    "ci-fixture": "CI: fixture",
    "local-only": "LOCAL ONLY",
    "none": "NO TEST",
}
ROUTE_LABEL = {"bundle_ids": "bundle id", "homebrew": "homebrew", "npm": "npm",
               "pypi": "PyPI", "binaries": "binary", "state_dirs": "state dir",
               "launchd_prefixes": "launchd", "ports": "port", "model_stores": "model store",
               "native_messaging_hosts": "native msg", "images": "image",
               "extension_ids": "extension id"}
DOC = ROOT / "docs" / "agents.md"


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
        "# What we scan for, and what proves it",
        "",
        "Every AI agent this repo detects on macOS, the identifiers each is matched on, and the",
        "strength of the evidence behind them.",
        "",
        # One line, not two. The policy and the current state were being stated separately
        # and adjacently, which read as emphasis rather than as information.
        ("**A real install is the standard, and every entry meets it.** A VM scenario installs "
         "the real software and asserts the classifier finds it. Anything less would be an "
         "exception recorded in the catalog with a reason, an evidence grade and a date; there "
         "are none open."
         if not (len(agents) - n_scen) else
         "**A real install is the standard. Everything else is an exception, and every "
         "exception is recorded.**"),
        "",
        (f"| | entries | |\n|---|---:|---|\n"
         f"| **standard** | {n_scen} | a VM scenario installs the real software and asserts "
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
        "## What counts as an agent",
        "",
        "**Something that acts on the user's behalf.** That is the whole test. It is not *is this",
        "AI software* and not *can we detect it* &mdash; everything below passed both and was",
        "removed anyway, because counting it as an agent overstates what was found on a machine.",
        "",
        "| removed | what it actually is |",
        "|---|---|",
        "| `mcp-sdk` | a library an agent is **built with** |",
        "| `litellm` | a gateway an agent **calls through** |",
        "| `docker` | a runtime: **how we look**, not what we look for |",
        "| `ollama`, `lm-studio`, `jan`, `llama-cpp` | model runners. They **serve** models; an "
        "agent drives one |",
        "",
        "Each keeps its fixture rows, with the assertion inverted to *must not match*. Deleting",
        "the evidence with the signature would leave nothing to tell *correctly not an agent*",
        "from *route quietly broken*.",
        "",
        "One boundary is contested rather than settled. **Desktop assistant** is counted as an",
        "agent: the old definition read *no autonomous execution*, which stopped being true when",
        "these clients gained MCP and began running tools locally. Overstating an agent is the",
        "safer error for an inventory than missing one, but it is a judgement, not a fact.",
        "",
        "## Why a real install is the bar",
        "",
        "`bot.molt.mac` was read off OpenClaw's own Homebrew metadata and matched nothing on any",
        "Mac. `aider` installs as `aider-chat` under `uv` and `pipx` while its state directory is",
        "`~/.aider`, so evidence and signature never met. Both were silent, both survived review,",
        "and neither survived contact with an actual install. Nothing short of installing the",
        "software catches that class of error.",
        "",
        f"## {n_ci}/{n_ident} identifiers are covered by a CI test",
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
        f"| **no test** | {n_st('none')} | nothing exercises it |",
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
                MARK = {"ci-install": "**`%s`**", "ci-fixture": "`%s`",
                        "local-only": "_`%s`_", "none": "%s"}
                ids = ", ".join(MARK[i["state"]] % i["value"]
                                for i in a["identifiers"]) or "--"
                mark = "real install" if grade(a) == "standard" else "**exception**"
                out.append(f"| **{a['name']}** | {mark} | {ids} | "
                           f"{', '.join(a['scenarios']) or '--'} |")
            out.append("")

    out += ["> **`bold`** = CI installs it for real. `code` = CI fixture only. _`italic`_ = "
            "proved locally, not in CI. plain = no test.", ""]

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
            for i in a["identifiers"] if i["state"] in ("none", "local-only")]
    if unex:
        out += ["## Identifiers no CI test covers", "",
                "Each is a candidate for a fixture row or a scenario. A `local only` row is the "
                "more misleading of the two: something proved it once, on someone's machine.", "",
                "| agent | route | identifier | state |", "|---|---|---|---|"]
        out += [f"| {a['name']} | {ROUTE_LABEL.get(i['route'], i['route'])} | `{i['value']}` | "
                f"{'local only' if i['state'] == 'local-only' else 'no test'} |"
                for a, i in unex]
        out.append("")

    if data.get("blind_spots"):
        out += ["## What osquery cannot see", "",
                "These are properties of the platform and the tables, not of any one scenario, so",
                "they are stated once. No amount of test coverage moves them.", "",
                "| blind spot | why |", "|---|---|"]
        out += [f"| {b['spot']} | {b['why']} |" for b in data["blind_spots"]]
        out.append("")

    if data["limits"]:
        out += ["## What individual scenarios do not cover", "",
                "Specific to one scenario and fixable by work, unlike the table above. A coverage",
                "report that lists only its successes fails the same way an empty scan result does",
                "-- it reads as complete when it is merely silent.", ""]
        for lim in data["limits"]:
            head = "cannot run here" if lim["kind"] == "skip" else "known gap"
            out += [f"**{lim['scenario']} -- {head}**", "", lim["text"], ""]

    return "\n".join(x for x in out if x is not None).rstrip() + "\n"


def main():
    data = collect()
    if "--record" in sys.argv:
        i = sys.argv.index("--record")
        record(sys.argv[i + 1], sys.argv[i + 2])
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
        print(f"wrote {DOC.relative_to(ROOT)}")
        return
    if "--check" in sys.argv:
        want = markdown(data)
        have = DOC.read_text() if DOC.exists() else ""
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
    print(f"\nIDENTIFIERS COVERED BY A CI TEST   {covered}/{n_ident}"
          f"   ({100 * covered // n_ident}%)")
    print(f"  CI: real install {n('ci-install'):>3}  a scenario in the scenarios.yml matrix "
          f"installs the\n{'':>21}  software and asserts the classifier finds it")
    print(f"  CI: fixture      {n('ci-fixture'):>3}  matched a captured row by test_matcher, "
          f"which ci.yml runs\n{'':>21}  on every pull request. Proves the matcher, not "
          f"that the\n{'':>21}  identifier is current")
    print(f"  LOCAL ONLY       {n('local-only'):>3}  proved only by a scenario CI does not "
          f"run. Catches nothing\n{'':>21}  on a pull request")
    print(f"  NO TEST          {n('none'):>3}  nothing exercises it")


if __name__ == "__main__":
    main()
