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


def collect():
    catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())

    scenarios = collections.defaultdict(set)
    for path in sorted((ROOT / "test" / "scenarios").glob("*/expected.json")):
        block = json.loads(path.read_text()).get("classified", {})
        for aid in block.get("must_find", []):
            scenarios[aid].add(path.parent.name)

    # Replay the fixtures through the real classifier and record what each finding was
    # matched ON, not merely that it was found.
    values = collections.defaultdict(set)   # agent id -> identifier values proven
    routes = collections.defaultdict(set)   # agent id -> route groups proven
    for path in sorted((ROOT / "test" / "fixtures").glob("*.json")):
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
                    routes[aid].update(GLOB_ROUTES & {"state_dirs", "binaries", "model_stores"})
                elif kind == "daemon":
                    routes[aid].add("launchd_prefixes")

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
                idents.append({"route": route, "value": value,
                               "fixture": proven, "precision": precision})
        agents.append({
            "id": aid, "name": agent["name"], "classification": agent["classification"],
            "scenarios": sorted(scenarios.get(aid, ())),
            "identifiers": idents,
            "notes": [c.strip("# ").strip() for c in ()],
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

    return {"classifications": catalog["classifications"], "agents": agents,
            "limits": limits}


ROUTE_LABEL = {"bundle_ids": "bundle id", "homebrew": "homebrew", "npm": "npm",
               "pypi": "PyPI", "binaries": "binary", "state_dirs": "state dir",
               "launchd_prefixes": "launchd", "ports": "port", "model_stores": "model store",
               "native_messaging_hosts": "native msg", "images": "image",
               "extension_ids": "extension id"}
DOC = ROOT / "docs" / "agents.md"


def grade(agent):
    if agent["scenarios"]:
        return "real install"
    return "fixture only" if any(i["fixture"] for i in agent["identifiers"]) else "unexercised"


def markdown(data):
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
        f"**{len(agents)} agents, {n_ident} identifiers.** {n_scen} agents are backed by a "
        f"real install; {n_fix} identifiers are matched by a fixture and "
        f"{n_ident - n_fix} are unexercised.",
        "",
        "## What the grades mean",
        "",
        "| grade | what it proves |",
        "|---|---|",
        "| **real install** | a VM scenario installed the actual software and the classifier "
        "found it. The only evidence that survives a vendor-documented identifier matching "
        "nothing on any Mac. |",
        "| **fixture only** | the classifier matched a captured row. Those rows came from real "
        "machines, but nothing re-checks them against a current install, so a fixture proves the "
        "*matcher* works and cannot prove the *identifier* is current. |",
        "| **unexercised** | catalogued, but no test exercises it yet. Not a defect and not a "
        "wrong signature -- unexercised, which is a different thing, and is why each one is "
        "named below rather than left out. |",
        "",
        "The two grades are also scoped differently: **per-agent** coverage comes from scenarios,",
        "**per-identifier** coverage from fixtures only. A scenario's `expected.json` names the",
        "*agent* it expects, never the identifier that found it -- so an agent can be backed by a",
        "real install while its identifiers still show no fixture row.",
        "",
    ]

    by_class = {}
    for a in agents:
        by_class.setdefault(a["classification"], []).append(a)

    for cls in data["classifications"]:
        if cls not in by_class:
            continue
        out += [f"## {cls}", "",
                "| agent | evidence | identifiers | scenarios |", "|---|---|---|---|"]
        for a in sorted(by_class[cls], key=lambda x: x["id"]):
            ids = ", ".join(f"`{i['value']}`" if i["fixture"] else f"{i['value']}"
                            for i in a["identifiers"]) or "--"
            out.append(f"| **{a['name']}** | {grade(a)} | {ids} | "
                       f"{', '.join(a['scenarios']) or '--'} |")
        out.append("")

    out += ["> Identifiers in `code` are matched by a test fixture; the rest are unexercised.", ""]

    unex = [(a, i) for a in sorted(agents, key=lambda x: x["id"])
            for i in a["identifiers"] if not i["fixture"]]
    if unex:
        out += ["## Unexercised identifiers", "",
                "No test matches these. Each is a candidate for a fixture row or a scenario.", "",
                "| agent | route | identifier |", "|---|---|---|"]
        out += [f"| {a['name']} | {ROUTE_LABEL.get(i['route'], i['route'])} | `{i['value']}` |"
                for a, i in unex]
        out.append("")

    if data["limits"]:
        out += ["## What the suite cannot prove", "",
                "Carried alongside what it can. A coverage report that lists only its successes",
                "fails the same way an empty scan result does -- it reads as complete when it is",
                "merely silent.", ""]
        for lim in data["limits"]:
            head = "cannot run here" if lim["kind"] == "skip" else "known gap"
            out += [f"**{lim['scenario']} -- {head}**", "", lim["text"], ""]

    return "\n".join(out).rstrip() + "\n"


def main():
    data = collect()
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

    by_class = collections.defaultdict(list)
    for a in agents:
        by_class[a["classification"]].append(a)

    for cls in data["classifications"]:
        if cls not in by_class:
            continue
        print(f"\n{cls}")
        for a in sorted(by_class[cls], key=lambda x: x["id"]):
            mark = "scenario" if a["scenarios"] else (
                "fixture" if any(i["fixture"] for i in a["identifiers"]) else "unexercised")
            print(f"  {a['name']:<22} {mark:<12} {len(a['identifiers'])} identifiers"
                  + (f"  [{', '.join(a['scenarios'])}]" if a["scenarios"] else ""))
            for i in a["identifiers"]:
                if not i["fixture"]:
                    print(f"      no fixture row  {i['route']}: {i['value']}")

    print(f"\n{len(agents)} agents, {n_ident} identifiers. "
          f"{n_scen} agents asserted by a VM scenario; "
          f"{n_fix} identifiers matched by a fixture, {n_ident - n_fix} with no fixture row.")
    # Said plainly because the two columns answer different questions and are easy to
    # conflate: a scenario names the AGENT it expects, never the identifier that found it,
    # so an agent can be scenario-backed while its individual identifiers show no fixture.
    print("Per-agent coverage comes from VM scenarios; per-identifier coverage comes from "
          "fixtures only.\nA scenario's expected.json names the agent, not the identifier "
          "that matched it.")


if __name__ == "__main__":
    main()
