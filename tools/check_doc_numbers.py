#!/usr/bin/env python3
"""Fail when a document states a catalog number that is no longer true.

The generated pages cannot go stale -- docs/agents.md and the README badges are rebuilt and
gated. PROSE CAN, and it did: CLAUDE.md claimed 40/40 coverage after the figure became
38/38, and docs/signature-lifecycle.md said 42 identifiers after two were removed. Both read
perfectly; neither was true; nothing checked them.

A catalog that changes often makes this the normal case rather than an accident, so the
numbers in prose are checked against the tree on every run.

NUMBERS THAT ARE NOT CLAIMS ABOUT TODAY are exempt and must say so. Two kinds occur here:
a past MEASUREMENT ("growing the catalog from 21 agents to 221 left dist/discovery.sql
byte-identical") and a hypothetical PROJECTION ("at 500 agents that is a few hundred regexes
per row"). Rewriting either would destroy the point it makes. Mark the line
<!--fixed-number--> and it is skipped -- deliberately verbose, so exempting is a decision
rather than a reflex.
"""
import json
import pathlib
import re
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ["README.md", "CLAUDE.md", "CONTRIBUTING.md",
        "docs/signature-lifecycle.md", "queries/COST.md"]
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
    covered = sum(1 for i in idents if i["state"] in ("ci-install", "ci-fixture"))
    coverable = sum(1 for i in idents if i["state"] != "alias")
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


def main():
    facts = truth()
    bad = []
    for name in DOCS:
        path = ROOT / name
        if not path.exists():
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
    readme = (ROOT / "README.md")
    if readme.exists():
        text = readme.read_text()
        for r in cat.get("removed", []) or []:
            for n, line in enumerate(text.splitlines(), 1):
                if EXEMPT in line:
                    continue
                if re.search(rf"[`\"]{re.escape(r['id'])}[`\"]", line):
                    bad.append(f"README.md:{n}: names `{r['id']}`, which was removed from the "
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
