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


def read(scenarios=SCENARIOS):
    """(live, archived): every observation keyed (agent, route, value), each carrying its
    scenario and that scenario's platform. `archived` holds the observations of superseded
    values.

    The scenario is the directory, not the file's own field. The platform comes from the
    scenario's expected.json when the record has none: the macOS runners record without
    `--platform`, and the scenario declares it anyway."""
    scenarios = pathlib.Path(scenarios)
    platform_of = {p.parent.name: json.loads(p.read_text()).get("platform")
                   for p in sorted(scenarios.glob("*/expected.json"))}
    live, archived = collections.defaultdict(list), collections.defaultdict(list)
    for path in sorted(scenarios.glob("*/observed.json")):
        doc, scenario = json.loads(path.read_text()), path.parent.name
        for bucket, key in ((live, "identifiers"), (archived, "archived")):
            for rec in doc.get(key, []):
                full = {**rec, "scenario": scenario,
                        "platform": rec.get("platform") or platform_of.get(scenario)}
                bucket[(rec["agent"], rec["route"], str(rec["value"]))].append(full)
    return live, archived
