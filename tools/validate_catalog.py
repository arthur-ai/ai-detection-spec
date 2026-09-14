#!/usr/bin/env python3
"""Validate catalog/agents.yaml.

Runs in CI so a malformed contribution fails in seconds rather than in review.
Deliberately strict about the things that fail *silently* if wrong: a duplicate
identifier produces double findings, an unknown classification renders as a blank
pill, and an entry with no detection route at all is a catalog line that can never
match anything.
"""
import pathlib
import json
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent

# THE ROUTE VOCABULARY IS NOT WRITTEN HERE ANY MORE. It is catalog/routes.yaml, which is
# also what bin/classify, tools/agent_status.py and test/lint.sh read -- this list used
# to be one of five copies that had to agree, and `ext` was missing from another of them
# from the beginning.
def load_routes():
    return yaml.safe_load((ROOT / "catalog" / "routes.yaml").read_text())


REQUIRED = {"id", "name", "classification", "platforms"}
OPTIONAL = {"superseded"}
SUPERSEDED_REQUIRED = {"route", "value", "last_version", "last_proved", "by", "run"}


def archived_match(aid, rec):
    """Is this superseded record backed by an archived observation?

    The catalog claims; the tests verify. A superseded record is written from the run that
    stopped reproducing an identifier, and the observation it was written from moves into
    that scenario's `archived` list rather than being discarded -- so the two can be
    compared field for field, by reading a file, with no network and no git archaeology.
    """
    path = ROOT / "test" / "scenarios" / str(rec["by"]) / "observed.json"
    if not path.exists():
        return False
    for obs in json.loads(path.read_text()).get("archived", []):
        if (obs.get("agent") == aid
                and str(obs.get("route")) == str(rec["route"])
                and str(obs.get("value")) == str(rec["value"])
                and str(obs.get("run")) == str(rec["run"])
                and str(obs.get("agent_version", "")) == str(rec["last_version"])):
            return True
    return False

# A REAL INSTALL IS THE STANDARD, AND IT IS NOW THE ONLY ONE. An agent is verified when a
# VM scenario installs the actual software and asserts the classifier finds it -- the only
# evidence that survives the failure this catalog was built around: `bot.molt.mac` came
# from the vendor's own Homebrew metadata and matched nothing on any Mac.
#
# THE `unverified:` BLOCK AND ITS EVIDENCE GRADES ARE GONE. They let an agent enter on
# `vendor-documentation` -- which is, precisely and by name, the grade that produced
# bot.molt.mac -- provided the guess carried a reason and a date. The register was built to
# stop a guess hiding, and it worked: nothing ever hid in it, because nothing was ever
# written to it. It held zero entries for its entire life while remaining the one way into
# the catalog that did not require a machine to have run the software.
#
# So the exception was not managing a real tension; it was an unused door. The gate below
# is unconditional now: an agent no scenario installs does not ship. `untested:`, the
# identifier-level version of the same idea, went with it and was equally empty.
#
# What replaces it is not another register but a stricter question -- see
# docs/signature-lifecycle-v2.md. An identifier that WAS proved and can no longer be is
# superseded, and carries the observation that proved it. An identifier that was never
# proved is not a signature.


def validate_registry(reg):
    """The registry validates itself, because everything else now trusts it.

    A route with no `kind` is the failure worth naming: bin/classify inverts kind ->
    routes, so a missing kind means rows of that kind are DROPPED rather than unmatched,
    which is the `ext` bug reproduced from a typo.
    """
    errors = []
    platforms = set(reg.get("platforms") or ())
    groups = reg.get("platform_groups") or {}
    if not platforms:
        errors.append("routes.yaml: platforms must list the platform vocabulary")
    for name, members in groups.items():
        unknown = set(members) - platforms
        if unknown:
            errors.append(f"routes.yaml: platform_groups {name!r} names {sorted(unknown)}, "
                          f"which are not platforms")
    legal_platform = platforms | set(groups)
    modes = {"exact", "prefix", "exact-normalised", "home-dir", "home-prefix", "tool-dir"}
    required = {"platform", "kind", "match", "table", "min_osquery"}
    optional = {"value_pattern", "retired"}
    for name, r in (reg.get("routes") or {}).items():
        if not isinstance(r, dict):
            errors.append(f"routes.yaml: {name} must be a mapping")
            continue
        missing = required - set(r)
        if missing:
            errors.append(f"routes.yaml: {name} is missing {sorted(missing)}")
        unknown = set(r) - required - optional
        if unknown:
            errors.append(f"routes.yaml: {name} has unknown field(s) {sorted(unknown)}. "
                          f"This file carries no field that nothing reads -- see its header")
        if r.get("platform") not in legal_platform:
            errors.append(f"routes.yaml: {name} declares platform {r.get('platform')!r}; "
                          f"expected one of {sorted(legal_platform)}")
        if r.get("match") not in modes:
            errors.append(f"routes.yaml: {name} declares match {r.get('match')!r}; "
                          f"expected one of {sorted(modes)}")
        if not r.get("kind"):
            errors.append(f"routes.yaml: {name} declares no kind. bin/classify inverts "
                          f"kind -> routes, so rows of an unregistered kind are DROPPED, "
                          f"not unmatched -- invisible even under --show-unmatched.")
        pattern = r.get("value_pattern")
        if pattern is not None:
            try:
                re.compile(pattern)
            except re.error as exc:
                errors.append(f"routes.yaml: {name} value_pattern does not compile: {exc}")
    return errors


def main():
    doc = yaml.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
    reg = load_routes()
    ROUTES = set(reg["routes"])
    PLATFORMS = set(reg["platforms"])
    GROUPS = reg.get("platform_groups", {})
    # A route's declared platform to the concrete platforms it covers: `posix` is both.
    route_platforms = {n: set(GROUPS.get(r["platform"], [r["platform"]]))
                       for n, r in reg["routes"].items()}
    # Routes whose value is a `~/`-rooted path, derived rather than the hand-written
    # ("state_dirs", "binaries", "model_stores") tuple this file used to carry -- the
    # same tuple that also sat in bin/classify and tools/agent_status.py.
    PATH_ROUTES = [n for n, r in reg["routes"].items() if r["match"].startswith("home-")]
    known = set(doc["classifications"])

    errors_registry = validate_registry(reg)

    # not_agents names classifications, so a typo here would silently count an agent as a
    # supporting tool or the reverse -- a wrong headline number with nothing to notice it.
    unknown_na = set(doc.get("not_agents", ())) - known
    errors = []
    if unknown_na:
        errors.append(f"not_agents names {sorted(unknown_na)}, which are not "
                      f"classifications")
    errors.extend(errors_registry)
    seen_ids, seen_route_values = set(), {}

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

        unknown = set(agent) - REQUIRED - ROUTES - OPTIONAL
        if unknown:
            errors.append(f"{aid}: unknown field(s) {sorted(unknown)}")

        routes = ROUTES & set(agent)
        if not routes:
            errors.append(f"{aid}: no detection route, so it can never match anything")

        # The same identifier claimed by two agents means one of them is wrong, and
        # both will fire. RETIRED routes are excluded, and `ports` is the only one:
        # 8080 is legitimately shared, and a value two agents may both hold is not an
        # identifier -- that exemption was the admission the route had to go. Derived
        # from routes.yaml's `retired` flag now, so the exemption cannot outlive it.
        retired_routes = {n for n, r in reg["routes"].items() if r.get("retired")}
        for route in routes - retired_routes:
            for value in agent[route]:
                key = (route, str(value))
                if key in seen_route_values:
                    errors.append(
                        f"{aid}: {route} {value!r} already claimed by "
                        f"{seen_route_values[key]}")
                seen_route_values[key] = aid

        # An image value must be a repository, never a tag. `ollama/ollama:latest` in the
        # catalog would normalise to `ollama/ollama` on the row side and never match, and
        # it would fail silently -- the agent simply stops being found. Rejected here
        # rather than discovered on a fleet.
        for value in agent.get("images", []):
            tail = str(value).rsplit("/", 1)[-1]
            if ":" in tail:
                errors.append(f"{aid}: images {value!r} carries a tag. Use the repository "
                              f"alone; the matcher strips the tag from the row side.")
            if str(value) != str(value).lower():
                errors.append(f"{aid}: images {value!r} must be lowercase; a registry "
                              f"rejects uppercase in a repository name.")

        # A SUPERSEDED RECORD MUST BE BACKED BY AN ARCHIVED OBSERVATION. This replaces a
        # flat `retired:` list of strings, which exempted every value it named from the
        # coverage gate and asked for nothing in return -- which is how `bot.molt.mac` and
        # `bot.molt.` sat excluded from the badge for months while naming a release that
        # was never published.
        #
        # Four things are checked, and the last is the one that matters: the route must
        # exist, the value must still be ON that route (leaving it there is what keeps the
        # matcher matching it), the date must be a date, and `by`/`run`/`last_version` must
        # line up with a record in that scenario's observed.json `archived` list. Without
        # the last check the record is a guess wearing provenance-shaped fields, which is
        # worse than a guess because it reads as evidence.
        for rec in agent.get("superseded", []) or []:
            if not isinstance(rec, dict):
                errors.append(f"{aid}: superseded entries must be mappings, not bare "
                              f"values -- a string cannot say which run proved it")
                continue
            missing = SUPERSEDED_REQUIRED - set(rec)
            if missing:
                errors.append(f"{aid}: superseded {rec.get('value')!r} missing "
                              f"{sorted(missing)}")
                continue
            route, value = str(rec["route"]), str(rec["value"])
            if route not in ROUTES:
                errors.append(f"{aid}: superseded names route {route!r}, which is not in "
                              f"catalog/routes.yaml")
                continue
            if value not in {str(v) for v in agent.get(route, [])}:
                errors.append(
                    f"{aid}: superseded {route}:{value!r} is not on that route's list. A "
                    f"superseded value STAYS on its route -- that is what keeps it matched "
                    f"on the machines it exists for. Supersession marks it, never moves it.")
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(rec["last_proved"])):
                errors.append(f"{aid}: superseded {value!r} last_proved must be YYYY-MM-DD")
            if not archived_match(aid, rec):
                errors.append(
                    f"{aid}: superseded {route}:{value!r} cites {rec['by']} run "
                    f"{rec['run']}, and no archived observation there matches it. The "
                    f"record is written from a run that stopped producing the identifier; "
                    f"one nothing produced is a guess with a date on it.")

        # PER-ROUTE VALUE SHAPES COME FROM THE REGISTRY, not from a branch per route
        # here. The Chrome extension-id rule (32 characters from a-p: a base16 encoding
        # of the first half of a SHA-256 over the developer's public key, remapped onto
        # letters) used to be one such branch, so a hex-looking id or one of the wrong
        # length was caught only because someone had written that branch. A new route
        # now arrives carrying its own `value_pattern` instead of needing one.
        for route in ROUTES & set(agent):
            pattern = reg["routes"][route].get("value_pattern")
            if not pattern:
                continue
            for value in agent[route]:
                if not re.fullmatch(pattern, str(value)):
                    errors.append(
                        f"{aid}: {route} {value!r} does not match the shape "
                        f"{pattern} that routes.yaml declares for this route. Read the "
                        f"identifier off a real install rather than transcribing it.")

        # Paths are written with ~ so nothing user-specific is implied, and so the
        # matcher expands them consistently. THIS IS A CORRECTNESS DEPENDENCY, not a
        # style rule: bin/classify's home_pattern() strips exactly two leading
        # characters, so a value without the prefix silently loses two of its own.
        for route in PATH_ROUTES:
            for value in agent.get(route, []):
                if not str(value).startswith("~/"):
                    errors.append(f"{aid}: {route} {value!r} should start with '~/'")

        # --- platforms -------------------------------------------------------------
        #
        # REQUIRED, not optional. On a multi-OS catalog an absent list is ambiguous
        # between "macOS only" and "nobody said", and those are different claims.
        declared = agent.get("platforms") or []
        if not isinstance(declared, list) or not declared:
            errors.append(f"{aid}: platforms must be a non-empty list, e.g. [darwin]")
        else:
            unknown_p = set(map(str, declared)) - PLATFORMS
            if unknown_p:
                errors.append(f"{aid}: platforms names {sorted(unknown_p)}, which are not "
                              f"in routes.yaml's vocabulary {sorted(PLATFORMS)}")
            # A route this agent declares must be able to fire on a platform it claims.
            # `deb_packages` without `linux` is a copy-paste, and it reads as coverage.
            for route in sorted(ROUTES & set(agent)):
                if not route_platforms[route] & set(map(str, declared)):
                    errors.append(
                        f"{aid}: declares {route}, which only exists on "
                        f"{sorted(route_platforms[route])}, but platforms says "
                        f"{sorted(declared)}")
            # ...and the converse: a platform with no route that can match there is a
            # claim nothing can support. That is a DETECTION GAP, and this repo already
            # has a place for those -- docs/blind-spots.yaml, which renders onto the
            # generated page. Record it there rather than exempting it here.
            for plat in sorted(set(map(str, declared)) & PLATFORMS):
                if not any(plat in route_platforms[r] for r in ROUTES & set(agent)):
                    errors.append(
                        f"{aid}: claims platform {plat!r} but declares no route that can "
                        f"match there, so nothing can ever find it on {plat}. Either add "
                        f"a route or drop the platform and record the gap in "
                        f"docs/blind-spots.yaml.")

        if not re.fullmatch(r"[a-z0-9-]+", str(aid)):
            errors.append(f"{aid}: id should be lowercase kebab-case")

    # THE STANDARD GATE, AND IT IS UNCONDITIONAL. Every agent is backed by a real install
    # or it does not ship. There is no longer a block that buys an exception, because the
    # one that existed was never used and its weakest grade was the one that produced
    # bot.molt.mac -- see the note at the head of this file.
    covered = set()
    for path in sorted((ROOT / "test" / "scenarios").glob("*/expected.json")):
        for aid in json.loads(path.read_text()).get("classified", {}).get("must_find", []):
            covered.add(aid)

    for agent in doc["agents"]:
        aid = agent.get("id", "<missing id>")
        if aid not in covered:
            errors.append(
                f"{aid}: NOT backed by a real install. A real install is the standard and "
                f"the only one -- add it to a VM scenario's classified.must_find. If no "
                f"scenario can install it, it is not a signature yet; say so in "
                f"docs/blind-spots.yaml rather than shipping it.")

    # Scenario expectations name catalog agents by id. Those run on dispatch and on a
    # schedule, not per pull request, so a typo'd id would sit undetected for as long as
    # nobody triggers the matrix -- and would then fail as "agent not found", which reads
    # like a broken query rather than a broken test. Check it here, where it runs in
    # seconds on every push. 'comet' instead of 'perplexity-comet' is not hypothetical.
    known = {a["id"] for a in doc["agents"]}
    root = pathlib.Path(__file__).resolve().parent.parent
    for path in sorted((root / "test" / "scenarios").glob("*/expected.json")):
        block = json.loads(path.read_text()).get("classified", {})
        for key in ("must_find", "forbid"):
            for aid in block.get(key, []):
                if aid not in known:
                    errors.append(
                        f"{path.parent.name}: classified.{key} names {aid!r}, "
                        f"which is not an id in catalog/agents.yaml")

    # test/docker_states.sh hardcodes the agents its image fixture must resolve to, and it
    # needs sudo, so it does not run in the fast loop -- a catalog change that breaks it
    # surfaces minutes later on someone's machine instead of here. Removing `litellm` did
    # exactly that. Cheap to check: the ids that suite names must still exist.
    suite = ROOT / "test" / "docker_states.sh"
    if suite.exists():
        text = suite.read_text()
        m = re.search(r"== \['([a-z0-9,'-]+)'\] else 0", text)
        if m:
            named = [x.strip("'") for x in m.group(1).split("','")]
            for aid in named:
                if aid not in known:
                    errors.append(
                        f"test/docker_states.sh expects findings {named}, but {aid!r} is "
                        f"not an id in catalog/agents.yaml. That suite needs sudo and does "
                        f"not run in the fast loop, so this would surface as a red run "
                        f"minutes later instead of here.")

    # A removed entry must not also be a live one, and must say what it is -- the table in
    # the report is rendered straight from this.
    live = {a.get("id") for a in doc["agents"]}
    for r in doc.get("removed", []) or []:
        if not {"id", "what_it_is"} <= set(r):
            errors.append(f"removed entry {r!r} needs both `id` and `what_it_is`")
        elif r["id"] in live:
            errors.append(f"{r['id']} is listed under `removed:` and is also a live agent. "
                          f"One of the two is wrong.")

    # `untested:` IS NO LONGER A KEY, and a catalog still carrying one is refused rather
    # than ignored. Silently dropping it would leave a contributor believing an excuse had
    # been recorded when nothing reads it -- which is how a register becomes decorative.
    if doc.get("untested"):
        errors.append("catalog carries `untested:`, which no longer exists. An identifier "
                      "no CI test covers is not excused by a reason any more: cover it, "
                      "supersede it if a run once proved it, or remove it.")

    if errors:
        print("catalog: FAIL")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)
    # `not_agents` is empty now that the scope is agents only. The machinery stays,
    # because the argument that produced it will be had again: something detectable and
    # AI-adjacent will be proposed, and the question will be whether it ACTS on anyone's
    # behalf. Print the split only when there is one.
    na = set(doc.get("not_agents", ()))
    n_tools = sum(1 for a in doc["agents"] if a.get("classification") in na)
    split = f" ({len(doc['agents']) - n_tools} agents, {n_tools} not)" if n_tools else ""
    print(f"catalog: ok, {len(doc['agents'])} agents{split}, "
          f"{len(seen_route_values)} identifiers, scenario references resolve")
    # No exception count, because there is no longer a way to be an exception. Every agent
    # above passed the unconditional gate, so the number could only ever have been the
    # total -- and a line reporting "19/19, 0 exceptions" every run is a scoreboard for a
    # game with one possible score.
    print("  real install: every entry, or the gate above would have failed.")


if __name__ == "__main__":
    main()
