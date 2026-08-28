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

# --- PyPI agents installed through pipx or uv -----------------------------------
# The endpoint cannot query python_packages (15.6s, no WHERE push-down), so it globs
# the tool directories instead and those rows arrive as kind 'file'. Before D20 nothing
# checked what the classifier did with them, and the answer was nothing: aider installs
# as 'aider-chat' under uv while its state_dir is ~/.aider, so evidence and signature
# never met. 25-python-agents asserted row counts, which were correct the whole time.
check("a uv tool directory resolves by package name (aider-chat -> aider)",
      "aider" in found,
      "the tool dir names the package, which is the only identifier in the path")
check("a pipx venv directory resolves the same way (litellm)", "litellm" in found)
check("a non-AI tool in the same directory is NOT claimed",
      not any("ruff" in json.dumps(f) for f in r["findings"]),
      "ruff installs through uv like anything else; matching the location must not "
      "mean matching everything in it")
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
