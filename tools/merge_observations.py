#!/usr/bin/env python3
"""Merge one run's uploaded observations into each scenario's committed observed.json.

    python3 tools/merge_observations.py /tmp/observed

EXTRACTED FROM A YAML HEREDOC, and that is the whole reason this file exists. It ran as
inline Python inside .github/workflows/scenarios.yml, where tools/check_workflows.py sees a
string and no test can reach it -- so its behaviour was asserted nowhere and only observable
on main, after a full matrix run. It is the one piece of this pipeline that decides what the
committed record says, which makes "untestable" the wrong property for it to have.

MERGE, NOT COPY. There is one artifact per (scenario, OS), and both describe the same
observed.json. Copying meant whichever landed last decided what the scenario had ever
proved, and the other platform's evidence vanished -- the exact thing the OS axis exists to
make visible.

THE KEY AND THE SORT MUST MATCH record() EXACTLY. That function writes these files locally
and this one writes them in CI, so a different ordering means the committed file and a local
`--record` run disagree about a file neither of them changed. Two records could not collide
on the key today, because `os` holds "14.8.7" against "24.04", but that is a coincidence of
version numbering rather than a property worth relying on.
"""
import collections
import json
import pathlib
import sys

# The merge key. `run` is deliberately NOT in it: two runs on the same (platform, os, arch)
# are one observation re-proved, not two, so including the run id would append a duplicate
# record every night instead of refreshing one.
KEY = ("agent", "route", "value", "platform", "os", "arch")


def _key(rec):
    return tuple(rec.get(k) for k in KEY)


def _sort_key(rec):
    return (rec["agent"], rec["route"], rec["value"],
            rec.get("platform") or "", rec.get("os") or "", rec.get("arch") or "")


def merge(artifacts, scenarios):
    """Union every artifact's identifiers into the scenario files under `scenarios`.

    Returns {scenario: record count} for the files it wrote.
    """
    incoming = collections.defaultdict(dict)
    for d in sorted(pathlib.Path(artifacts).glob("observed-*--*")):
        f = d / "observed.json"
        if not f.is_file():
            continue
        doc = json.loads(f.read_text())
        scen = doc.get("scenario") or d.name.split("--")[0].removeprefix("observed-")
        for rec in doc.get("identifiers", []):
            incoming[scen][_key(rec)] = rec

    written = {}
    for scen, recs in sorted(incoming.items()):
        out = pathlib.Path(scenarios) / scen / "observed.json"
        if not out.parent.is_dir():
            continue

        # THE ARCHIVE IS CARRIED THROUGH, AND WOULD OTHERWISE BE ERASED EVERY RUN. This
        # rebuilt the document from scratch as {"scenario", "identifiers"}, so an
        # `archived` list -- the evidence a superseded catalog record cites -- survived
        # exactly until the next main run. Nothing would have reported that: the catalog
        # entry stays, the gate stays green, and the record it points at is simply gone.
        committed = json.loads(out.read_text()) if out.exists() else {}
        archived = {_key(r): r for r in committed.get("archived", [])}

        # AND A RESURRECTED RECORD IS WORSE THAN A LOST ONE. record() copies every OTHER
        # (platform, os, arch) key's records verbatim into each job's upload, so a record
        # archived on the macos-15 runner is re-uploaded intact by macos-14 and the union
        # above hands it straight back to `identifiers`. The archive could never take
        # effect in CI. An archived key wins: it is the decision a maintainer committed,
        # and another runner's stale copy does not get to overturn it.
        live = {k: r for k, r in incoming[scen].items() if k not in archived}

        doc = {"scenario": scen, "identifiers": sorted(live.values(), key=_sort_key)}
        if archived:
            doc["archived"] = sorted(archived.values(), key=_sort_key)
        out.write_text(json.dumps(doc, indent=2) + "\n")
        written[scen] = len(doc["identifiers"])
    return written


def main():
    artifacts = sys.argv[1] if len(sys.argv) > 1 else "/tmp/observed"
    scenarios = sys.argv[2] if len(sys.argv) > 2 else "test/scenarios"
    written = merge(artifacts, scenarios)
    for scen, n in sorted(written.items()):
        doc = json.loads((pathlib.Path(scenarios) / scen / "observed.json").read_text())
        plats = sorted({f"{r.get('platform') or '?'}/{r.get('os') or '?'}"
                        for r in doc["identifiers"]})
        kept = f", {len(doc['archived'])} archived" if doc.get("archived") else ""
        print(f"  {scen}: {n} records across {plats or ['(none recorded)']}{kept}")
    if not written:
        print("  no observations to merge")


if __name__ == "__main__":
    main()
