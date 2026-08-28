#!/usr/bin/env python3
"""Regression tests for bin/classify.

Assertions are on which agents are found and which rows are deliberately NOT claimed.
The second half matters as much: a signature that over-matches produces confident
wrong findings across a fleet, and nothing errors.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "test" / "fixtures"
failures = []


def run(fixture):
    out = subprocess.run(
        [sys.executable, str(ROOT / "bin" / "classify"), str(FIXTURES / fixture), "--json",
         "--show-unmatched"],
        capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def check(label, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'}  {label}{'' if condition else '  ' + detail}")
    if not condition:
        failures.append(label)


# --- a machine with real agents on it -------------------------------------------
r = run("known-agents.json")
found = {f["id"]: f for f in r["findings"]}

check("finds OpenClaw", "openclaw" in found)
check("finds it across all four of its routes",
      len(found.get("openclaw", {}).get("evidence", [])) == 4,
      f"got {len(found.get('openclaw', {}).get('evidence', []))}")
check("the retired bot.molt.mac alias still resolves to OpenClaw",
      any(e["id"] == "bot.molt.mac" for e in found.get("openclaw", {}).get("evidence", [])))
check("finds Ollama as formula, cask and listening port",
      len(found.get("ollama", {}).get("evidence", [])) == 3,
      "port 11434 counts because the process holding it is ollama")
check("a wildcard npm scope matches (@modelcontextprotocol/sdk)", "mcp-sdk" in found)
check("carries the display name", found.get("openclaw", {}).get("name") == "OpenClaw")
check("carries the classification",
      found.get("openclaw", {}).get("classification") == "Personal agent")

# The one that matters most. `mcp` is a real npm signature; `libxdmcp` is an X11
# library. A substring match would claim it, which is exactly the false positive
# that a real probe hit during design.
unmatched = {row["id"] for row in r["unmatched"]}
check("libxdmcp is NOT claimed by the 'mcp' signature", "libxdmcp" in unmatched)
check("ordinary software is left alone", {"cmake", "com.apple.Safari"} <= unmatched)

# --- a machine with none -------------------------------------------------------
r = run("no-agents.json")
check("an ordinary developer machine yields zero findings", r["findings"] == [],
      f"got {[f['id'] for f in r['findings']]}")

check("port 8080 held by java is not claimed as llama.cpp",
      not any(f["id"] == "llama-cpp" for f in r["findings"]),
      "a port alone is not a signature")

print()
if failures:
    print(f"matcher: FAIL ({len(failures)})")
    sys.exit(1)
print("matcher: PASS")
