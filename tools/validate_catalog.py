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
ROUTES = {"bundle_ids", "homebrew", "npm", "pypi", "binaries",
          "state_dirs", "launchd_prefixes", "ports", "model_stores",
          "native_messaging_hosts", "images", "extension_ids"}
REQUIRED = {"id", "name", "classification"}
OPTIONAL = {"unverified"}

# A REAL INSTALL IS THE STANDARD. An agent is verified when a VM scenario installs the
# actual software and asserts the classifier finds it -- that is the only evidence that
# survives the failure this catalog was built around: `bot.molt.mac` came from the vendor's
# own Homebrew metadata and matched nothing on any Mac.
#
# Anything less is an EXCEPTION and must say so in the tree. The gate below refuses an
# agent that is neither covered by a scenario nor carrying an `unverified` block, because
# the alternative is what we had before: verified and assumed identifiers sitting side by
# side, indistinguishable, with nothing recording which was which.
#
# The grades, weakest first. See docs/signature-lifecycle.md.
EVIDENCE = {
    # What produced bot.molt.mac. The vendor says so and nothing else does.
    "vendor-documentation",
    # The artifact resolves under this exact name from its registry -- a Homebrew cask
    # token, a published npm or PyPI package. Authoritative about the NAME, and silent
    # about what an osquery row actually renders, which is a different question.
    "registry-manifest",
    # The artifact's own metadata confirms it: an image entrypoint, a bundle Info.plist.
    "artifact-metadata",
}
UNVERIFIED_REQUIRED = {"reason", "evidence", "raised"}
UNVERIFIED_OPTIONAL = {"blocker", "belongs_in"}


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

        unknown = set(agent) - REQUIRED - ROUTES - OPTIONAL
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

        # A Chrome extension id is 32 characters drawn from a-p -- it is a base16 encoding of
        # the first half of a SHA-256 over the developer's public key, remapped onto letters.
        # So a hex-looking id, an id with a digit, or one of the wrong length was transcribed
        # rather than read off an install, and would silently match nothing.
        for value in agent.get("extension_ids", []):
            if not re.fullmatch(r"[a-p]{32}", str(value)):
                errors.append(f"{aid}: extension_ids {value!r} is not a Chrome extension id "
                              f"(32 characters, a-p only). Read it from chrome_extensions on a "
                              f"real install rather than from a Web Store URL.")

        # Paths are written with ~ so nothing user-specific is implied, and so the
        # matcher expands them consistently.
        for route in ("state_dirs", "binaries", "model_stores"):
            for value in agent.get(route, []):
                if not value.startswith("~/"):
                    errors.append(f"{aid}: {route} {value!r} should start with '~/'")

        if not re.fullmatch(r"[a-z0-9-]+", str(aid)):
            errors.append(f"{aid}: id should be lowercase kebab-case")

    # THE STANDARD GATE. Every agent is either backed by a real install or carries a
    # recorded exception. Nothing is allowed to be silently unverified.
    covered = set()
    for path in sorted((ROOT / "test" / "scenarios").glob("*/expected.json")):
        for aid in json.loads(path.read_text()).get("classified", {}).get("must_find", []):
            covered.add(aid)

    for agent in doc["agents"]:
        aid = agent.get("id", "<missing id>")
        exc = agent.get("unverified")
        if aid in covered:
            # A scenario installs it AND an exception claims it cannot be verified. One of
            # the two is out of date, and leaving both means the doc contradicts itself.
            if exc:
                errors.append(f"{aid}: has an `unverified` block but IS covered by a "
                              f"scenario. Delete the block -- it is now verified.")
            continue
        if not exc:
            errors.append(
                f"{aid}: NOT backed by a real install and carries no `unverified` block. "
                f"A real install is the standard. Either add it to a VM scenario's "
                f"classified.must_find, or record the exception:\n"
                f"      unverified:\n"
                f"        reason: <why there is no scenario yet>\n"
                f"        evidence: {'|'.join(sorted(EVIDENCE))}\n"
                f"        raised: YYYY-MM-DD")
            continue
        if not isinstance(exc, dict):
            errors.append(f"{aid}: `unverified` must be a mapping")
            continue
        missing = UNVERIFIED_REQUIRED - set(exc)
        if missing:
            errors.append(f"{aid}: `unverified` missing {sorted(missing)}")
        extra = set(exc) - UNVERIFIED_REQUIRED - UNVERIFIED_OPTIONAL
        if extra:
            errors.append(f"{aid}: `unverified` has unknown field(s) {sorted(extra)}")
        if exc.get("evidence") not in EVIDENCE:
            errors.append(f"{aid}: `unverified.evidence` is {exc.get('evidence')!r}, "
                          f"not one of {sorted(EVIDENCE)}. `real-install` is not a value "
                          f"here -- an agent with a real install does not need this block.")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(exc.get("raised", ""))):
            errors.append(f"{aid}: `unverified.raised` must be YYYY-MM-DD, so an exception "
                          f"that has sat for a year is visible as one")
        if len(str(exc.get("reason", ""))) < 20:
            errors.append(f"{aid}: `unverified.reason` is too short to be a reason. Say "
                          f"what stands between this agent and a real install.")

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

    if errors:
        print("catalog: FAIL")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)
    n_exc = sum(1 for a in doc["agents"] if a.get("unverified"))
    n_real = len(doc["agents"]) - n_exc
    print(f"catalog: ok, {len(doc['agents'])} agents, {len(seen_route_values)} identifiers, "
          f"scenario references resolve")
    print(f"  real install: {n_real}/{len(doc['agents'])} agents. "
          f"{n_exc} recorded exception(s).")


if __name__ == "__main__":
    main()
