#!/usr/bin/env python3
"""bin/classify against the spec's conformance vectors, and the spec's files against
each other.

What is held here, and why each one:
  * every vector's catalog and rows validate against the schemas, and an `error` vector's
    catalog does not -- so the schemas are exercised, not only published -- unless the
    refusal is one only a matcher can make (MATCHER_ONLY);
  * bin/classify, run as a command, gives each vector's expected result, and on an `error`
    vector exits non-zero naming what the vector says it refuses -- a mode, or a version --
    so a crash for any other reason is not counted as a refusal;
  * every match mode the schema declares has a vector with a row that must match and one
    that must not -- a mode with only positive cases passes a matcher that matches anything;
  * every vector's section is a heading in SPEC.md, so a citation cannot point at nothing;
  * bin/classify's MATCH_MODES equals the schema's list: the set is written in both, and two
    copies that are not checked are the `ext` bug;
  * the evidence fixtures validate against the evidence schema, so the rows this repository
    produces are rows the spec describes;
  * SPEC.md, schema/ and conformance/ name no implementation path. The spec may not come
    to depend on this repository's code;
  * the version is the same everywhere it is written: SPEC.md, bin/classify's FORMATS, both
    schemas and every vector but the one refusing another version. Eight copies of one fact
    moved by hand drift, and a matcher refusing its own catalog is the result.

The rendered SQL is held to the same vectors in osquery/test/test_match_sql.py.

jsonschema validates. Without it this SKIPs loudly; CI passes --require-jsonschema.
"""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "test"))
import conformance  # noqa: E402

os.environ.setdefault("AI_DETECTION_SPEC_TELEMETRY", "0")
failures = []
# Refusals the schema cannot express, because route names are the catalog's own (SPEC.md 6).
MATCHER_ONLY = {"6"}


def check(label, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'}  {label}{'' if condition else '  ' + detail}")
    if not condition:
        failures.append(label)


def load_classify():
    loader = importlib.machinery.SourceFileLoader("classify", str(ROOT / "bin" / "classify"))
    spec = importlib.util.spec_from_loader("classify", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def main():
    require = "--require-jsonschema" in sys.argv
    try:
        import jsonschema
    except ImportError:
        if require:
            sys.exit("FAIL: --require-jsonschema and jsonschema is not installed")
        print("SKIP: jsonschema is not installed, so nothing here is validated. "
              "`pip install jsonschema`; CI runs this with --require-jsonschema.")
        return 0

    classify = load_classify()
    vectors = conformance.load()
    catalog_schema = json.loads((ROOT / "schema" / "catalog.schema.json").read_text())
    evidence_schema = json.loads((ROOT / "schema" / "evidence.schema.json").read_text())
    for schema in (catalog_schema, evidence_schema):
        jsonschema.Draft202012Validator.check_schema(schema)
    catalog_v = jsonschema.Draft202012Validator(catalog_schema)
    evidence_v = jsonschema.Draft202012Validator(evidence_schema)

    print("\nthe vectors, against the schemas")
    for v in vectors:
        errors = [e.message for e in catalog_v.iter_errors(v["catalog"])]
        if v["expect"].get("error") and v["section"] in MATCHER_ONLY:
            check(f"{v['id']}: its catalog validates, so the refusal is the matcher's own",
                  not errors, "; ".join(errors[:2]))
        elif v["expect"].get("error"):
            check(f"{v['id']}: its catalog is refused by the schema", bool(errors))
        else:
            check(f"{v['id']}: its catalog validates", not errors, "; ".join(errors[:2]))
        rows_errors = [e.message for e in evidence_v.iter_errors(v["rows"])]
        check(f"{v['id']}: its rows validate", not rows_errors, "; ".join(rows_errors[:2]))

    print("\nbin/classify, against the vectors")
    modes = set(catalog_schema["$defs"]["match_mode"]["enum"])
    for v in vectors:
        got = conformance.result(classify, v)
        if v["expect"].get("error"):
            refused = v["expect"]["error"]
            check(f"{v['id']} ({v['section']}): stops with an error naming {refused!r}",
                  got["exit"] != 0 and refused in got["stderr"],
                  f"exit {got['exit']}: {got['stderr'].strip()[-300:]}")
            continue
        problems = conformance.compare(got, v["expect"]) if got["exit"] == 0 else [
            f"exit {got['exit']}: {got['stderr'].strip()[-300:]}"]
        check(f"{v['id']} ({v['section']}): {v['description']}", not problems,
              "; ".join(problems))

    print("\nwhat the vectors cover")
    for mode in sorted(modes):
        mine = [v for v in vectors if v.get("mode") == mode]
        pos = any(m for v in mine for m in v["expect"]["matches"])
        neg = any(m is None for v in mine for m in v["expect"]["matches"])
        check(f"match mode {mode!r} has a row that must match and one that must not",
              pos and neg, f"{len(mine)} vectors")
    spec = (ROOT / "SPEC.md").read_text()
    for v in vectors:
        check(f"{v['id']}: section {v['section']} is a heading in SPEC.md",
              re.search(rf"^#+ {re.escape(v['section'])}\.? ", spec, re.M) is not None)
    check("bin/classify's MATCH_MODES is the schema's list", set(classify.MATCH_MODES) == modes,
          f"classify {sorted(classify.MATCH_MODES)}, schema {sorted(modes)}")

    print("\nthis repository's rows, against the evidence schema")
    for path in sorted((ROOT / "test" / "fixtures").glob("*.json")):
        errors = [e.message for e in evidence_v.iter_errors(json.loads(path.read_text()))]
        check(f"{path.name} validates", not errors, "; ".join(errors[:2]))

    print("\nthe spec names no implementation path")
    bad = re.compile(r"(?<![\w./-])(catalog|bin|tools|test|osquery)/")
    for path in [ROOT / "SPEC.md", *sorted((ROOT / "schema").glob("*")),
                 *sorted((ROOT / "conformance").glob("*"))]:
        hits = sorted({m.group(0) for m in bad.finditer(path.read_text())})
        check(f"{path.relative_to(ROOT)} names none", not hits, str(hits))

    print("\none version, wherever it is written")
    m = re.search(r"^Version (\d+)\.(\d+)\.(\d+)\b", spec, re.M)
    check("SPEC.md states its version", m is not None)
    if m:
        major, minor, patch = m.groups()
        ver, fmt = f"{major}.{minor}", f"ai-detection-spec/{major}.{minor}"
        check("SPEC.md 4.1 names the same format", f"this version is `{fmt}`" in spec)
        check("SPEC.md 9 names the same version", f"*an ai-detection-spec {ver} matcher*" in spec)
        check("SPEC.md 10 names the same version",
              f"This document is version {major}.{minor}.{patch}." in spec)
        check("bin/classify reads that format and no other", set(classify.FORMATS) == {fmt},
              str(sorted(classify.FORMATS)))
        check("the catalog schema accepts that format",
              catalog_schema["properties"]["format"]["pattern"] == f"^ai-detection-spec/{major}\\.{minor}$",
              catalog_schema["properties"]["format"]["pattern"])
        for name, schema in (("catalog", catalog_schema), ("evidence", evidence_schema)):
            check(f"the {name} schema's $id carries the version",
                  schema["$id"] == f"urn:ai-detection-spec:schema:{name}:{ver}", schema["$id"])
        doc = json.loads((ROOT / "conformance" / "vectors.json").read_text())
        check("the vectors document says that format", doc["format"] == fmt, doc["format"])
        stale = [v["id"] for v in vectors
                 if v["catalog"].get("format") != fmt and not v["expect"].get("error")]
        check("every vector's catalog says that format", not stale, str(stale))

    print(f"\nconformance: {'PASS' if not failures else f'FAIL ({len(failures)})'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
