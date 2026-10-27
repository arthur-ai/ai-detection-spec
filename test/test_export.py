#!/usr/bin/env python3
"""tools/export.py: the catalog as an ai-detection-spec catalog document.

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
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "test"))
import conformance  # noqa: E402
import export  # noqa: E402

os.environ.setdefault("AI_DETECTION_SPEC_TELEMETRY", "0")
failures = []


def check(label, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'}  {label}{'' if condition else '  ' + detail}")
    if not condition:
        failures.append(label)


def raises(fn, *args, expected, message):
    """Does fn(*args) raise `expected` with `message` in it? Any other exception is a crash,
    and it is not counted as the refusal under test."""
    try:
        fn(*args)
    except expected as exc:
        return message in str(exc)
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
          raises(export.purl, "brew", "openclaw", expected=KeyError,
                 message="no package-url builder"))
    check("a VS Code value that is not publisher.name is an error",
          raises(export.purl, "vscode-extension", "noperiod", expected=ValueError,
                 message="is not publisher.name"))

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
             if i.get("purl") != (export.purl(routes_yaml[i["route"]]["purl"], i["value"])
                                  if "purl" in routes_yaml[i["route"]] else None)]
    check("an identifier carries a purl exactly when its route declares one: the builder's",
          not wrong, str(wrong[:3]))
    # A chrome-extension purl is a Chrome Web Store coordinate. A store that re-signs, such
    # as Edge Add-ons, issues another id for the same extension, so each value must come from
    # a scenario that downloads from the Web Store's update endpoint AND from nowhere else: a
    # script that also fetches a CRX from another host could be where any of its ids came
    # from. Not per command, because a setup builds its URL from an id in a loop.
    def web_store_only(text):
        hosts = set(re.findall(r"https?://([^/\s\"'$]+)/[^\s\"']*crx", text))
        return hosts == {"clients2.google.com"} and "/service/update2/crx" in text

    # setup.sh, or setup.ps1 on Windows: a scenario's script in either language.
    setups = [s for s in (p.read_text() for p in
                          sorted((ROOT / "test" / "scenarios").glob("*/setup.*")))
              if web_store_only(s)]
    not_cws = [i["value"] for a in doc["agents"] for i in a["identifiers"]
               if routes_yaml[i["route"]].get("purl") == "chrome-extension"
               and not any(i["value"] in s for s in setups)]
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
    _bindings = export.BINDINGS
    export.BINDINGS = {**_bindings, "other": {"table"}}
    try:
        check("a second binding stops the export until observations name theirs",
              raises(export.document, cat, routes, live, archived, expected=ValueError,
                     message="does not say which produced a record"))
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

    # THE DOCUMENT IS A CATALOG THE MATCHER READS, and reads to the same answer. bin/classify
    # once read catalog.json as an authoring form with no route keys and reported a clean
    # machine; every fixture finding nothing would pass the check above.
    try:
        import jsonschema  # noqa: F401
        schema = classify.CATALOG_SCHEMA
    except ImportError:
        schema = None                       # said once, under "the document" above
    doc_catalog, doc_routes = classify.from_document(doc, schema=schema)
    # A `format` of any JSON type is refused as a format, before anything hashes it or the
    # schema runs. A list once raised TypeError: a consumer that turns a refusal into "fix the
    # catalog" reported it as a crash.
    for fmt in ([], {}, [doc["format"]], 2, None):
        check(f"classify refuses a catalog whose format is {fmt!r}",
              raises(classify.from_document, {**doc, "format": fmt}, expected=SystemExit,
                     message=f"is format {fmt!r}"))
    if schema is not None:
        # A status the schema does not allow would otherwise read as current (SPEC.md 4).
        bad = json.loads(json.dumps(doc))
        bad["agents"][0]["identifiers"][0]["status"] = "probably"
        check("classify refuses a document the schema rejects, rather than reading it in part",
              raises(classify.from_document, bad, expected=SystemExit,
                     message="does not validate"))
        # A catalog document needs jsonschema and not PyYAML, as bin/classify's header says.
        tmp = pathlib.Path(tempfile.mkdtemp())
        (tmp / "catalog.json").write_text(json.dumps(doc))
        proc = subprocess.run(
            [sys.executable, "-c", "import runpy, sys; sys.modules['yaml'] = None; "
             "sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')",
             str(ROOT / "bin" / "classify"), "--json", "--catalog", str(tmp / "catalog.json"),
             str(ROOT / "test" / "fixtures" / "known-agents.json")],
            capture_output=True, text=True, env={**os.environ, "AI_DETECTION_SPEC_TELEMETRY": "0"})
        check("classify reads catalog.json where PyYAML is not installed",
              proc.returncode == 0 and json.loads(proc.stdout or "{}").get("findings"),
              proc.stderr.strip()[-200:])

    def index(catalog, routes):
        exact, prefix, glob = classify.build_index(catalog, classify.Registry(routes))
        return sorted([repr((k, sorted(m.items()))) for k, m in exact.items()]
                      + [repr((v, r, sorted(m.items()))) for v, r, m in prefix]
                      + [repr((p.pattern, r, sorted(m.items()))) for p, r, m in glob])
    # The whole index, because the fixtures reach only some identifiers. Superseded ones are
    # conformance/vectors.json's to cover: this catalog has none today.
    check("classify indexes the same identifiers from both forms",
          index(doc_catalog, doc_routes) == index(real_catalog, real_routes))
    for path in sorted((ROOT / "test" / "fixtures").glob("*.json")):
        rows = json.loads(path.read_text())
        want = classify.classify(rows, real_catalog, real_routes)[0]
        got = classify.classify(rows, doc_catalog, doc_routes)[0]
        check(f"{path.name}: classify finds the same agents from the document as from the YAML",
              {a: [r for _, r in h] for a, h in got.items()}
              == {a: [r for _, r in h] for a, h in want.items()},
              f"document {sorted(got)}, YAML {sorted(want)}")

    print(f"\nexport: {'PASS' if not failures else f'FAIL ({len(failures)})'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
