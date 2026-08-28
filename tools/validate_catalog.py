#!/usr/bin/env python3
"""Validate catalog/agents.yaml.

Runs in CI so a malformed contribution fails in seconds rather than in review.
Deliberately strict about the things that fail *silently* if wrong: a duplicate
identifier produces double findings, an unknown classification renders as a blank
pill, and an entry with no detection route at all is a catalog line that can never
match anything.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROUTES = {"bundle_ids", "homebrew", "npm", "pypi", "binaries",
          "state_dirs", "launchd_prefixes", "ports", "model_stores",
          "native_messaging_hosts"}
REQUIRED = {"id", "name", "classification"}


def main():
    doc = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    known = set(doc["classifications"])
    errors, seen_ids, seen_route_values = [], set(), {}

    for agent in doc["agents"]:
        aid = agent.get("id", "<missing id>")

        missing = REQUIRED - set(agent)
        if missing:
            errors.append(f"{aid}: missing {sorted(missing)}")
        if agent.get("classification") not in known:
            errors.append(f"{aid}: unknown classification {agent.get('classification')!r}")
        if aid in seen_ids:
            errors.append(f"{aid}: duplicate id, which would produce duplicate findings")
        seen_ids.add(aid)

        unknown = set(agent) - REQUIRED - ROUTES
        if unknown:
            errors.append(f"{aid}: unknown field(s) {sorted(unknown)}")

        routes = ROUTES & set(agent)
        if not routes:
            errors.append(f"{aid}: no detection route, so it can never match anything")

        # The same identifier claimed by two agents means one of them is wrong, and
        # both will fire. Ports are excluded: 8080 is legitimately shared.
        for route in routes - {"ports"}:
            for value in agent[route]:
                key = (route, str(value))
                if key in seen_route_values:
                    errors.append(
                        f"{aid}: {route} {value!r} already claimed by "
                        f"{seen_route_values[key]}")
                seen_route_values[key] = aid

        # Paths are written with ~ so nothing user-specific is implied, and so the
        # matcher expands them consistently.
        for route in ("state_dirs", "binaries", "model_stores"):
            for value in agent.get(route, []):
                if not value.startswith("~/"):
                    errors.append(f"{aid}: {route} {value!r} should start with '~/'")

        if not re.fullmatch(r"[a-z0-9-]+", str(aid)):
            errors.append(f"{aid}: id should be lowercase kebab-case")

    if errors:
        print("catalog: FAIL")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)
    print(f"catalog: ok, {len(doc['agents'])} agents, {len(seen_route_values)} identifiers")


if __name__ == "__main__":
    main()
