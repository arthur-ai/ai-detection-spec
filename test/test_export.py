#!/usr/bin/env python3
"""tools/export.py: the catalog as an Open Agent Detection Format document.

What is held here:
  * each package-url builder against purl-spec's own rules and examples, and a type with no
    builder is an error rather than a missing member;
  * the real export validates against schema/catalog.schema.json, is the same bytes twice,
    publishes every binding a route declares, and gives an identifier a purl exactly when
    its route declares one;
  * every current identifier the export cannot prove is one tools/agent_status.py calls
    pending. Not --strict: a pull request that adds a value has no run to prove it until
    collect runs on main, and a gate red on every correct signature PR is the trap
    _pending() exists to avoid. release.yml runs --strict;
  * a superseded identifier carries its record and its archived proof, a current one with
    no proof is what --strict refuses, and an observation without a run id proves nothing;
  * every identifier bin/classify finds on the fixtures is an identifier the export
    publishes, so a consumer of the document can name what the matcher matched.

Schema validation needs jsonschema. Without it that part SKIPs loudly; CI passes
--require-jsonschema.
"""
import datetime
import json
import os
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "test"))
import conformance  # noqa: E402
import export  # noqa: E402

os.environ.setdefault("AI_DISCOVERY_TELEMETRY", "0")
failures = []


def check(label, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'}  {label}{'' if condition else '  ' + detail}")
    if not condition:
        failures.append(label)


def raises(fn, *args):
    try:
        fn(*args)
    except Exception:
        return True
    return False


def main():
    print("\npackage URLs, against purl-spec's rules")
    for ptype, value, want in (
            ("npm", "@angular/animation", "pkg:npm/%40angular/animation"),
            ("npm", "foobar", "pkg:npm/foobar"),
            ("npm", "@openai/codex", "pkg:npm/%40openai/codex"),
            ("pypi", "Django", "pkg:pypi/django"),
            ("pypi", "django_allauth", "pkg:pypi/django-allauth"),
            ("chrome-extension", "hlepfoohegkhhmjieoechaddaejaokhf",
             "pkg:chrome-extension/hlepfoohegkhhmjieoechaddaejaokhf"),
            ("vscode-extension", "ms-python.python", "pkg:vscode-extension/ms-python/python"),
            ("vscode-extension", "Golang.Go", "pkg:vscode-extension/golang/go")):
        got = export.purl(ptype, value)
        check(f"{ptype} {value!r} -> {want}", got == want, f"got {got}")
    check("a type with no builder is an error, not a missing member",
          raises(export.purl, "brew", "openclaw"))
    check("a VS Code value that is not publisher.name is an error",
          raises(export.purl, "vscode-extension", "noperiod"))

    print("\nthe real export")
    run = [sys.executable, str(ROOT / "tools" / "export.py"), "--commit", "test"]
    first = subprocess.run(run, capture_output=True, text=True)
    if first.returncode:
        # Every check below reads the document; without one they would fail for this reason
        # and report another.
        check("the export runs", False, first.stderr.strip()[-300:])
        return 1
    second = subprocess.run(run, capture_output=True, text=True)
    check("two runs produce the same bytes", first.stdout == second.stdout)
    doc = json.loads(first.stdout)
    catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    routes_yaml = yaml.safe_load((ROOT / "catalog" / "routes.yaml").read_text())["routes"]
    n_yaml = sum(len(a.get(r, []) or []) for a in catalog["agents"] for r in routes_yaml)
    n_doc = sum(len(a["identifiers"]) for a in doc["agents"])
    check("it publishes every identifier the catalog carries", n_doc == n_yaml,
          f"{n_doc} published, {n_yaml} in the catalog")
    unbound = [n for n, r in doc["routes"].items()
               if set(r["bindings"]) != set(routes_yaml[n]) & set(export.BINDINGS)]
    check("each route publishes every binding it declares", not unbound, str(unbound[:3]))
    wrong = [f"{a['id']}: {i['route']} {i['value']!r}" for a in doc["agents"]
             for i in a["identifiers"]
             if i.get("purl", "").partition("/")[0] != (f"pkg:{routes_yaml[i['route']]['purl']}"
                                                        if "purl" in routes_yaml[i["route"]] else "")]
    check("an identifier carries a purl exactly when its route declares one, of that type",
          not wrong, str(wrong[:3]))
    # A chrome-extension purl is a Chrome Web Store coordinate. A store that re-signs, such
    # as Edge Add-ons, issues another id for the same extension, so each value must be one a
    # scenario downloads from the Web Store's own update endpoint.
    setups = [p.read_text() for p in sorted((ROOT / "test" / "scenarios").glob("*/setup.sh"))]
    cws = "clients2.google.com/service/update2/crx"
    not_cws = [i["value"] for a in doc["agents"] for i in a["identifiers"]
               if routes_yaml[i["route"]].get("purl") == "chrome-extension"
               and not any(cws in s and i["value"] in s for s in setups)]
    check("every chrome-extension value is downloaded from the Chrome Web Store by a scenario",
          not not_cws, str(not_cws[:3]))
    pending, _ = export.agent_status._pending(export.agent_status.collect(), ["--pending-ok"])
    unproved = {(a["id"], i["route"], i["value"]) for a in doc["agents"] for i in a["identifiers"]
                if i["status"] == "current" and not i.get("proof")}
    check("every identifier --strict would refuse awaits a CI run, and none is simply unproved",
          unproved <= pending, str(sorted(unproved - pending)[:3]))
    try:
        import jsonschema  # noqa: F401
    except ImportError:
        if "--require-jsonschema" in sys.argv:
            sys.exit("FAIL: --require-jsonschema and jsonschema is not installed")
        print("  SKIP  schema validation: jsonschema is not installed")
    else:
        errors = conformance.schema_errors(doc, "catalog")
        check("it validates against schema/catalog.schema.json", not errors, "; ".join(errors[:2]))

    print("\nstatus and proof")
    cat = {"classifications": [{"name": "Coding agent", "definition": "d"}],
           "agents": [{"id": "a", "name": "A", "classification": "Coding agent",
                       "platforms": ["linux"], "npm": ["new", "old", "bare"],
                       "superseded": [{"route": "npm", "value": "old", "last_version": "1.0",
                                       "last_proved": datetime.date(2026, 1, 1), "by": "s1",
                                       "run": 7}]}]}
    routes = {"platforms": ["darwin", "linux"], "platform_groups": {"posix": ["darwin", "linux"]},
              "routes": {"npm": {"kind": "npm", "match": "exact", "platform": "posix",
                                 "purl": "npm",
                                 "osquery": {"table": "npm_packages", "min_osquery": "5.10.0"}}}}
    obs = {"agent": "a", "route": "npm", "scenario": "s1", "platform": "linux"}
    live = {("a", "npm", "new"): [{**obs, "value": "new", "run": 1, "os": "debian-12"}],
            ("a", "npm", "bare"): [{**obs, "value": "bare"}]}
    archived = {("a", "npm", "old"): [{**obs, "value": "old", "run": 7, "agent_version": "1.0"}]}
    d = export.document(cat, routes, live, archived)
    by = {i["value"]: i for i in d["agents"][0]["identifiers"]}
    check("a current identifier carries its proof",
          by["new"]["status"] == "current" and by["new"].get("proof", [{}])[0].get("run") == "1")
    check("a superseded identifier carries its record and its archived proof",
          by["old"]["status"] == "superseded"
          and by["old"].get("superseded") == {"last_version": "1.0", "last_proved": "2026-01-01",
                                              "by": "s1", "run": "7"}
          and by["old"].get("proof", [{}])[0].get("run") == "7", json.dumps(by["old"]))
    check("an observation without a run id proves nothing", "proof" not in by["bare"])
    check("...so --strict refuses that identifier, and only it",
          export.unproved(d) == ["a: npm 'bare'"], str(export.unproved(d)))
    check("each identifier on a purl route carries its package URL",
          by["new"].get("purl") == "pkg:npm/new")
    check("a catalog with not_agents is refused, not published as agents",
          raises(export.document, {**cat, "not_agents": ["Coding agent"]}, routes, live, archived))
    _bindings = export.BINDINGS
    export.BINDINGS = {**_bindings, "other": {"table"}}
    try:
        check("a second binding stops the export until observations name theirs",
              raises(export.document, cat, routes, live, archived))
    finally:
        export.BINDINGS = _bindings

    print("\nwhat the matcher matches, the document names")
    classify = export.agent_status.classify_mod
    published = {(a["id"], i["route"], i["value"]) for a in doc["agents"]
                 for i in a["identifiers"]}
    real_catalog = classify.load_catalog(ROOT / "catalog" / "agents.yaml")
    real_routes = classify.load_routes()
    for path in sorted((ROOT / "test" / "fixtures").glob("*.json")):
        findings, *_ = classify.classify(json.loads(path.read_text()), real_catalog, real_routes)
        matched = {(m["id"], m["route"], m["value"]) for hits in findings.values() for m, _ in hits}
        check(f"{path.name}: every identifier classify matched is published",
              matched <= published, str(sorted(matched - published)[:3]))

    print(f"\nexport: {'PASS' if not failures else f'FAIL ({len(failures)})'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
