#!/usr/bin/env python3
"""When an identifier stops appearing, say what arrived in its place.

    python3 tools/successor_candidates.py /tmp/out.json --route bundle_ids
    python3 tools/successor_candidates.py /tmp/out.json --route bundle_ids --baseline base.json

A RENAME HAS TWO HALVES AND ONLY ONE WAS WATCHED. Three separate guards fire when an
identifier stops appearing -- the shrink guard, `tested-absent`, and a `must_contain`
assertion. Nothing fires when a NEW one arrives unclaimed, and a rename does both, in one
run, on one machine, in one payload. `com.openai.chat` did not merely vanish;
`com.openai.codex` arrived in its place, on the same runner, in the same JSON.

It is also mostly computed already, which is the part worth knowing: test/lib/assert.sh
runs `bin/classify --json --show-unmatched` on every scenario, there is an `unmatched_max`
assertion available, no scenario sets it, and agent_status.replay() keeps findings and
discards the unmatched list in the same call. The successor arrives on every run and is
thrown away.

WHAT THIS IS NOT. It proposes candidates; it does not identify anything. An unmatched row
is a row nothing claimed, which is not the same as a row belonging to the agent that just
lost an identifier -- a scenario installs one agent onto a machine carrying many other
things. Narrowing is not deciding, and a candidate becomes a signature the same way every
other one does: a scenario installs the software and a run produces the row.

AN EMPTY LIST IS INFORMATION. If an identifier is lost and nothing unclaimed arrives, this
was not a rename -- the route went away. An AppImage replacing a .deb leaves no package
record at all, and that reads as a lost `deb_packages` value with no successor anywhere.
"""
import argparse
import importlib.machinery
import importlib.util
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

_loader = importlib.machinery.SourceFileLoader("classify", str(ROOT / "bin" / "classify"))
_spec = importlib.util.spec_from_loader("classify", _loader)
classify_mod = importlib.util.module_from_spec(_spec)
_loader.exec_module(classify_mod)


def _rows(path):
    doc = json.loads(pathlib.Path(path).read_text())
    return doc["findings"] if isinstance(doc, dict) else doc


def unmatched(rows, catalog=None, routes=None):
    """Rows of a known kind that no signature claimed."""
    catalog = catalog if catalog is not None else classify_mod.load_catalog(
        ROOT / "catalog" / "agents.yaml")
    routes = routes if routes is not None else classify_mod.load_routes()
    return classify_mod.classify(rows, catalog, routes)[1]


def candidates(rows, kinds, baseline_rows=None, catalog=None, routes=None):
    """Unmatched rows of `kinds`, minus whatever a bare machine also shows.

    TWO NARROWINGS, AND NEITHER IS CLEVER. The kind comes from the lost value's route --
    a lost `bundle_ids` value means the successor is an `app` row, and routes.yaml already
    says so. The baseline is the noise floor: `00-baseline` installs nothing, so anything
    unmatched there is the runner's own furniture rather than something this scenario put
    on the machine. Subtracting it turns several hundred rows into a few.
    """
    mine = unmatched(rows, catalog, routes)
    out = [r for r in mine if r.get("kind") in kinds]
    if baseline_rows is not None:
        floor = {(r.get("kind"), r.get("id"))
                 for r in unmatched(baseline_rows, catalog, routes)}
        out = [r for r in out if (r.get("kind"), r.get("id")) not in floor]
    return sorted(out, key=lambda r: (r.get("kind") or "", r.get("id") or ""))


def kinds_for(routes_doc, route_names):
    """The row kinds a set of routes arrives on."""
    routes = routes_doc["routes"]
    return {routes[r]["kind"] for r in route_names if r in routes}


def render(cands, lost_desc=""):
    """One block, printed where the person triaging is already looking."""
    lines = []
    if lost_desc:
        lines.append(f"Lost: {lost_desc}")
    if not cands:
        lines.append("  No unclaimed row of that kind arrived. This is not a rename -- the "
                     "route went away, which is a different finding.")
        return "\n".join(lines)
    lines.append(f"  {len(cands)} unclaimed row(s) of that kind arrived in the same run. "
                 f"A successor, if there is one, is among them:")
    for r in cands:
        ver = f"  {r['ver']}" if r.get("ver") else ""
        lines.append(f"    {r.get('kind',''):9} {r.get('id','')}{ver}")
        if r.get("loc") and r["loc"] != r.get("id"):
            lines.append(f"              {r['loc']}")
    lines.append("  Confirm one is the renamed product before cataloguing it: an unclaimed "
                 "row is not the same as this agent's row.")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # ONE WAY TO SAY WHAT WAS LOST. A --kind flag stood beside this and was redundant:
    # the route is what you know when an identifier stops appearing, and routes.yaml maps
    # it to the kind. An "every kind" default stood here too, which returns the machine.
    ap.add_argument("payload", help="the run's osquery JSON")
    ap.add_argument("--route", action="append", required=True,
                    help="the route whose value went missing; repeatable")
    ap.add_argument("--baseline", help="a bare machine's payload, subtracted as noise")
    args = ap.parse_args()

    kinds = kinds_for(classify_mod.load_routes(), args.route)
    base = _rows(args.baseline) if args.baseline else None
    print(render(candidates(_rows(args.payload), kinds, base),
                 lost_desc=", ".join(sorted(args.route))))


if __name__ == "__main__":
    main()
