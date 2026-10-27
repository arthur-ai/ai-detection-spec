"""The one reader of test/scenarios/*/observed.json.

tools/agent_status.py counts coverage from it, tools/export.py publishes proof from it, and
tools/validate_catalog.py checks superseded records against it. Three readers keyed three
ways would come to disagree about whether an identifier is still live. It imports nothing
from the catalog, so validate_catalog can read through it before it knows routes.yaml parses.
"""
import collections
import json
import pathlib

SCENARIOS = pathlib.Path(__file__).resolve().parent.parent / "test" / "scenarios"


def provable(rec):
    """Can this observation be published as proof (SPEC.md 7.2)? It needs the run that
    produced it and the platform it ran on. A local `--record` names no run. Coverage counts
    only these too, so an identifier is never covered by CI and refused by --strict."""
    return bool(rec.get("run") and rec.get("platform"))


def read(scenarios=SCENARIOS):
    """(live, archived): every observation keyed (agent, route, value), each carrying its
    scenario. `archived` holds the observations of superseded values.

    The scenario is the directory, not the file's own field. The platform is the record's
    own and is never filled in from the scenario: every runner records it, so one without it
    is not provable, rather than proof credited to whatever the scenario declares now."""
    scenarios = pathlib.Path(scenarios)
    live, archived = collections.defaultdict(list), collections.defaultdict(list)
    for path in sorted(scenarios.glob("*/observed.json")):
        doc, scenario = json.loads(path.read_text()), path.parent.name
        for bucket, key in ((live, "identifiers"), (archived, "archived")):
            for rec in doc.get(key, []):
                full = {**rec, "scenario": scenario}
                bucket[(rec["agent"], rec["route"], str(rec["value"]))].append(full)
    return live, archived
