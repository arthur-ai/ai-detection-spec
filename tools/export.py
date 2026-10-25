#!/usr/bin/env python3
"""Write the catalog as an Open Agent Detection Format document (SPEC.md section 4).

    tools/export.py [--strict] [--commit SHA] [--out PATH]

catalog/agents.yaml and catalog/routes.yaml are this repository's authoring form. A tool
elsewhere reads this document instead: every route with its bindings, every agent, and every
identifier with its status, its package URL where one exists, and the observations that proved
it -- the part no other catalog of agents carries.

BUILT AT RELEASE, NEVER COMMITTED. The proof changes every time a scenario run records, and a
committed copy would go stale on the next collect commit with nothing to regenerate it.
release.yml runs this with --strict and attaches the result. A pull request cannot pass
--strict when it adds a value, because the run that proves it happens on main;
test/test_export.py holds the unproved values to the ones tools/agent_status.py calls pending.

--strict fails when a current identifier has no proof with a run id. SPEC.md 7.2 requires one
in a catalog distributed for others to use, and an observation without a run id cannot be
traced to an execution, so it is left out of the proof rather than published as one.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import agent_status  # noqa: E402
from validate_catalog import BINDINGS  # noqa: E402

# THE BINDING A PROOF NAMES. observed.json records no binding, because every harness that
# writes it runs osquery. That holds only while osquery is the one binding, so document()
# refuses a second until observations record theirs, rather than label its proof osquery.
BINDING = "osquery"


def format_version():
    """`ai-detection-spec/<major>.<minor>`, from the version SPEC.md states."""
    m = re.search(r"^Version (\d+)\.(\d+)\.\d+\b", (ROOT / "SPEC.md").read_text(), re.M)
    if not m:
        sys.exit("export: SPEC.md states no `Version X.Y.Z` line")
    return f"ai-detection-spec/{m.group(1)}.{m.group(2)}"


# --- package URLs, one builder per purl-spec type -------------------------------------------
def _npm(value):
    # The scope's `@` is always percent-encoded; npm names are case-sensitive.
    scope, _, name = value.rpartition("/")
    q = urllib.parse.quote
    return f"pkg:npm/{q(scope, safe='')}/{q(name, safe='')}" if scope else f"pkg:npm/{q(name, safe='')}"


def _pypi(value):
    # Case-insensitive, and `_` is `-`.
    return "pkg:pypi/" + urllib.parse.quote(value.lower().replace("_", "-"), safe="")


def _chrome(value):
    # No namespace; the id is the name, case-insensitive.
    return "pkg:chrome-extension/" + value.lower()


def _vscode(value):
    # The marketplace id is `publisher.name`; both case-insensitive.
    publisher, _, name = value.partition(".")
    if not publisher or not name:
        raise ValueError(f"{value!r} is not publisher.name")
    return f"pkg:vscode-extension/{publisher.lower()}/{name.lower()}"


PURL = {"npm": _npm, "pypi": _pypi, "chrome-extension": _chrome, "vscode-extension": _vscode}


def purl(ptype, value):
    if ptype not in PURL:
        raise KeyError(f"no package-url builder for type {ptype!r}")
    return PURL[ptype](value)


# --- the document -----------------------------------------------------------------------------
def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _proof(rec):
    out = {"binding": BINDING, "scenario": rec["scenario"], "platform": rec["platform"],
           "run": str(rec["run"])}
    for key in ("os", "arch", "agent_version"):
        if rec.get(key):
            out[key] = str(rec[key])
    return out


def _proofs(recs):
    seen, out = set(), []
    for rec in recs:
        if not rec.get("run") or not rec.get("platform"):
            continue
        p = _proof(rec)
        key = json.dumps(p, sort_keys=True)
        if key not in seen:
            seen.add(key)
            out.append(p)
    return sorted(out, key=lambda p: (p["scenario"], p["platform"], p.get("os", ""),
                                      p.get("arch", ""), p["run"]))


def document(catalog, routes, live, archived, commit=None, shas=None):
    """The format's catalog document. Pure: everything it reads is an argument."""
    # `not_agents` names classifications whose entries are NOT agents. The format has no
    # place for them (SPEC.md 3), and publishing them under `agents` is the overstatement
    # this catalog exists to avoid. Refused rather than filtered: the scope is a decision.
    if catalog.get("not_agents"):
        raise ValueError(f"export: not_agents {sorted(catalog['not_agents'])} has no place in "
                         f"the format; its entries would be published as agents")
    if set(BINDINGS) != {BINDING}:
        raise ValueError(f"export: bindings {sorted(BINDINGS)}, and observed.json does not "
                         f"say which produced a record. Record it before publishing proof")
    out_routes = {}
    for name, r in routes["routes"].items():
        route = {k: r[k] for k in ("kind", "match", "platform")}
        for key in ("values_from", "live", "retired", "value_pattern", "purl"):
            if key in r:
                route[key] = r[key]
        route["bindings"] = {b: dict(r[b]) for b in sorted(BINDINGS) if b in r}
        out_routes[name] = route

    agents = []
    for a in catalog["agents"]:
        superseded = {(str(s["route"]), str(s["value"])): s for s in a.get("superseded", []) or []}
        identifiers = []
        for name, r in routes["routes"].items():
            for value in a.get(name, []) or []:
                value = str(value)
                key = (a["id"], name, value)
                ident = {"route": name, "value": value}
                rec = superseded.get((name, value))
                ident["status"] = "superseded" if rec else "current"
                if "purl" in r:
                    ident["purl"] = purl(r["purl"], value)
                proof = _proofs(archived.get(key, []) if rec else live.get(key, []))
                if proof:
                    ident["proof"] = proof
                if rec:
                    ident["superseded"] = {"last_version": str(rec["last_version"]),
                                           "last_proved": str(rec["last_proved"]),
                                           "by": str(rec["by"]), "run": str(rec["run"])}
                identifiers.append(ident)
        agents.append({"id": a["id"], "name": a["name"], "classification": a["classification"],
                       "platforms": list(a["platforms"]), "identifiers": identifiers})

    doc = {"format": format_version(),
           "platforms": list(routes["platforms"]),
           "platform_groups": {k: list(v) for k, v in routes.get("platform_groups", {}).items()},
           "classifications": [dict(c) for c in catalog["classifications"]],
           "routes": out_routes,
           "agents": agents}
    if catalog.get("removed"):
        doc["removed"] = [{"id": r["id"], "what_it_is": r["what_it_is"]} for r in catalog["removed"]]
    source = dict(shas or {})
    if commit:
        source["commit"] = commit
    if source:
        doc["source"] = source
    return doc


def unproved(doc):
    """Current identifiers with no proof: what --strict refuses."""
    return [f"{a['id']}: {i['route']} {i['value']!r}" for a in doc["agents"]
            for i in a["identifiers"] if i["status"] == "current" and not i.get("proof")]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--strict", action="store_true",
                    help="fail when a current identifier has no proof")
    ap.add_argument("--commit", help="the commit the document was built from")
    ap.add_argument("--out", help="write here instead of stdout")
    args = ap.parse_args()

    catalog_path, routes_path = ROOT / "catalog" / "agents.yaml", ROOT / "catalog" / "routes.yaml"
    catalog = yaml.safe_load(catalog_path.read_text())
    routes = yaml.safe_load(routes_path.read_text())
    live, archived = agent_status.observations()
    doc = document(catalog, routes, live, archived, args.commit,
                   {"catalog_sha256": _sha(catalog_path), "routes_sha256": _sha(routes_path)})
    if args.strict:
        missing = unproved(doc)
        if missing:
            sys.exit("export: --strict, and these current identifiers have no proof with a run "
                     "id:\n  " + "\n  ".join(missing))
    text = json.dumps(doc, indent=2) + "\n"
    if args.out:
        pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.out).write_text(text)
        n = sum(len(a["identifiers"]) for a in doc["agents"])
        print(f"export: wrote {args.out} ({len(doc['agents'])} agents, {n} identifiers)",
              file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
