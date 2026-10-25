#!/usr/bin/env python3
"""tools/export.py: the catalog as an Open Agent Detection Format document.

What is held here:
  * each package-url builder against purl-spec's own rules and examples, and a type with no
    builder is an error rather than a missing member;
  * the real export is strict -- every current identifier proved by a run -- validates
    against schema/catalog.schema.json, and is the same bytes twice;
  * a superseded identifier carries its record and its archived proof, a current one with
    no proof is what --strict refuses, and an observation without a run id proves nothing;
  * every identifier bin/classify finds on the fixtures is an identifier the export
    publishes, so a consumer of the document can name what the matcher matched.

Schema validation needs jsonschema. Without it that part SKIPs loudly; CI passes
--require-jsonschema.
"""
import datetime
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
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
    run = [sys.executable, str(ROOT / "tools" / "export.py"), "--strict", "--commit", "test"]
    first = subprocess.run(run, capture_output=True, text=True)
    check("--strict passes: every current identifier has a proof with a run id",
          first.returncode == 0, first.stderr.strip()[-300:])
    second = subprocess.run(run, capture_output=True, text=True)
    check("two runs produce the same bytes", first.stdout == second.stdout)
    doc = json.loads(first.stdout or "{}")
    catalog = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    n_yaml = sum(len(a.get(r, []) or []) for a in catalog["agents"]
                 for r in yaml.safe_load((ROOT / "catalog" / "routes.yaml").read_text())["routes"])
    n_doc = sum(len(a["identifiers"]) for a in doc.get("agents", []))
    check("it publishes every identifier the catalog carries", n_doc == n_yaml,
          f"{n_doc} published, {n_yaml} in the catalog")
    try:
        import jsonschema
    except ImportError:
        jsonschema = None
        if "--require-jsonschema" in sys.argv:
            sys.exit("FAIL: --require-jsonschema and jsonschema is not installed")
        print("  SKIP  schema validation: jsonschema is not installed")
    if jsonschema:
        schema = json.loads((ROOT / "schema" / "catalog.schema.json").read_text())
        errors = [f"{e.json_path}: {e.message}"
                  for e in jsonschema.Draft202012Validator(schema).iter_errors(doc)]
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

    print("\nwhat the matcher matches, the document names")
    loader = importlib.machinery.SourceFileLoader("classify", str(ROOT / "bin" / "classify"))
    spec = importlib.util.spec_from_loader("classify", loader)
    classify = importlib.util.module_from_spec(spec)
    loader.exec_module(classify)
    published = {(a["id"], i["route"], i["value"]) for a in doc.get("agents", [])
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
