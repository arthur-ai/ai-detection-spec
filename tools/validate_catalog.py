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


def load_classify():
    """bin/classify as a module: the catalog version it reads and the image normaliser it
    applies are the matcher's, so the validator asks the matcher rather than copying them."""
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("classify", str(ROOT / "bin" / "classify"))
    spec = importlib.util.spec_from_loader("classify", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


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
# VM scenario installs the actual software and asserts the classifier finds it.
#
# THE `unverified:` BLOCK AND ITS EVIDENCE GRADES ARE GONE. Its weakest grade was
# `vendor-documentation` -- the one this catalog's header names as how a wrong identifier
# gets shipped -- and a guess carrying a reason and a date still entered on it. The
# register was built so a guess could not hide, and nothing ever hid in it because nothing
# was ever written to it: zero entries for its whole life, while remaining the one way in
# that did not require a machine to have run the software. An unused door is still a door.
#
# The gate below is unconditional now. `untested:`, the identifier-level version of the
# same idea, went with it and was equally empty. What replaces them is a stricter question,
# not another register -- see docs/signature-lifecycle-v2.md: an identifier that WAS proved
# and can no longer be is superseded and carries the observation that proved it; one that
# was never proved is not a signature.


# A BINDING IS HOW ONE WAY OF COLLECTING EVIDENCE FEEDS A ROUTE, and each one's fields are
# checked against that binding's own source by that binding: osquery's by
# osquery/tools/build.py, against the query frontmatter.
BINDINGS = {"osquery": {"table", "min_osquery"}}


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
    required = {"platform", "kind", "match"}
    optional = {"value_pattern", "retired", "values_from"}
    for name, r in (reg.get("routes") or {}).items():
        if not isinstance(r, dict):
            errors.append(f"routes.yaml: {name} must be a mapping")
            continue
        missing = required - set(r)
        if missing:
            errors.append(f"routes.yaml: {name} is missing {sorted(missing)}")
        unknown = set(r) - required - optional - set(BINDINGS)
        # A ROUTE NOTHING CAN COLLECT MATCHES NOTHING, and it reads as coverage. A route is
        # the neutral half -- kind, match, platform -- and a binding says how one way of
        # collecting evidence feeds it. osquery is the only binding today.
        bound = sorted(set(r) & set(BINDINGS))
        if not bound:
            errors.append(f"routes.yaml: {name} has no binding ({', '.join(sorted(BINDINGS))}), "
                          f"so nothing collects the rows it would match")
        for b in bound:
            spec = r[b]
            if not isinstance(spec, dict) or set(spec) != BINDINGS[b]:
                errors.append(f"routes.yaml: {name}.{b} must be a mapping of exactly "
                              f"{sorted(BINDINGS[b])}, got {spec!r}")
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
        # A `values_from` naming a route that does not exist indexes NOTHING, in silence:
        # build_index falls back to agent.get(<missing key>, []) and the route matches no
        # row ever. That is the failure this file exists to end, so the target is checked.
        src = r.get("values_from")
        if src is not None and src not in (reg.get("routes") or {}):
            errors.append(f"routes.yaml: {name} declares values_from {src!r}, which is "
                          f"not a route. It would index nothing, silently.")
        if src is not None and src == name:
            errors.append(f"routes.yaml: {name} declares values_from itself; drop the "
                          f"field, a route reads its own key by default")
        pattern = r.get("value_pattern")
        if pattern is not None:
            try:
                re.compile(pattern)
            except re.error as exc:
                errors.append(f"routes.yaml: {name} value_pattern does not compile: {exc}")
    return errors


# THE TOP LEVEL IS CLOSED, as an agent's fields are. `untested:` was refused by name and
# `unverified:`, the register it replaced, was not: a block of guesses written under it
# passed, and nothing reads it. These are the keys some tool reads; anything else is a
# record no code can disagree with.
TOP_LEVEL = {"version", "agents", "removed", "classifications", "not_agents"}


def top_level_errors(doc):
    errors = []
    # `untested:` IS NO LONGER A KEY, and a catalog still carrying one is refused rather
    # than ignored -- by PRESENCE, because an empty `untested:` is the key all the same.
    # Silently dropping it would leave a contributor believing an excuse had been recorded
    # when nothing reads it, which is how a register becomes decorative.
    if "untested" in doc:
        errors.append("catalog carries `untested:`, which no longer exists. An identifier "
                      "no CI test covers is not excused by a reason any more: cover it, "
                      "supersede it if a run once proved it, or remove it.")
    unknown = sorted(set(doc) - TOP_LEVEL - {"untested"})
    if unknown:
        errors.append(f"catalog has top-level key(s) {unknown} that nothing "
                      f"reads, so nothing can check them. Put the fact where a tool reads "
                      f"it -- an unproved identifier goes nowhere -- or leave it out.")
    return errors


def borrowed_route_errors(aid, agent, reg):
    """A `values_from` route indexes ANOTHER route's values and never reads its own key, so
    a value an agent lists under it matches nothing, in silence. Say where it belongs.

    By PRESENCE, as top_level_errors() refuses `untested:`: an empty list is the key all the
    same, and accepting it tells the next contributor the route is declared here."""
    errors = []
    for route in sorted(set(agent) & set(reg.get("routes") or {})):
        src = reg["routes"][route].get("values_from")
        if src:
            errors.append(f"{aid}: `{route}` takes its values from `{src}` and reads none of "
                          f"its own, so nothing reads it here. List the values under `{src}`.")
    return errors


def route_value_errors(aid, agent, reg):
    """A route's values are a non-empty list of strings, and a retired route holds none.

    A bare string is iterated a character at a time -- `npm: openclaw` would index `o`,
    `p`, `e`... -- and an empty list declares a route that claims nothing. A retired route
    identifies nothing by definition; a value under it is a signature that cannot fire."""
    errors = []
    for route in sorted(set(agent) & set(reg["routes"])):
        values = agent[route]
        if (not isinstance(values, list) or not values
                or not all(isinstance(v, str) for v in values)):
            errors.append(f"{aid}: {route} must be a non-empty list of strings, got "
                          f"{values!r}")
        if reg["routes"][route].get("retired"):
            errors.append(f"{aid}: {route} is retired and identifies nothing, so it may "
                          f"carry no values")
    return errors


def image_errors(aid, agent, image_repo):
    """An `images` value is written as bin/classify normalises it. Two spellings of one
    repository -- `docker.io/x/y` and `x/y` -- pass every other check, collide after
    normalising, and the index keeps whichever agent comes last."""
    return [f"{aid}: images {v!r} normalises to {image_repo(str(v))!r}; write that"
            for v in agent.get("images", []) if image_repo(str(v)) != str(v)]


def claims(mode, p, q):
    """Does every row the value `q` can match also match `p`, under `p`'s mode?
    The modes are bin/classify's home_pattern() and prefix rule, read as containment."""
    if mode == "prefix":
        return q.startswith(p)
    if mode == "home-prefix":
        return q.rstrip("/") == p.rstrip("/") or q.startswith(p if p.endswith("/") else p + "/")
    if mode == "home-dir":
        return q.rstrip("/") == p.rstrip("/")
    return False


def overlap_errors(agents, reg):
    """NO VALUE CLAIMS ANOTHER AGENT'S ROWS on the same kind. The matcher takes the first
    hit in catalog order, so an overlap would be settled by where an entry sits in the file
    -- `binaries: ~/.local/bin/kiro` would take kiro-cli's binary. With none allowed, a row
    satisfies at most one agent and order decides nothing."""
    entries = []
    for agent in agents:
        for name, r in reg["routes"].items():
            if r.get("retired"):
                continue
            for v in agent.get(r.get("values_from", name), []) or []:
                entries.append((r["kind"], r["match"], agent.get("id"), name, str(v)))
    errors = []
    for kind, mode, aid, route, p in entries:
        for kind2, _, aid2, route2, q in entries:
            if kind2 == kind and aid2 != aid and claims(mode, p, q):
                errors.append(f"{aid}: {route} {p!r} ({mode}) also matches {aid2}'s "
                              f"{route2} {q!r}, so catalog order would decide the row")
    return errors


def live_observations(root):
    """(agent, route, value) -> where a current run still produces it."""
    live = {}
    for path in sorted((root / "test" / "scenarios").glob("*/observed.json")):
        for o in json.loads(path.read_text()).get("identifiers", []):
            key = (o.get("agent"), str(o.get("route")), str(o.get("value")))
            live.setdefault(key, set()).add(path.parent.name)
    return live


def live_superseded_errors(aid, agent, live):
    """A superseded value is one the release CI installs no longer produces. One a run
    still produces is current, and marking it superseded would label live evidence as an
    earlier release's."""
    errors = []
    for rec in agent.get("superseded", []) or []:
        if not isinstance(rec, dict):
            continue
        where = live.get((aid, str(rec.get("route")), str(rec.get("value"))))
        if where:
            errors.append(f"{aid}: superseded {rec.get('route')}:{rec.get('value')!r} is still "
                          f"observed by {', '.join(sorted(where))}, so it is current")
    return errors


def version_errors(doc, catalog_version):
    """This catalog and this matcher ship together, so they agree on the version exactly.
    bin/classify only warns on a newer catalog, which is right for a consumer pairing a
    new catalog with an old matcher and wrong for the tree that writes both."""
    if doc.get("version") != catalog_version:
        return [f"catalog version is {doc.get('version')!r} and bin/classify reads version "
                f"{catalog_version}; bump them together"]
    return []


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
    classify = load_classify()
    live = live_observations(ROOT)

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
        errors.extend(borrowed_route_errors(aid, agent, reg))
        errors.extend(route_value_errors(aid, agent, reg))
        errors.extend(image_errors(aid, agent, classify.image_repo))
        errors.extend(live_superseded_errors(aid, agent, live))

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
        # coverage gate and asked for nothing in return.
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
    # one that existed was never used -- see the note at the head of this file.
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

    # A removed entry must not also be a live one, and must say what it is -- the table in
    # the report is rendered straight from this.
    live = {a.get("id") for a in doc["agents"]}
    for r in doc.get("removed", []) or []:
        if not {"id", "what_it_is"} <= set(r):
            errors.append(f"removed entry {r!r} needs both `id` and `what_it_is`")
        elif r["id"] in live:
            errors.append(f"{r['id']} is listed under `removed:` and is also a live agent. "
                          f"One of the two is wrong.")

    errors.extend(top_level_errors(doc))
    errors.extend(version_errors(doc, classify.CATALOG_VERSION))
    errors.extend(overlap_errors(doc["agents"], reg))

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
