"""The conformance vectors, read once and put in the terms each matcher takes.

A vector carries a catalog in the format's own shape (SPEC.md section 4), evidence rows
(section 5) and the result a conforming matcher must give (section 9). bin/classify reads this
repository's authoring form instead -- catalog/agents.yaml and catalog/routes.yaml -- so
authoring_form() converts. result() and compare() state a matcher's answer in the vector's
terms, so bin/classify and the rendered SQL are held to one expectation rather than two.
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
VECTORS = ROOT / "conformance" / "vectors.json"


def load():
    return json.loads(VECTORS.read_text())["vectors"]


def authoring_form(doc, catalog_version):
    """A format catalog as the two documents bin/classify reads."""
    routes = {"platforms": list(doc["platforms"]),
              "platform_groups": dict(doc["platform_groups"]),
              "routes": {name: {k: v for k, v in r.items() if k != "bindings"}
                         for name, r in doc["routes"].items()}}
    agents = []
    for a in doc["agents"]:
        entry = {k: a[k] for k in ("id", "name", "classification", "platforms")}
        superseded = []
        for ident in a["identifiers"]:
            entry.setdefault(ident["route"], []).append(ident["value"])
            if ident["status"] == "superseded":
                superseded.append({"route": ident["route"], "value": ident["value"],
                                   **ident["superseded"]})
        if superseded:
            entry["superseded"] = superseded
        agents.append(entry)
    catalog = {"version": catalog_version, "classifications": doc["classifications"],
               "agents": agents}
    return catalog, routes


def result(classify, vector):
    """What bin/classify reports for a vector, in the vector's terms."""
    catalog, routes = authoring_form(vector["catalog"], classify.CATALOG_VERSION)
    rows = vector["rows"]
    findings, unmatched, gaps, scans, absences = classify.classify(rows, catalog, routes)
    index = {id(r): i for i, r in enumerate(rows)}
    live = classify.Registry(routes).live_kinds
    matches, out = [None] * len(rows), {}
    for aid, hits in findings.items():
        evidence = [index[id(r)] for _, r in hits]
        for i in evidence:
            matches[i] = aid
        f = {"evidence": evidence}
        if any(r.get("kind") in live for _, r in hits):
            f["running"] = True
        if any(m.get("superseded") for m, _ in hits):
            f["superseded"] = [r.get("id") for m, r in hits if m.get("superseded")]
            f["only_superseded"] = all(m.get("superseded") for m, _ in hits)
        out[aid] = f
    groups = {"ok": sorted(index[id(r)] for r in scans),
              "absent": sorted(index[id(r)] for r in absences),
              "gap": sorted(index[id(r)] for r in gaps)}
    unm = sorted(index[id(r)] for r in unmatched)
    seen = set(unm) | {i for i, a in enumerate(matches) if a} | {
        i for g in groups.values() for i in g}
    return {"matches": matches, "unmatched": unm,
            "dropped": [i for i in range(len(rows)) if i not in seen],
            "scans": groups, "findings": out}


def _finding(f):
    return {"evidence": f["evidence"], "running": f.get("running", False),
            "superseded": f.get("superseded", []),
            "only_superseded": f.get("only_superseded", False)}


def compare(got, expect, keys=("matches", "unmatched", "dropped", "scans", "findings")):
    """Where a matcher's result differs from a vector's expectation, as short strings.
    Only the members the vector states are compared, and only those in `keys`."""
    problems = []
    for key in keys:
        if key not in expect:
            continue
        want, have = expect[key], got.get(key)
        if key == "findings":
            want = {a: _finding(f) for a, f in want.items()}
            have = {a: _finding(f) for a, f in (have or {}).items()}
        if want != have:
            problems.append(f"{key}: got {have}, want {want}")
    return problems
