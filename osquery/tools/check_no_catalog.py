#!/usr/bin/env python3
"""Fail if a catalog-shaped literal reappears in the queries.

The queries enumerate; the matcher classifies. That boundary is easy to state and
easy to erode: the tempting fix for a noisy result is always one more `AND name NOT
IN (...)`, and each one silently moves catalog matching back onto the device, where
being wrong means every Mac stays wrong until it is redeployed.

Comments are exempt. Explaining which identifier was wrong and why is the most useful
thing in these files; the rule is about what the SQL *matches on*.
"""
import pathlib
import re
import sys

# Stock-macOS exclusions. These name the PLATFORM VENDOR to drop its own noise, which is
# the opposite of selecting an AI product, and each is load-bearing:
#   com.apple.%                    -> 937 launchd jobs down to 47
#   com.apple.passwordmanager.json -> the iCloud Passwords bridge every Mac ships, which
#                                     otherwise reports two phantom findings fleet-wide
# Adding to this list means arguing the same case again. It is not a general escape hatch.
#
# org.opencontainers.image.source is the third entry, and it is a DIFFERENT KIND of thing
# from the two above -- it names a FIELD, not a product, and the case is worth writing out
# because the reverse-DNS shape makes it look exactly like what this file exists to catch.
#
#   * It is a key from the OCI image specification, the same category of string as the
#     column name `bundle_identifier`. queries/apps.sql selects that column without naming
#     a single bundle; queries/containers.sql selects this label without naming a single
#     agent. The OCI publishes no AI product and this namespace cannot come to hold one.
#   * IT CHANGES NO MATCHING DECISION. The agents are still in catalog/agents.yaml, under
#     `image_labels:`, and the endpoint still enumerates every image's source label whether
#     or not anything claims it -- the unmatched ones reach the reader as unmatched. A
#     wrong catalog entry is still fixed off the machine, which is the whole point of enumerating.
#   * The alternative is emitting EVERY label key: measured 2026-09-11, that is 30 rows for
#     one langflow image, and it would put `title=wolfi-base` and `ref.name=ubuntu` --
#     values inherited from base images -- in front of a matcher as if they identified
#     anything. Selecting the one key that survived that measurement is narrowing the
#     payload, not narrowing the catalog.
ALLOWED = {"com.apple.%", "com.apple.passwordmanager.json",
           "org.opencontainers.image.source"}

# Vendors and products seen in earlier revisions of these files, plus the ecosystem names
# a future contributor is most likely to reach for.
VENDORS = re.compile(
    r"anthropic|openai|claude|openclaw|moltbot|clawdbot|ollama|cursor|codex|perplexity"
    r"|comet|windsurf|copilot|gemini|aider|litellm|langchain|langgraph|crewai|autogen"
    r"|lmstudio|elementlabs|todesktop|exafunction|kagi|cline|llama|mistral|huggingface"
    r"|modelcontextprotocol|openinterpreter|open-interpreter|jan\.ai|vercel|replit",
    re.I,
)
REVERSE_DNS = re.compile(r"^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*){2,}", re.I)
NPM_SCOPE = re.compile(r"^@[a-z0-9][a-z0-9-]*/", re.I)


def strip_comments(sql):
    """Drop -- comments. Keeps line count so the report can point at a line."""
    return "\n".join(re.sub(r"--.*$", "", line) for line in sql.splitlines())


def offenders(path):
    text = strip_comments(path.read_text())
    for lineno, line in enumerate(text.splitlines(), 1):
        for lit in re.findall(r"'([^']*)'", line):
            if lit in ALLOWED or not lit.strip():
                continue
            why = None
            if NPM_SCOPE.match(lit):
                why = "npm vendor scope"
            elif VENDORS.search(lit):
                why = "names a vendor or product"
            elif REVERSE_DNS.match(lit) and "/" not in lit:
                why = "reverse-DNS bundle identifier"
            if why:
                yield lineno, lit, why


def rendered_names(root):
    """The files tools/render_match.py owns: the ONE place identifiers belong in SQL.

    Read from that tool rather than listed here, so the exception is by NAME and tracks
    the generator -- a stray `dist/stray.sql` carrying a vendor literal is still an
    offender, and a rendered file renamed there is still exempt here.
    """
    sys.path.insert(0, str(root / "tools"))
    import render_match
    return set(render_match.OUTPUTS)


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    rendered = rendered_names(root)
    # EVERY artifact in dist/, discovered rather than named, MINUS the rendered set by
    # name. The rendered match files are the catalog written out as SQL on purpose; this
    # rule is about the enumeration, which must stay free of it. A hardcoded filename
    # would have quietly stopped checking the moment the name changed -- leaving the
    # rule enforced on the source and not on what ships.
    targets = (sorted((root / "queries").glob("*.sql"))
               + [p for p in sorted((root / "dist").glob("*"))
                  if p.suffix in (".sql", ".yml", ".yaml") and p.name not in rendered])
    failed = False
    for path in targets:
        if not path.exists():
            continue
        for lineno, lit, why in offenders(path):
            rel = path.relative_to(root.parent)
            print(f"FAIL: {rel}:{lineno} matches on '{lit}' -- {why}.")
            failed = True
    if failed:
        print()
        print("The queries enumerate; the matcher classifies. Matching on a product")
        print("identifier here means a wrong entry stays wrong on every Mac until it rescans.")
        print("Move the identifier to catalog/agents.yaml, which the matcher reads.")
        return 1
    # THE INVERSE, for the rendered files: each must carry identifiers, because one that
    # carries none is a signature table nobody rendered -- the same silence as a route
    # with no producer, wearing a generated banner. Missing is fine here (the drift gate
    # is tools/render_match.py --check); present and empty is not.
    for name in sorted(rendered):
        path = root / "dist" / name
        if path.exists() and not any(offenders(path)):
            print(f"FAIL: osquery/dist/{name} is a rendered match file and names no "
                  f"product. Either the render produced no signatures or the file is not "
                  f"what osquery/tools/render_match.py writes.")
            failed = True
    if failed:
        return 1
    print(f"no-catalog: ok, {len(targets)} files match on no product identifier; "
          f"{len(rendered)} rendered files do, by name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
