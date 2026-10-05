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
import argparse
import collections
import json
import pathlib

# The merge key. `run` is deliberately NOT in it: two runs on the same (platform, os, arch)
# are one observation re-proved, not two, so including the run id would append a duplicate
# record every night instead of refreshing one.
KEY = ("agent", "route", "value", "platform", "os", "arch")


def _key(rec):
    return tuple(rec.get(k) for k in KEY)


def _sort_key(rec):
    return (rec["agent"], rec["route"], rec["value"],
            rec.get("platform") or "", rec.get("os") or "", rec.get("arch") or "")


def uploaded(artifacts):
    """(scenario, document) for every artifact this run uploaded.

    One reader, because the two callers must agree on what counts as an artifact: the merge
    and the reported list are read by different steps and a disagreement between them would
    show up as an identifier counted missing when its scenario simply did not run.
    """
    for d in sorted(pathlib.Path(artifacts).glob("observed-*--*")):
        f = d / "observed.json"
        if not f.is_file():
            continue
        doc = json.loads(f.read_text())
        yield doc.get("scenario") or d.name.split("--")[0].removeprefix("observed-"), doc


def merge(artifacts, scenarios):
    """Union every artifact's identifiers into the scenario files under `scenarios`.

    Returns {scenario: record count} for the files it wrote.
    """
    # THE NEWEST RUN WINS A KEY, NOT THE LAST ARTIFACT. Every upload carries verbatim copies
    # of the other runners' committed records, and artifacts arrive in name order -- so the
    # label that sorted last overwrote the other runner's fresh records with stale copies.
    # Run 37118799385: macos-14 uploaded its 14.8.9 records with that run id, and the
    # committed file kept macos-15's copies, which had none. GitHub run ids only increase,
    # so a runner's own record outranks any copy of an older one; no run ranks lowest.
    incoming = collections.defaultdict(dict)
    for scen, doc in uploaded(artifacts):
        for rec in doc.get("identifiers", []):
            k = _key(rec)
            held = incoming[scen].get(k)
            if held is None or int(rec.get("run") or 0) > int(held.get("run") or 0):
                incoming[scen][k] = rec

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

        # THE COMMITTED FILE IS THE BASE, AND AN UPLOAD REPLACES A KEY ONLY WITH A NEWER
        # RUN. This used to build `identifiers` from the uploads alone, which was the same
        # thing exactly as long as main had not moved since the run checked out -- every
        # upload carries a verbatim copy of the committed file. Once collect re-merges onto
        # the current main after a rejected push, that stops being true: a record another
        # collect committed in the meantime is absent from these uploads, or present only
        # as the older copy they were cut from, and uploads-only would erase or regress it.
        # Starting from what is committed and letting only a newer run id win a key makes
        # the merge the same files on any base, which is what re-merging relies on.
        live = {_key(r): r for r in committed.get("identifiers", [])}
        for k, r in incoming[scen].items():
            held = live.get(k)
            if held is None or int(r.get("run") or 0) >= int(held.get("run") or 0):
                live[k] = r

        # AND A RESURRECTED RECORD IS WORSE THAN A LOST ONE. record() copies every OTHER
        # (platform, os, arch) key's records verbatim into each job's upload, so a record
        # archived on the macos-15 runner is re-uploaded intact by macos-14 and the union
        # above hands it straight back to `identifiers`. The archive could never take
        # effect in CI. An archived key wins: it is the decision a maintainer committed,
        # and another runner's stale copy does not get to overturn it.
        live = {k: r for k, r in live.items() if k not in archived}

        doc = {"scenario": scen, "identifiers": sorted(live.values(), key=_sort_key)}
        if archived:
            doc["archived"] = sorted(archived.values(), key=_sort_key)
        out.write_text(json.dumps(doc, indent=2) + "\n")
        written[scen] = len(doc["identifiers"])
    return written


def seen_scenarios(artifacts):
    """Every scenario that uploaded an artifact for this run.

    NOT the same as the scenarios written: one whose directory is absent is skipped by the
    merge but still reported. The coverage gate reads this to tell PENDING from MISSING --
    a scenario that failed or exited 3 uploads nothing, and must stay pending or an
    unactionable skip reads as a missing identifier.
    """
    return {scen for scen, _ in uploaded(artifacts)}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("artifacts", nargs="?", default="/tmp/observed")
    ap.add_argument("scenarios", nargs="?", default="test/scenarios")
    ap.add_argument("--reported-out",
                    help="write the comma-separated list of scenarios that reported")
    args = ap.parse_args()
    artifacts, scenarios = args.artifacts, args.scenarios
    written = merge(artifacts, scenarios)
    if args.reported_out:
        reported = sorted(seen_scenarios(artifacts))
        pathlib.Path(args.reported_out).write_text(",".join(reported))
        print("reported:", ", ".join(reported) or "(nothing)")
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
