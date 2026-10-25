"""The conformance vectors, read once and put in the terms each matcher takes.

A vector carries a catalog in the format's own shape (SPEC.md section 4), evidence rows
(section 5) and the result a conforming matcher must give (section 9). bin/classify reads this
repository's authoring form instead -- catalog/agents.yaml and catalog/routes.yaml -- so
authoring_form() converts. result() runs bin/classify itself and states its answer in the
vector's terms, so bin/classify and the rendered SQL are held to one expectation rather than
two.

scan_outcome_ok() is the format's outcome vocabulary, read from the evidence schema. CI's
vocabulary checks and the osquery lint call it, so no copy of how to read the schema exists.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VECTORS = ROOT / "conformance" / "vectors.json"
EVIDENCE_SCHEMA = ROOT / "schema" / "evidence.schema.json"
CLASSIFY = ROOT / "bin" / "classify"
# A member a matcher must ignore (SPEC.md 5.1), carrying each row's index into the output.
ROW = "conformance_row"


def load():
    return json.loads(VECTORS.read_text())["vectors"]


def scan_outcomes():
    """The evidence schema's outcomes: (the fixed words, the patterns)."""
    anyof = json.loads(EVIDENCE_SCHEMA.read_text())["$defs"]["scan_outcome"]["anyOf"]
    return (tuple(w for o in anyof for w in o.get("enum", ())),
            tuple(o["pattern"] for o in anyof if "pattern" in o))


def scan_outcome_ok(value):
    words, patterns = scan_outcomes()
    return value in words or any(re.fullmatch(p, value) for p in patterns)


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
    """What `bin/classify --json` reports for a vector, in the vector's terms, plus `exit`
    and `stderr`. JSON is YAML, so the authoring form is written as JSON."""
    catalog, routes = authoring_form(vector["catalog"], classify.CATALOG_VERSION)
    rows = [{**r, ROW: str(i)} for i, r in enumerate(vector["rows"])]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        for name, doc in (("agents.yaml", catalog), ("routes.yaml", routes), ("rows.json", rows)):
            (tmp / name).write_text(json.dumps(doc))
        proc = subprocess.run(
            [sys.executable, str(CLASSIFY), "--json", "--show-unmatched",
             "--catalog", str(tmp / "agents.yaml"), "--routes", str(tmp / "routes.yaml"),
             str(tmp / "rows.json")],
            capture_output=True, text=True, env={**os.environ, "AI_DISCOVERY_TELEMETRY": "0"})
    got = {"exit": proc.returncode, "stderr": proc.stderr}
    if proc.returncode:
        return got
    out = json.loads(proc.stdout)

    def idx(listed):
        return sorted(int(r[ROW]) for r in listed)

    matches, findings = [None] * len(rows), {}
    for f in out["findings"]:
        evidence = [int(r[ROW]) for r in f["evidence"]]
        for i in evidence:
            matches[i] = f["id"]
        findings[f["id"]] = {"evidence": evidence,
                             **{k: f[k] for k in ("running", "superseded", "only_superseded")
                                if k in f}}
    gap, absent = idx(out.get("gaps", [])), idx(out.get("absences", []))
    # `scans` reports each `ok` marker as {id, at}, not as the row, in input order.
    ok = [i for i, r in enumerate(rows) if r["kind"] == "scan" and i not in gap + absent]
    said = [(s["id"], s["at"]) for s in out.get("scans", [])]
    if said != [(rows[i]["id"], int(rows[i]["ver"])) for i in ok]:
        ok = [f"bin/classify reported scans {said}"]
    unmatched = idx(out.get("unmatched", []))
    seen = set(unmatched) | set(gap) | set(absent) | set(ok) | {
        i for i, a in enumerate(matches) if a}
    dropped = [i for i in range(len(rows)) if i not in seen]
    if len(dropped) != out.get("dropped", 0):
        dropped = [f"bin/classify counted {out.get('dropped', 0)} dropped"]
    got.update(matches=matches, unmatched=unmatched, dropped=dropped,
               scans={"ok": ok, "absent": absent, "gap": gap}, findings=findings)
    return got


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
