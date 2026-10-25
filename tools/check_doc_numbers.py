#!/usr/bin/env python3
"""Fail when a document states a catalog number that is no longer true.

The generated pages cannot go stale -- docs/agents.md and the README badges are rebuilt and
gated. PROSE CAN, and it did: CLAUDE.md claimed 40/40 coverage after the figure became
38/38, and the signature lifecycle doc said 42 identifiers after two were removed. Both read
perfectly; neither was true; nothing checked them.

A catalog that changes often makes this the normal case rather than an accident, so the
numbers in prose are checked against the tree on every run.

NUMBERS THAT ARE NOT CLAIMS ABOUT TODAY are exempt and must say so. Two kinds occur here:
a past MEASUREMENT ("growing the catalog from 21 agents to 221 left the composed artifact
byte-identical") and a hypothetical PROJECTION ("at 500 agents that is a few hundred regexes
per row"). Rewriting either would destroy the point it makes. Mark the line
<!--fixed-number--> and it is skipped -- deliberately verbose, so exempting is a decision
rather than a reflex.
"""
import importlib.machinery
import importlib.util
import json
import pathlib
import re
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ["README.md", "osquery/README.md", "CLAUDE.md", "osquery/CLAUDE.md", "CONTRIBUTING.md",
        "docs/signature-lifecycle-v2.md", "osquery/queries/COST.md", "SPEC.md"]
EXEMPT = "<!--fixed-number-->"


def truth():
    cat = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    # A broken agent_status is a finding, not a traceback to re-raise: this gate runs in
    # lint, and a stack trace from a subprocess names the wrong tool as the failure.
    proc = subprocess.run([sys.executable, str(ROOT / "tools" / "agent_status.py"), "--json"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print("doc-numbers: FAIL -- tools/agent_status.py --json did not run, so the numbers "
              "cannot be checked:")
        for line in proc.stderr.strip().splitlines()[-3:]:
            print(f"  {line}")
        sys.exit(1)
    st = json.loads(proc.stdout)
    idents = [i for a in st["agents"] for i in a["identifiers"]]
    # THE COVERAGE FORMULA IS BORROWED, NOT REPEATED. This file carried its own copy --
    # excluding only `alias` from the denominator while agent_status.badge_for() also
    # excluded `no-ci-platform`. The two agreed purely because no identifier had ever
    # reached that state, so a disagreement would have shipped the day one did: this gate
    # would pass while telling the README a number the page beside it contradicts.
    #
    # That is the five-copies-that-must-agree shape, one copy short of the `ext` bug. One
    # definition, imported from the module that owns it.
    loader = importlib.machinery.SourceFileLoader(
        "agent_status", str(ROOT / "tools" / "agent_status.py"))
    spec = importlib.util.spec_from_loader("agent_status", loader)
    status_mod = importlib.util.module_from_spec(spec)
    loader.exec_module(status_mod)
    covered, coverable, _ = status_mod.badge_for(st)
    wf = yaml.safe_load((ROOT / ".github" / "workflows" / "scenarios.yml").read_text())
    return {
        "agents": len(cat["agents"]),
        "identifiers": len(idents),
        "scenarios": len(wf["jobs"]["scenario"]["strategy"]["matrix"]["scenario"]),
        "blind spots": len(st["blind_spots"]),
        "coverage": (covered, coverable),
    }


PATTERNS = [(re.compile(rf"(\d+)\s+{word}\b"), word)
            for word in ("agents", "identifiers", "scenarios", "blind spots")]
COVERAGE = re.compile(r"(\d+)\s*/\s*(\d+)\s*(?:identifiers|coverage)?")


def telemetry_fields():
    """The published event field list must be the sent one.

    bin/classify declares EVENT_FIELDS once and docs/telemetry.md tabulates it for people
    deciding whether to leave telemetry on. Two lists that have to agree is the shape of
    every drift bug this repo has had -- five copies of the route vocabulary, one missing
    `ext`, every browser row dropped for months. So the code is the source and the page is
    checked against it, rather than both being maintained and neither being right.
    """
    doc = ROOT / "docs" / "telemetry.md"
    if not doc.exists():
        return ["docs/telemetry.md is missing, and bin/classify sends an event it is "
                "supposed to describe"]
    loader = importlib.machinery.SourceFileLoader("classify", str(ROOT / "bin" / "classify"))
    spec = importlib.util.spec_from_loader("classify", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    declared = set(mod.EVENT_FIELDS)
    # The Properties table only -- the envelope table above it describes Amplitude's own
    # fields, which bin/classify does not declare.
    body = doc.read_text().partition("### Properties")[2]
    published = set(re.findall(r"^\| `([a-z_]+)` \|", body, re.M))
    bad = []
    for missing in sorted(declared - published):
        bad.append(f"docs/telemetry.md: does not document `{missing}`, which "
                   f"bin/classify sends. A field nobody published is a field nobody "
                   f"agreed to.")
    for extra in sorted(published - declared):
        bad.append(f"docs/telemetry.md: documents `{extra}`, which bin/classify does not "
                   f"send. Remove it, or the page overstates what leaves the machine.")
    return bad


def dangling_doc_links():
    """A cited document must exist.

    THE ONE CLASS OF DRIFT NOTHING HERE CAUGHT. `bin/classify` went on citing the
    lifecycle document by its pre-split name after that file was renamed, and lint stayed
    green the whole time -- a reader following the pointer found nothing, which is worse
    than no pointer at all because it reads as a promise the tree makes.

    It survived a deliberate sweep for references, too: the sweep filtered by
    `--include=*.py`, and `bin/classify` has no extension. So this walks files by content
    rather than by name, which is the only version that cannot miss the same way.

    Note what this means for prose: naming a deleted file, even to describe its deletion,
    fails here. That is the right trade -- a check that could tell a citation from a
    reminiscence would be guessing, and the cost is one rephrasing.
    """
    bad = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or ".git" in path.parts:
            continue
        if path.suffix not in (".md", ".py", ".yaml", ".yml", ".sh", ""):
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        # THE WHOLE PATH IS THE CITATION. A match that may start partway into a path checks a
        # suffix: `missing/osquery/docs/<name>.md` was checked as `osquery/docs/<name>.md`,
        # which exists, and passed. So a match starts only where a path token starts -- never
        # after a path character, and never after `:`, which keeps a URL from being read as a
        # repository citation at all.
        #
        # It resolves from the repository root, from the citing file's directory, or -- for
        # a file inside osquery/, whose code names paths from there -- from osquery/.
        bases = [ROOT, path.parent]
        if path.relative_to(ROOT).parts[0] == "osquery":
            bases.append(ROOT / "osquery")
        for m in re.finditer(r"(?<![\w./:-])(?:[\w.-]+/)*docs/[\w.-]+\.(?:md|yaml)", text):
            if not any((base / m.group(0)).exists() for base in bases):
                n = text[:m.start()].count("\n") + 1
                bad.append(f"{path.relative_to(ROOT)}:{n}: cites {m.group(0)}, which does "
                           f"not exist. Repoint it or drop it -- a pointer to nothing "
                           f"reads as a promise the tree is making.")
    return bad


def main():
    facts = truth()
    bad = telemetry_fields() + dangling_doc_links()
    for name in DOCS:
        path = ROOT / name
        # A MISSING FILE IS A FAILURE, not a skip: queries/COST.md moved under osquery/ and a
        # `continue` here would have stopped checking it with nothing going red.
        if not path.exists():
            bad.append(f"{name}: listed in DOCS and does not exist, so its numbers go unchecked")
            continue
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if EXEMPT in line:
                continue
            for rx, word in PATTERNS:
                for m in rx.finditer(line):
                    got, want = int(m.group(1)), facts[word]
                    if got != want:
                        bad.append(f"{name}:{n}: says {got} {word}, the tree has {want}. "
                                   f"Fix it, or mark the line {EXEMPT} if it records a past "
                                   f"measurement or a projection.")
            if "coverage" in line.lower() or "covered" in line.lower():
                for m in COVERAGE.finditer(line):
                    pair = (int(m.group(1)), int(m.group(2)))
                    if pair != facts["coverage"] and pair[1] in (facts["identifiers"],
                                                                facts["coverage"][1]):
                        bad.append(f"{name}:{n}: says {pair[0]}/{pair[1]} covered, the tree "
                                   f"has {facts['coverage'][0]}/{facts['coverage'][1]}.")
    # README NAMES ONLY LIVE AGENTS. It used `ollama` as the example of a name the SQL never
    # matches on, months after ollama stopped being detected -- which reads to a newcomer as
    # though it still were. Other documents may name a removed entry, because explaining the
    # removal is their job; the front page's job is to describe what the catalog has.
    cat = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    # Both front pages: the repository's, and the osquery binding's, where the usage is.
    for name in ("README.md", "osquery/README.md"):
        readme = ROOT / name
        if not readme.exists():
            bad.append(f"{name}: missing, so nothing checks what it names")
            continue
        text = readme.read_text()
        for r in cat.get("removed", []) or []:
            for n, line in enumerate(text.splitlines(), 1):
                if EXEMPT in line:
                    continue
                if re.search(rf"[`\"]{re.escape(r['id'])}[`\"]", line):
                    bad.append(f"{name}:{n}: names `{r['id']}`, which was removed from the "
                               f"catalog ({r['what_it_is']}). A reader takes it as detected. "
                               f"Use a live agent, or mark the line {EXEMPT}.")

    if bad:
        print("doc-numbers: FAIL")
        for b in bad:
            print(f"  {b}")
        sys.exit(1)
    print(f"doc-numbers: ok, prose agrees with the tree "
          f"({facts['agents']} agents, {facts['identifiers']} identifiers, "
          f"{facts['coverage'][0]}/{facts['coverage'][1]} covered)")


if __name__ == "__main__":
    main()
