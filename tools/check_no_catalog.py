#!/usr/bin/env python3
"""Fail if a catalog-shaped literal reappears in the queries (D20).

The queries enumerate; the collector classifies. That boundary is easy to state and
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
ALLOWED = {"com.apple.%", "com.apple.passwordmanager.json"}

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


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    targets = sorted((root / "queries").glob("*.sql")) + [root / "dist" / "discovery.sql"]
    failed = False
    for path in targets:
        if not path.exists():
            continue
        for lineno, lit, why in offenders(path):
            rel = path.relative_to(root)
            print(f"FAIL: {rel}:{lineno} matches on '{lit}' -- {why}.")
            failed = True
    if failed:
        print()
        print("The queries enumerate; the collector classifies (D20). Matching on a product")
        print("identifier here means a wrong entry stays wrong on every Mac until it rescans.")
        print("Move the identifier to catalog/agents.yaml, which the collector reads.")
        return 1
    print(f"no-catalog: ok, {len(targets)} files match on no product identifier")
    return 0


if __name__ == "__main__":
    sys.exit(main())
