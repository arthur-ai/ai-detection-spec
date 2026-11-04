#!/usr/bin/env python3
"""The scenario contract: what test/scenarios/<name>/ may say, what each key asserts, and
what the catalog derives. Every tool that reads a scenario reads it through this file.

    python3 tools/scenarios.py --check                     every scenario, against the catalog
    python3 tools/scenarios.py --write                     regenerate each extension-ids.txt
    python3 tools/scenarios.py field <scenario> <key>      one value, for a shell harness
    python3 tools/scenarios.py list <platform>             one platform's scenarios
    python3 tools/scenarios.py want <expected.json>        its platform, then each must_find
    python3 tools/scenarios.py assert-counts <rows.json> <expected.json>
    python3 tools/scenarios.py assert-classified <rows.json> <expected.json>

ONE HOME PER KEY. The harnesses, the assertions and the tools each did `.get(key, default)`,
and the default always meant "nothing to check": 93's forbid_evidence sat at the top level
where nothing looked, and the scenario stayed green. So the vocabulary below is the only one, a value of the wrong shape is
refused rather than read as empty, and the code that asserts each key is in this file too. A
key joins the vocabulary in the change that teaches this file to read it.

A SCENARIO FINDS EXACTLY ITS must_find. Every agent the classifier finds and must_find does
not name fails the run, so `forbid` is no longer the over-matching guard: it names the
agents whose rows this scenario holds lookalikes for, which tools/ci_scope.py reads to rerun
it when one of them changes. A `control` finds nothing and reruns when any agent of its
platform changes; the list of every agent a control must not find was a hand-kept copy of
the catalog, and it fell behind.

DERIVED, NEVER COPIED. `every_extension` puts every agent the catalog matches by extension id
on the scenario's platform into must_find, and `--write` lists their ids in the scenario's
extension-ids.txt, which its setup installs from. `composes` runs sibling scenarios and finds
what each of them finds.
"""
import collections
import functools
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCENARIOS = ROOT / "test" / "scenarios"
EXTENSIONS = "extension-ids.txt"


# --- shapes ---------------------------------------------------------------------------------
# Each returns what the value should have been, or None. A bool is an int to Python, and
# `"counts": {"ext": true}` is not a count.

def _text(v):
    return None if isinstance(v, str) and v.strip() else "a non-empty string"


def _texts(v):
    ok = isinstance(v, list) and v and all(_text(x) is None for x in v)
    return None if ok else "a non-empty list of non-empty strings"


def _names(v):
    ok = _texts(v) is None and len(set(v)) == len(v)
    return None if ok else "a list of distinct names"


def _true(v):
    # One spelling per meaning: absent is false.
    return None if v is True else "true, or left out"


def _floor(v):
    if isinstance(v, int) and not isinstance(v, bool) and v >= 0:
        return None
    if isinstance(v, str) and re.fullmatch(r">=\d+", v):
        return None
    return "an exact count or a '>=N' floor"


def _counts(v):
    if not isinstance(v, dict) or not v:
        return "a non-empty object of kind -> count"
    bad = sorted(k for k, n in v.items() if _floor(n))
    return f"counts whose values are exact or '>=N' (not {', '.join(bad)})" if bad else None


def _probes(v):
    # must_contain: a string, or a list meaning "any of these".
    ok = isinstance(v, list) and v and all(_text(p) is None or _texts(p) is None for p in v)
    return None if ok else "a list of strings, or of lists of strings meaning any of them"


def _require_value(v, columns):
    if isinstance(v, dict):
        return v.keys() == {"tail_of"} and v["tail_of"] in columns
    return _text(v) is None or _texts(v) is None


def _rows(v, columns, value_ok, what):
    if not isinstance(v, list) or not v:
        return "a non-empty list of row specs"
    for spec in v:
        if not isinstance(spec, dict) or not spec:
            return "row specs that each name at least one field"
        unknown = sorted(set(spec) - set(columns))
        if unknown:
            return f"fields from {sorted(columns)}, not {unknown}"
        bad = [k for k, x in spec.items() if not value_ok(x, columns)]
        if bad:
            return f"{what} (not {spec[bad[0]]!r} for {bad[0]})"
    return None


@functools.lru_cache(maxsize=None)
def _columns():
    # The six-column contract, from the schema rather than a copy of it.
    doc = json.loads((ROOT / "schema" / "evidence.schema.json").read_text())
    return tuple(doc["$defs"]["row"]["properties"])


# --- the vocabulary -------------------------------------------------------------------------
# key -> (required, shape). Prose for people: description, why, demo_beat (the step of
# 90-demo-fleet's walkthrough a scenario shows). tools/agent_status.py renders known_gaps
# into docs/limits.md.

def _top(columns):
    return {
        "description": (True, _text),
        "platform": (True, _text),
        "why": (True, _text),
        "counts": (True, _counts),
        "classified": (True, None),
        "deep": (False, _true),
        "control": (False, _true),
        "must_contain": (False, _probes),
        # require_rows: some ONE row matches every field. A value is a substring, a list of
        # substrings all in that field, or {"tail_of": <field>}, equal to that field's last
        # path component on the same row.
        "require_rows": (False, lambda v: _rows(
            v, columns, _require_value,
            "a substring, a list of substrings, or {\"tail_of\": <field>}")),
        # forbid_rows: no row matches every field EXACTLY. A list or {"tail_of"} here would be
        # compared as its own text, match no row, and pass whatever the payload held.
        "forbid_rows": (False, lambda v: _rows(
            v, columns, lambda x, _: _text(x) is None, "an exact non-empty string")),
        "known_gaps": (False, _texts),
        "demo_beat": (False, _text),
        "composes": (False, _names),
    }


CLASSIFIED = {
    "must_find": (True, lambda v: None if v == [] else _names(v)),
    "forbid": (False, _names),
    # A string that must appear in no finding's evidence: rows a stock machine carries,
    # like libxcursor1, that must not become evidence for Cursor.
    "forbid_evidence": (False, _texts),
    "every_extension": (False, _true),
}
# requires.json: a macOS floor, for a scenario whose software needs a newer guest than a
# runner may have. Below it the harness reports SKIP with the reason.
REQUIRES = {"min_macos": (True, lambda v: None if isinstance(v, int) and not isinstance(v, bool)
                          and v >= 11 else "a macOS major version, 11 or later"),
            "why": (True, _text)}
# What a shell harness may ask for, and the answer when a scenario does not say.
FIELDS = {"platform": None, "deep": False, "requires.min_macos": 0, "requires.why": ""}


def _shape(where, doc, vocabulary, elsewhere):
    """`elsewhere` maps a key this level does not read to where it is read."""
    if not isinstance(doc, dict):
        return [f"{where} is not a JSON object"]
    errors = [f"{where}: {k!r} is read by nothing"
              + (f"; it belongs {elsewhere[k]}" if k in elsewhere else "")
              for k in sorted(set(doc) - set(vocabulary))]
    for key, (required, shape) in vocabulary.items():
        if key not in doc:
            if required:
                errors.append(f"{where}: {key!r} is required")
        elif shape and shape(doc[key]):
            errors.append(f"{where}: {key!r} should be {shape(doc[key])}")
    return errors


def shape_errors(name, exp, req=None, columns=None):
    """What is wrong with one scenario's files on their own, without the catalog."""
    top = _top(columns or _columns())
    errors = _shape(f"{name}: expected.json", exp, top,
                    dict.fromkeys(CLASSIFIED, "under `classified`"))
    if not isinstance(exp, dict):
        return errors
    if "classified" in exp:
        errors += _shape(f"{name}: classified", exp["classified"], CLASSIFIED,
                         dict.fromkeys(top, "at the top level"))
    if req is not None:
        errors += _shape(f"{name}: requires.json", req, REQUIRES, {})
        if exp.get("platform") != "darwin":
            errors.append(f"{name}: requires.json carries a macOS floor on a "
                          f"{exp.get('platform')} scenario")
    # A ROW KIND IS ONE THE SCENARIO COUNTS. A payload row of any other kind fails the run as
    # UNEXPECTED KIND, so a spec naming one can match nothing in a passing run: a misspelt
    # kind under forbid_rows passes whatever the payload holds.
    if not _counts(exp.get("counts")):
        counted = {k for key in exp["counts"] for k in key.split("+")}
        for key in ("forbid_rows", "require_rows"):
            for spec in exp.get(key) if isinstance(exp.get(key), list) else []:
                kind = spec.get("kind") if isinstance(spec, dict) else None
                if isinstance(kind, str) and kind not in counted:
                    errors.append(f"{name}: {key} names kind {kind!r}, which counts does not, "
                                  f"so no row of it reaches a passing run")
    return errors


# --- reading --------------------------------------------------------------------------------

def read(name, where=SCENARIOS):
    """(expected, requires or None) for one scenario, parsed and unchecked."""
    d = pathlib.Path(where) / name
    req = d / "requires.json"
    return (json.loads((d / "expected.json").read_text()),
            json.loads(req.read_text()) if req.exists() else None)


def names(where=SCENARIOS):
    return sorted(p.parent.name for p in pathlib.Path(where).glob("*/expected.json"))


def on_platform(platform, where=SCENARIOS):
    """Every scenario that declares `platform`. One whose expected.json cannot be parsed is
    included: could-not-look must not read as nothing-to-run."""
    out = []
    for name in names(where):
        try:
            if read(name, where)[0].get("platform") != platform:
                continue
        except ValueError:
            pass
        out.append(name)
    return out


def field(name, key, where=SCENARIOS):
    """One FIELDS value, or its default when the scenario does not say. The files are
    checked first, so a misspelt key fails here instead of reading as the default."""
    if key not in FIELDS:
        raise KeyError(f"no field {key!r}; one of {sorted(FIELDS)}")
    exp, req = read(name, where)
    errors = shape_errors(name, exp, req)
    if errors:
        raise ValueError("\n".join(errors))
    if key.startswith("requires."):
        min_macos, why = floor(name, where)
        return min_macos if key == "requires.min_macos" else why
    return exp.get(key, FIELDS[key])


def floor(name, where=SCENARIOS, _through=()):
    """(min_macos, why): the scenario's own floor, or the highest of the scenarios it
    composes, since it runs their setups and must find what they find. 90-demo-fleet
    carries none of its own and runs 11-perplexity-desktop, which needs macOS 15."""
    if name in _through:
        raise ValueError(f"{name}: composes itself, through {' -> '.join(_through + (name,))}")
    exp, req = read(name, where)
    best = (req["min_macos"], req["why"]) if req else (FIELDS["requires.min_macos"],
                                                      FIELDS["requires.why"])
    for sibling in exp.get("composes") or []:
        need, why = floor(sibling, where, _through + (name,))
        if need > best[0]:
            best = (need, f"{sibling}: {why}")
    return best


def catalog(root=ROOT):
    """(agents, platforms) from catalog/agents.yaml and catalog/routes.yaml."""
    import yaml
    agents = yaml.safe_load((root / "catalog" / "agents.yaml").read_text())["agents"]
    platforms = yaml.safe_load((root / "catalog" / "routes.yaml").read_text())["platforms"]
    return agents, platforms


# --- derived from the catalog ---------------------------------------------------------------

@functools.lru_cache(maxsize=None)
def store_routes(root=ROOT):
    """The routes whose values are Chrome Web Store ids, read off catalog/routes.yaml by
    their purl rather than named here: a setup fetches each from the store."""
    import yaml
    routes = yaml.safe_load((root / "catalog" / "routes.yaml").read_text())["routes"]
    return tuple(sorted(r for r, spec in routes.items() if spec.get("purl") == "chrome-extension"))


def extension_ids(agents, platform):
    """[(id, agent)] for every Web Store id the catalog matches on `platform`. Not a
    superseded one: it stays on its route for old machines, and the store no longer serves
    it, so a setup that fetched it would fail every run (docs/signature-lifecycle.md)."""
    out = []
    for a in agents:
        if platform not in (a.get("platforms") or []):
            continue
        retired = {(str(s.get("route")), str(s.get("value"))) for s in a.get("superseded") or []}
        out += [(str(v), a["id"]) for r in store_routes() for v in a.get(r) or []
                if (r, str(v)) not in retired]
    return out


def extensions_text(agents, platform):
    lines = [f"# Generated from catalog/agents.yaml by `python3 tools/scenarios.py --write`; do",
             f"# not edit. Every extension id the catalog matches on {platform}, and its agent."]
    return "\n".join(lines + [f"{i} {aid}" for i, aid in extension_ids(agents, platform)]) + "\n"


def must_find(name, lookup, agents, _through=()):
    """Every agent the scenario must find: its own list, the platform's extension agents
    under every_extension, and what each scenario it composes must find. `lookup(name)`
    returns a parsed expected.json, so a reader of git revisions can use this too. A
    scenario that composes itself is a ValueError, never a RecursionError past every gate."""
    if name in _through:
        raise ValueError(f"{name}: composes itself, through {' -> '.join(_through + (name,))}")
    exp = lookup(name)
    cls = exp.get("classified") or {}
    out = set(cls.get("must_find") or [])
    if cls.get("every_extension"):
        out |= {aid for _, aid in extension_ids(agents, exp.get("platform"))}
    for sibling in exp.get("composes") or []:
        out |= must_find(sibling, lookup, agents, _through + (name,))
    return out


def catalog_errors(name, docs, agents, platforms, where=SCENARIOS):
    """What is wrong with a scenario against the catalog and its siblings. `docs` is
    {name: expected} for every scenario."""
    exp = docs[name]
    cls = exp.get("classified") or {}
    ids = {a["id"] for a in agents}
    plat = exp.get("platform")
    errors = []
    if plat not in platforms:
        errors.append(f"{name}: platform {plat!r} is not one of {platforms}")
    for key in ("must_find", "forbid"):
        errors += [f"{name}: classified.{key} names {aid!r}, which is not an id in "
                   f"catalog/agents.yaml" for aid in cls.get(key) or [] if aid not in ids]
    sibling_errors = []
    for sibling in exp.get("composes") or []:
        sib = docs.get(sibling)
        if sib is None or sibling == name:
            sibling_errors.append(f"{name}: composes {sibling!r}, which is not another scenario "
                                  f"whose files pass")
        elif sib.get("composes"):
            sibling_errors.append(f"{name}: composes {sibling!r}, which composes others")
        elif sib.get("platform") != plat:
            sibling_errors.append(f"{name}: composes {sibling!r}, a {sib.get('platform')} "
                                  f"scenario")
    errors += sibling_errors
    if exp.get("composes") and cls.get("must_find"):
        errors.append(f"{name}: composes others, so its must_find is theirs and its own is []")
    if exp.get("control") and (cls.get("must_find") or cls.get("every_extension")
                               or exp.get("composes")):
        errors.append(f"{name}: a control finds nothing, so it may not name or derive must_find")
    if not sibling_errors:
        clash = must_find(name, docs.__getitem__, agents) & set(cls.get("forbid") or [])
        errors += [f"{name}: {aid!r} is both found and forbidden" for aid in sorted(clash)]
    # THE LIST A SETUP INSTALLS FROM IS GENERATED, and an empty one would install nothing and
    # assert nothing, which is green.
    listed = pathlib.Path(where) / name / EXTENSIONS
    if cls.get("every_extension"):
        if not extension_ids(agents, plat):
            errors.append(f"{name}: every_extension, and the catalog matches no extension "
                          f"on {plat}")
        elif not listed.exists() or listed.read_text() != extensions_text(agents, plat):
            errors.append(f"{name}: {EXTENSIONS} is not the catalog's list; run "
                          f"`python3 tools/scenarios.py --write`")
    elif listed.exists():
        errors.append(f"{name}: {EXTENSIONS} without every_extension installs agents nothing "
                      f"asserts; run `python3 tools/scenarios.py --write`")
    return errors


def check(agents, platforms, where=SCENARIOS):
    """Every problem with every scenario, as messages."""
    columns, docs, errors = _columns(), {}, []
    for name in names(where):
        try:
            exp, req = read(name, where)
        except ValueError as exc:
            errors.append(f"{name}: does not parse: {exc}")
            continue
        found = shape_errors(name, exp, req, columns)
        errors += found
        if not found:
            docs[name] = exp
    for name in sorted(docs):
        errors += catalog_errors(name, docs, agents, platforms, where)
    return errors


def write(agents, where=SCENARIOS):
    """Regenerate every extension-ids.txt, and remove one no scenario declares."""
    for name in names(where):
        exp = read(name, where)[0]
        path = pathlib.Path(where) / name / EXTENSIONS
        if (exp.get("classified") or {}).get("every_extension"):
            path.write_text(extensions_text(agents, exp.get("platform")))
        elif path.exists():
            path.unlink()


def load(expected_path, root=ROOT):
    """(expected, must_find) for the scenario whose expected.json is the file at
    `expected_path`, refused with every problem found when its files, the scenarios it
    composes or the catalog disagree. What the assertions read."""
    path = pathlib.Path(expected_path).resolve()
    where, name = path.parent.parent, path.parent.name
    agents, platforms = catalog(root)
    req_path = path.parent / "requires.json"
    exp = json.loads(path.read_text())
    errors = shape_errors(name, exp, json.loads(req_path.read_text()) if req_path.exists() else None)
    docs = {name: exp}
    if not errors:
        # A composed scenario is checked here too: a malformed one would derive a must_find
        # of whatever its value spells, a string's letters included.
        for sibling in exp.get("composes") or []:
            if (where / sibling / "expected.json").exists():
                sib, sib_req = read(sibling, where)
                found = shape_errors(sibling, sib, sib_req)
                errors += found
                if not found:
                    docs[sibling] = sib
        errors += catalog_errors(name, docs, agents, platforms, where)
    if errors:
        raise ValueError("\n".join(errors))
    return exp, must_find(name, docs.__getitem__, agents)


# --- what each key asserts ------------------------------------------------------------------

def counts_verdict(rows, exp):
    """(lines, ok) for counts, must_contain, forbid_rows and require_rows.

    Counts, not "did it parse": every defect found so far returned plausible output with the
    wrong number of rows. The query enumerates and holds no catalog, so a count proves only
    that each BRANCH still returns rows, and most counts are floors."""
    got = collections.Counter(r["kind"] for r in rows)
    want = exp["counts"]
    lines, ok_all = [f"{'kind':10} {'want':>8} {'got':>8}"], True

    # A `+` IN A KEY SUMS THE KINDS IT JOINS: `deb+rpm >= 1` says a Linux box's package
    # branch ran, whichever family the distro uses, where `deb >= 1` said Ubuntu.
    def count(key):
        return sum(got.get(k, 0) for k in key.split("+"))
    covered = {k for key in want for k in key.split("+")}
    for kind in sorted(set(want) | (set(got) - covered)):
        w, g = want.get(kind), count(kind)
        if w is None:
            lines.append(f"{kind:10} {'-':>8} {g:>8}  UNEXPECTED KIND")
            ok_all = False
            continue
        ok = g >= int(w[2:]) if isinstance(w, str) else g == w
        lines.append(f"{kind:10} {str(w):>8} {g:>8}  {'ok' if ok else 'FAIL'}")
        ok_all &= ok

    # must_contain: a string some row's JSON contains. A list means ANY OF THESE, because
    # the same cask resolved to builds with different bundle ids on two macOS labels (run
    # 33511815638), and the probe is the only thing that reads the raw row.
    blobs = [json.dumps(r) for r in rows]
    for probe in exp.get("must_contain", []):
        alts = probe if isinstance(probe, list) else [probe]
        hit = any(p in b for b in blobs for p in alts)
        lines.append(f"  must_contain {' | '.join(alts)!r}: {'ok' if hit else 'FAIL'}")
        ok_all &= hit

    # forbid_rows: NO ROW MATCHES EVERY NAMED FIELD, exactly, because what is asserted is
    # that a QUERY excluded something -- a removed-but-not-purged deb, which dpkg keeps as
    # `deinstall ok config-files` with its version -- and a substring would be satisfied or
    # defeated by whatever else was installed.
    for spec in exp.get("forbid_rows", []):
        hits = [r for r in rows if all(str(r.get(k, "")) == v for k, v in spec.items())]
        label = ", ".join(f"{k}={v}" for k, v in spec.items())
        lines.append(f"  forbid_rows {label}: {'FAIL' if hits else 'ok'}"
                     + (f"  found {len(hits)}" if hits else ""))
        ok_all &= not hits

    # require_rows: SOME ONE ROW MATCHES EVERY NAMED FIELD, by substring, because a
    # sideload hash and a permission list vary by run, and must_contain cannot say "on the
    # same row". {"tail_of": f} must EQUAL the last path component of f on that row: a
    # release read off a path changes with every install, and the substring `.` that stood
    # in for it passed any dotted version.
    def field_ok(r, k, v):
        have = str(r.get(k, ""))
        if isinstance(v, dict):
            return have != "" and have == re.split(r"[\\/]", str(r.get(v["tail_of"], "")))[-1]
        return all(s in have for s in (v if isinstance(v, list) else [v]))
    for spec in exp.get("require_rows", []):
        ok = any(all(field_ok(r, k, v) for k, v in spec.items()) for r in rows)
        label = ", ".join(f"{k}~{v}" for k, v in spec.items())
        lines.append(f"  require_rows {label}: {'ok' if ok else 'FAIL'}")
        ok_all &= ok
    return lines, ok_all


def classified_verdict(result, exp, want):
    """(lines, ok) for what bin/classify concluded: every agent in `want` (must_find, as
    derived) is found, nothing else is, and no finding rests on forbid_evidence."""
    found = {f["id"] for f in result["findings"]}
    cls = exp["classified"]
    lines, ok_all = [], True
    for agent in sorted(want):
        ok = agent in found
        lines.append(f"  classified must_find {agent!r}: {'ok' if ok else 'FAIL'}")
        ok_all &= ok
    extra = sorted(found - want)
    lookalike = set(cls.get("forbid") or [])
    lines.append("  classified nothing else: " + (
        "ok" if not extra else "FAIL - also found " + ", ".join(
            a + (" (a declared lookalike)" if a in lookalike else "") for a in extra)))
    ok_all &= not extra
    # `nothing else` asks whether an AGENT was claimed. This asks whether a ROW became
    # evidence: a stock Ubuntu's libxcursor1 is rightly in the payload, and must not be
    # evidence for Cursor even while some other row correctly is.
    # Against each field's VALUE, never the evidence's JSON text, where a backslash is
    # doubled: a Windows path probe would match nothing there and pass.
    for probe in cls.get("forbid_evidence", []):
        claimed = sorted({f["id"] for f in result["findings"] for e in f.get("evidence", [])
                          if any(probe in str(v)
                                 for v in (e.values() if isinstance(e, dict) else [e]))})
        lines.append(f"  forbid_evidence {probe!r}: "
                     + ("ok" if not claimed else "FAIL - claimed by " + ", ".join(claimed)))
        ok_all &= not claimed
    return lines, ok_all


# --- command line ---------------------------------------------------------------------------

def _assert(kind, rows_path, expected_path):
    try:
        exp, want = load(expected_path)
    except ValueError as exc:
        print(f"  FAIL: the scenario's files are refused:\n{exc}")
        return 1
    rows = json.loads(pathlib.Path(rows_path).read_text())  # a bare array, as every producer emits
    if kind == "counts":
        lines, ok = counts_verdict(rows, exp)
    else:
        proc = subprocess.run([sys.executable, str(ROOT / "bin" / "classify"), "--json",
                               "--show-unmatched"],
                              input=json.dumps(rows), capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"  FAIL: classifier exited {proc.returncode}: {proc.stderr.strip()[:200]}")
            return 1
        lines, ok = classified_verdict(json.loads(proc.stdout), exp, want)
    print("\n".join(lines))
    return 0 if ok else 1


def main(argv):
    if argv[:1] in (["--check"], ["--write"]):
        agents, platforms = catalog()
        if argv[0] == "--write":
            write(agents)
        errors = check(agents, platforms)
        print("\n".join(f"FAIL: {e}" for e in errors) or f"ok: {len(names())} scenarios")
        return 1 if errors else 0
    if argv[:1] == ["field"] and len(argv) == 3:
        try:
            value = field(argv[1], argv[2])
        except (KeyError, ValueError, OSError) as exc:
            print(f"scenarios.py field: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(value) if isinstance(value, bool) else value)
        return 0
    if argv[:1] == ["list"] and len(argv) == 2:
        print("\n".join(on_platform(argv[1])))
        return 0
    if argv[:1] == ["want"] and len(argv) == 2:
        try:
            exp, found = load(argv[1])
        except ValueError as exc:
            print(f"  FAIL: the scenario's files are refused:\n{exc}")
            return 1
        print(" ".join([exp["platform"]] + sorted(found)))
        return 0
    if argv[:1] in (["assert-counts"], ["assert-classified"]) and len(argv) == 3:
        return _assert(argv[0][7:], argv[1], argv[2])
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
