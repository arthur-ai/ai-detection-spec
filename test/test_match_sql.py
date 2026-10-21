#!/usr/bin/env python3
"""Does the rendered match SQL agree with bin/classify, evidence row for evidence row?

tools/render_match.py renders the catalog into SQL that matches on the endpoint. It is
derived from bin/classify's own index, which makes agreement LIKELY and proves nothing:
a route the renderer skips, a regex osquery's engine reads differently, a predicate that
is case-insensitive where the classifier is not -- each would match a little less or a
little more, silently, which is the failure this repo exists to refuse. So every payload
here is matched both ways and the two answers are compared as a MULTISET of (agent,
kind, id, loc), not as a set of agents: a row counted twice inside one agent, or an
unmatched row that leaked into a finding, both go red.

Needs osqueryi, because the SQL side is the thing under test and there is no other
engine that runs it. Without one this prints SKIP and exits 0 so test/lint.sh can run
on a runner with no osquery; `--require-osqueryi` turns that into a failure for the
jobs that do have it. Extra arguments are payload files to check besides the fixtures.

Two more modes serve the scenario harness (test/lib/assert.sh's assert_match_sql):

    --wrapper <payload.json>     print the SQL bin/discover --names would run over it
    --assert <actual> <expected> [--agents <json>] [--parity <json>] [--root <dir>]
                                 parity over <actual>, then dist/agents-<platform>.sql's
                                 findings against expected.json's must_find and forbid.
                                 Given the two json files it runs no osqueryi at all,
                                 which is how the Tart harness asserts on a host without one.
"""
import collections
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "test" / "fixtures"
sys.path.insert(0, str(ROOT / "tools"))
import render_match as R  # noqa: E402
os.environ.setdefault("AI_DISCOVERY_TELEMETRY", "0")

failures = []


def check(label, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'}  {label}{'' if condition else '  ' + detail}")
    if not condition:
        failures.append(label)


def osqueryi_path():
    """$OSQI, then tools/measure.py's candidate list -- one list, not a third copy."""
    import shutil
    import measure
    for c in [os.environ.get("OSQI")] + list(measure.OSQI_CANDIDATES):
        if not c:
            continue
        found = c if os.path.isabs(c) and os.access(c, os.X_OK) else shutil.which(c)
        if found:
            return found
    return None


def run_sql(osqi, sql, privileged=False):
    """osqueryi --json over `sql` on stdin. `privileged` adds `sudo -n` when not root,
    for the standalone artifact, which reads other users' homes; the parity wrapper
    reads a document and never needs it."""
    cmd = [osqi, "--json"]
    if privileged and os.geteuid() != 0:
        proc = subprocess.run(["sudo", "-n"] + cmd, input=sql, capture_output=True, text=True)
        if proc.returncode == 0:
            return json.loads(proc.stdout or "[]")
        if "password" not in proc.stderr:
            raise RuntimeError(f"osqueryi exited {proc.returncode}: {proc.stderr.strip()[:300]}")
        # A developer's Mac, where sudo wants a password. Say so and read what this
        # account can: the live check then sees one home rather than all of them, which
        # can only make a must_find miss, never make a forbid pass by accident on a row
        # it would otherwise have seen. CI runners and the containers never land here.
        print("  (sudo -n refused; running the live artifact unprivileged, so other "
              "users' homes are unread)")
    proc = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"osqueryi exited {proc.returncode}: {proc.stderr.strip()[:300]}")
    return json.loads(proc.stdout or "[]")


def shipped_fragment():
    """dist/signatures.sql as it ships -- the file under test, never a fresh render."""
    return (ROOT / "dist" / "signatures.sql").read_text()


def platform_here():
    return {"Darwin": "darwin", "Linux": "linux"}.get(os.uname().sysname)


# The `ev` CTE bin/discover --names builds over a payload, written once here and asserted
# against the runner's own text below, so the test cannot pass on a wrapper the runner
# does not use.
EV_FROM_DOC = (
    "ev AS (SELECT json_extract(e.value,'$.kind') AS kind,"
    " coalesce(json_extract(e.value,'$.id'),'') AS id,"
    " coalesce(json_extract(e.value,'$.ver'),'') AS ver,"
    " coalesce(json_extract(e.value,'$.loc'),'') AS loc,"
    " json_extract(e.value,'$.extra') AS extra"
    " FROM d, json_each(d.doc) e)")
HIT_SELECT = "SELECT agent, kind, id, loc FROM hit ORDER BY agent, kind, id, loc;"


def wrapper(doc, fragment_text, select=HIT_SELECT):
    return ("WITH d(doc) AS (VALUES ('" + doc.replace("'", "''") + "')), "
            + EV_FROM_DOC + "\n" + fragment_text + select)


def sql_hits(osqi, rows, fragment_text):
    out = run_sql(osqi, wrapper(json.dumps(rows), fragment_text))
    return collections.Counter((r["agent"], r["kind"], r["id"], r["loc"]) for r in out)


def classify_hits(classify, rows, catalog, routes):
    findings, *_ = classify.classify(rows, catalog, routes)
    return collections.Counter(
        (aid, str(r.get("kind")), str(r.get("id", "")), str(r.get("loc", "")))
        for aid, hits in findings.items() for _, r in hits)


def diff(a, b):
    """Rows in exactly one side, as a short string."""
    only_a = sorted((a - b).elements())
    only_b = sorted((b - a).elements())
    return (f"classify-only={only_a[:4]} sql-only={only_b[:4]}"
            if only_a or only_b else "")


def assert_mode(argv):
    """The scenario assertion: parity on the rows a scenario collected, then the
    standalone artifact's findings against the scenario's must_find and forbid."""
    import argparse
    ap = argparse.ArgumentParser(prog="test_match_sql.py --assert")
    ap.add_argument("actual")
    ap.add_argument("expected")
    ap.add_argument("--agents", help="dist/agents-<platform>.sql's output, already run")
    ap.add_argument("--parity", help="the --wrapper SQL's output, already run")
    ap.add_argument("--root", default=str(ROOT))
    a = ap.parse_args(argv)
    rows = json.load(open(a.actual))
    expected = json.load(open(a.expected))
    plat = expected.get("platform") or platform_here()
    frag = shipped_fragment()
    classify = R.load_classify()
    catalog = classify.load_catalog(R.CATALOG)
    routes = classify.load_routes()
    osqi = None
    if not (a.agents and a.parity):
        osqi = osqueryi_path()
        if osqi is None:
            sys.exit("  FAIL: assert_match_sql needs osqueryi, or --agents and --parity "
                     "from a machine that has one")

    # Parity on the rows the scenario actually collected: the one place real installs
    # meet the rendered SQL.
    want = classify_hits(classify, rows, catalog, routes)
    parity = (json.load(open(a.parity)) if a.parity
              else run_sql(osqi, wrapper(json.dumps(rows), frag)))
    got = collections.Counter((r["agent"], r["kind"], r["id"], r["loc"]) for r in parity)
    check(f"match SQL agrees with the classifier on {sum(want.values())} evidence rows",
          want == got, diff(want, got))

    # The standalone artifact, live. It has no container branch, so it is expected to
    # find an agent only when THIS PAYLOAD found it through a kind the artifact reads.
    #
    # DECIDED FROM THE EVIDENCE, NOT THE CATALOG. This first asked whether the agent had
    # any non-container signature, and aider does -- a state dir and a pipx/uv name --
    # so 79-linux-image, which installs aider only as an image, demanded the standalone
    # file find it and failed. Whether an agent is reachable here is a fact about how it
    # was installed on this machine, which only the classifier's evidence records. An
    # agent found only through images is still asserted above, by the parity check over
    # a payload that carries the bounded container branch.
    live = (json.load(open(a.agents)) if a.agents
            else run_sql(osqi, (pathlib.Path(a.root) / "dist" / f"agents-{plat}.sql")
                         .read_text(), privileged=True))
    live_found = {r["agent"] for r in live}
    inline_kinds = {k for q in R.build.queries() if not q["expensive"]
                    and plat in q["platforms"] for k in q["kinds"]}
    found_by = collections.defaultdict(set)
    for agent, kind, _, _ in want:
        found_by[agent].add(kind)
    want_c = expected.get("classified") or {}
    for agent in want_c.get("must_find", []):
        if not found_by.get(agent, set()) & inline_kinds:
            kinds = ", ".join(sorted(found_by.get(agent, set()))) or "nothing"
            print(f"  (dist/agents-{plat}.sql cannot see {agent!r} here: this payload "
                  f"found it only through {kinds}; covered by the parity check above)")
            continue
        check(f"dist/agents-{plat}.sql finds {agent!r}", agent in live_found,
              f"found {sorted(live_found)}")
    for agent in want_c.get("forbid", []):
        check(f"dist/agents-{plat}.sql does not claim {agent!r}", agent not in live_found)
    return 1 if failures else 0


def main():
    if "--wrapper" in sys.argv:
        path = sys.argv[sys.argv.index("--wrapper") + 1]
        sys.stdout.write(wrapper(pathlib.Path(path).read_text(), shipped_fragment()))
        return 0
    if "--assert" in sys.argv:
        return assert_mode(sys.argv[sys.argv.index("--assert") + 1:])

    require = "--require-osqueryi" in sys.argv
    extra = [pathlib.Path(a) for a in sys.argv[1:] if not a.startswith("--")]
    osqi = osqueryi_path()
    if osqi is None:
        if require:
            sys.exit("FAIL: --require-osqueryi and no osqueryi found (set OSQI)")
        print("SKIP: no osqueryi on this machine; the rendered SQL cannot be run here")
        return 0

    classify = R.load_classify()
    catalog = classify.load_catalog(R.CATALOG)
    routes = classify.load_routes()
    registry = classify.Registry(routes)
    sigs = R.signatures(classify, catalog, registry)
    tool_dir = classify.TOOL_DIR.pattern
    frag = R.fragment(sigs, tool_dir)

    # --- the shipped fragment is the one under test, not a fresh render -------------
    shipped = shipped_fragment()
    check("dist/signatures.sql carries the fragment this test renders", frag in shipped,
          "run tools/render_match.py")

    # --- the wrapper under test is the wrapper the runner builds ----------------------
    # bin/discover prints its `ev` CTE through printf, with `$` escaped, so the text is
    # compared expression by expression after unescaping rather than as one string.
    runner = (ROOT / "bin" / "discover").read_text().replace("\\$", "$")
    for expr in EV_FROM_DOC[len("ev AS (SELECT "):-1].split(" FROM ")[0].split(", "):
        check(f"bin/discover builds `{expr}`", expr in runner)
    check("bin/discover reads the rows FROM d, json_each(d.doc) e",
          "FROM d, json_each(d.doc) e)" in runner)

    # --- parity on every payload --------------------------------------------------
    payloads = sorted(FIXTURES.glob("*.json")) + extra
    for path in payloads:
        rows = json.loads(path.read_text())
        want = classify_hits(classify, rows, catalog, routes)
        got = sql_hits(osqi, rows, frag)
        check(f"parity on {path.name}: {sum(want.values())} evidence rows across "
              f"{len({a for a, *_ in want})} agents", want == got, diff(want, got))

    # --- controls: what must and must not match, said explicitly ------------------
    # Parity alone would pass if the classifier and the SQL drifted TOGETHER. Each row
    # below names its expected agent (or None), so a shared regression still goes red.
    controls = [
        ("file", "/Users/u/.claude/", "claude-code"),
        ("file", "/Users/u/.claude", "claude-code"),
        ("file", "/Users/u/.claudefoo/", None),                 # home-dir is anchored
        ("file", "/opt/dana/.claude/", None),                    # outside every home root
        ("file", "/root/.claude/", "claude-code"),               # /root is its own root
        ("daemon", "ai.openclaw.gateway", "openclaw"),
        ("daemon", "AI.OPENCLAW.X", None),                       # prefix is case-sensitive
        ("file", "/Users/u/.local/bin/hermes", "hermes"),             # home-prefix: the path
        ("file", "/Users/u/.local/bin/hermes-acp", None),             # ...not a name prefix
        ("file", "/home/u/.local/bin/muse-bin-1.4.10-R6427.1", None),
        ("file", "/home/u/.local/bin/musescore", None),
        ("file", "/home/u/.local/bin/claude-monitor", None),
        ("file", "/home/u/.local/share/uv/tools/openclaw/", "openclaw"),   # npm bridge
        ("file", "/root/.local/pipx/venvs/aider-chat/", "aider"),          # tool-dir
        ("image", "docker.io/paulgauthier/aider:v1,paulgauthier/aider:latest", "aider"),
        ("image", "paulgauthier/aider-fork:latest", None),
        ("image", "notpaulgauthier/aider:latest", None),
        ("image", "myreg:5000/paulgauthier/aider:1", None),
        ("deb", "libxcursor1", None),
        ("deb", "cursor", "cursor"),
        ("npm", "@anthropic-ai/claude-code", "claude-code"),
        ("npm", "mcp", None),
        ("proc", "ai.openclaw.mac", "openclaw"),               # running_apps reads bundle_ids
        ("proc", "@openai/codex", "codex-cli"),                # running_npm reads npm
        ("proc", "com.apple.finder", None),
        ("proc", "/home/u/.local/share/claude/versions/2.1.292", "claude-code"),   # process_paths
        ("proc", "/home/u/.local/share/claude-fork/versions/1", None),
        ("jbplugin", "cline", "cline"),
        ("jbplugin", "cline-2.0.6.jar", None),                 # a bare jar is not the directory
        ("jbplugin", "continue-intellij-extension", "continue"),
        ("scan", "containers", None),
    ]
    rows = [{"kind": k, "id": i, "ver": "", "loc": i if k == "file" else "",
             "extra": "absent" if k == "scan" else "", "perms": ""}
            for k, i, _ in controls]
    got = sql_hits(osqi, rows, frag)
    want = classify_hits(classify, rows, catalog, routes)
    check("parity on the control rows", want == got, diff(want, got))
    by_id = collections.defaultdict(set)
    for agent, kind, ident, _ in got:
        by_id[(kind, ident)].add(agent)
    for kind, ident, agent in controls:
        found = by_id.get((kind, ident), set())
        if agent is None:
            check(f"{kind} {ident!r} is NOT matched", not found, f"matched {sorted(found)}")
        else:
            check(f"{kind} {ident!r} is {agent}", found == {agent}, f"got {sorted(found)}")

    # --- the image regex, rule for rule, in osquery's regex engine ------------------
    table = [
        ("paulgauthier/aider", "paulgauthier/aider:latest", True),
        ("paulgauthier/aider", "docker.io/paulgauthier/aider:v1", True),
        ("paulgauthier/aider", "index.docker.io/paulgauthier/aider:v1", True),
        ("paulgauthier/aider", "paulgauthier/aider", True),
        ("paulgauthier/aider", "x/y:1,paulgauthier/aider:2", True),
        ("paulgauthier/aider", "paulgauthier/aider-fork:latest", False),
        ("paulgauthier/aider", "notpaulgauthier/aider:latest", False),
        ("paulgauthier/aider", "myreg:5000/paulgauthier/aider:1", False),
        ("paulgauthier/aider", "paulgauthier/aider/sub:1", False),
        ("paulgauthier/aider", "docker.io/library/paulgauthier/aider:1", False),
        ("ghcr.io/block/goose", "ghcr.io/block/goose:latest", True),
        ("alpine", "alpine:3", True),
        ("alpine", "library/alpine:3", True),
        ("alpine", "docker.io/library/alpine:3", True),
        ("alpine", "public.ecr.aws/docker/library/python:3.12", False),
        ("python", "public.ecr.aws/docker/library/python:3.12", False),
    ]
    vals = ",".join(f"('{tag}','{R.image_regex(repo).replace(chr(39), chr(39) * 2)}',{int(exp)})"
                    for repo, tag, exp in table)
    out = run_sql(osqi, f"WITH t(tag, pat, want) AS (VALUES {vals}) SELECT tag, want, "
                        f"(regex_match(tag, pat, 0) IS NOT NULL) AS got FROM t;")
    for r in out:
        check(f"image regex: {r['tag']} -> {bool(int(r['want']))}", r["want"] == r["got"])
    for repo, tag, exp in table:
        # And the classifier's own normalisation agrees with the table, so the table is
        # not merely describing the regex to itself.
        check(f"image_repo agrees: {tag}",
              (classify.image_repo(tag) == repo) == exp or
              # image_repo('library/alpine:3') is 'alpine'; the regex says the same.
              (repo in classify.image_repos(tag)) == exp)

    # --- Fleet policies: pass exactly when the classifier finds no evidence of the kinds
    # the policy reads ---------------------------------------------------------------
    import yaml
    docs = [d for d in yaml.safe_load_all((ROOT / "dist" / "fleet-policies.yml").read_text())
            if d]
    check("fleet-policies.yml holds at least one policy", bool(docs))
    sig_re = re.compile(r"\('((?:[^']|'')*)','(?:[^']|'')*','(?:[^']|'')*','((?:[^']|'')*)',")
    fixture_rows = {p.name: json.loads(p.read_text()) for p in sorted(FIXTURES.glob("*.json"))}
    fixture_rows["controls"] = rows
    policies = []
    for d in docs:
        q = d["spec"]["query"].strip()
        head, sep, rest = q.partition(", sig(")
        check(f"policy {d['spec']['name']!r} is WITH ev AS (...) then the fragment",
              head.startswith("WITH ev AS (") and sep and rest.endswith(
                  "SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM hit);"))
        pairs = sig_re.findall(rest)
        agents = {a for a, _ in pairs}
        kinds = {k for _, k in pairs}
        check(f"policy {d['spec']['name']!r} names one agent", len(agents) == 1, str(agents))
        policies.append((d["spec"]["name"], agents.pop() if agents else None, kinds, rest))
    check("policy names are unique, so a verdict below names one policy",
          len({p[0] for p in policies}) == len(policies))
    # ONE STATEMENT PER PAYLOAD, every policy a labelled arm of it. This ran one osqueryi
    # per (policy, payload): 69 policies over four payloads was 276 process spawns and 70s
    # of the CI step at 13% CPU. Each policy's `sig` and `hit` now run as a scalar subquery
    # over the shared `ev`, which SQLite resolves from the enclosing WITH, and the subquery
    # is NULL exactly when the policy's `SELECT 1 WHERE NOT EXISTS` returns no row. The
    # top-level shape is still held by the string check above, and both forms substitute
    # the payload's `ev` for the shipped one, as this test always has. A hard SQL error in
    # one arm fails the whole payload with osqueryi's message rather than a policy name;
    # render_match.py compiles every regex before writing it, so that is a build error
    # here, not a diagnosis this test is expected to make.
    for name, prow in fixture_rows.items():
        found = {aid: {str(r.get("kind")) for _, r in hits}
                 for aid, hits in classify.classify(prow, catalog, routes)[0].items()}
        arms = " UNION ALL ".join(
            f"SELECT '{pname.replace(chr(39), chr(39) * 2)}' AS policy, "
            f"((WITH sig({rest.rstrip().rstrip(';')}) IS NOT NULL) AS pass"
            for pname, _, _, rest in policies)
        sql = ("WITH d(doc) AS (VALUES ('" + json.dumps(prow).replace("'", "''")
               + "')), " + EV_FROM_DOC + " " + arms + ";")
        got = {r["policy"]: str(r["pass"]) == "1" for r in run_sql(osqi, sql)}
        for pname, agent, kinds, _ in policies:
            want_pass = not (found.get(agent, set()) & kinds)
            check(f"policy {pname!r} over {name}: {'passes' if want_pass else 'fails'}",
                  got.get(pname) == want_pass, f"got {got.get(pname)!r}")

    # --- the standalone artifact for this platform runs ---------------------------
    plat = platform_here()
    if plat:
        try:
            out = run_sql(osqi, (ROOT / "dist" / f"agents-{plat}.sql").read_text())
            check(f"dist/agents-{plat}.sql runs here ({len(out)} agents found, "
                  f"unprivileged)", True)
        except RuntimeError as exc:
            check(f"dist/agents-{plat}.sql runs here", False, str(exc))

    # --- agents the standalone files can never find are named in their headers ------
    qs = [q for q in R.build.queries() if not q["expensive"]]
    inline_kinds = {k for q in qs for k in q["kinds"]}
    image_only = R.image_only_agents(sigs, inline_kinds)
    by_kinds = sorted({a for a, *_ in sigs}
                      - {a for a, _, _, k, _, _, _ in sigs if k not in {"image", "container", "ilabel"}})
    check(f"image-only agents are exactly those with no inline kind: {image_only}",
          image_only == by_kinds, str(by_kinds))
    for p in ("agents-darwin.sql", "agents-linux.sql", "fleet-policies.yml"):
        text = (ROOT / "dist" / p).read_text()
        check(f"{p} names every image-only agent",
              all(a in text for a in image_only))

    # --- the comparison itself bites: drop one agent and it must say so --------------
    without = [s for s in sigs if s[0] != "openclaw"]
    broken = R.fragment(without, tool_dir)
    known = json.loads((FIXTURES / "known-agents.json").read_text())
    check("dropping openclaw from the fragment is detected",
          classify_hits(classify, known, catalog, routes) != sql_hits(osqi, known, broken))

    print()
    if failures:
        print(f"{len(failures)} FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("all match-SQL checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
