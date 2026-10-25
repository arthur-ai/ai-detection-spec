#!/usr/bin/env python3
"""bin/classify against the format's conformance vectors, and the format's files against
each other.

What is held here, and why each one:
  * every vector's catalog and rows validate against the schemas, and an `error` vector's
    catalog does not -- so the schemas are exercised, not only published;
  * bin/classify gives each vector's expected result, and stops on an `error` vector;
  * every match mode the schema declares has a vector with a row that must match and one
    that must not -- a mode with only positive cases passes a matcher that matches anything;
  * every vector's section is a heading in SPEC.md, so a citation cannot point at nothing;
  * bin/classify's MATCH_MODES equals the schema's list: the set is written in both, and two
    copies that are not checked are the `ext` bug;
  * the evidence fixtures validate against the evidence schema, so the rows this repository
    produces are rows the format describes;
  * SPEC.md, schema/ and conformance/ name no implementation path. The format may not come
    to depend on this repository's code.

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

os.environ.setdefault("AI_DISCOVERY_TELEMETRY", "0")
failures = []


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
        if v["expect"].get("error"):
            check(f"{v['id']}: its catalog is refused by the schema", bool(errors))
        else:
            check(f"{v['id']}: its catalog validates", not errors, "; ".join(errors[:2]))
        rows_errors = [e.message for e in evidence_v.iter_errors(v["rows"])]
        check(f"{v['id']}: its rows validate", not rows_errors, "; ".join(rows_errors[:2]))

    print("\nbin/classify, against the vectors")
    for v in vectors:
        if v["expect"].get("error"):
            try:
                conformance.result(classify, v)
                check(f"{v['id']}: stops with an error", False, "it returned a result")
            except Exception as exc:
                check(f"{v['id']}: stops with an error ({type(exc).__name__})", True)
            continue
        problems = conformance.compare(conformance.result(classify, v), v["expect"])
        check(f"{v['id']} ({v['section']}): {v['description']}", not problems,
              "; ".join(problems))

    print("\nwhat the vectors cover")
    modes = set(catalog_schema["$defs"]["match_mode"]["enum"])
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

    print("\nthe format names no implementation path")
    bad = re.compile(r"(?<![\w./-])(catalog|bin|tools|test|osquery)/")
    for path in [ROOT / "SPEC.md", *sorted((ROOT / "schema").glob("*")),
                 *sorted((ROOT / "conformance").glob("*"))]:
        hits = sorted({m.group(0) for m in bad.finditer(path.read_text())})
        check(f"{path.relative_to(ROOT)} names none", not hits, str(hits))

    print(f"\nconformance: {'PASS' if not failures else f'FAIL ({len(failures)})'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
