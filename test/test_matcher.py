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


def unmatched_ids(result):
    """Ids the classifier looked at and declined. Distinct from ids it never saw."""
    return {row["id"] for row in result["unmatched"]}


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
check("an MCP SDK install is NOT an agent finding",
      not any(f["id"] == "mcp-sdk" for f in r["findings"])
      and "@modelcontextprotocol/sdk" in unmatched_ids(r),
      "the SDK is a library an agent is built with. Detecting it says a developer "
      "imported a protocol, not that anything is acting on a user's behalf")

# --- PyPI agents installed through pipx or uv -----------------------------------
# The endpoint cannot query python_packages (15.6s, no WHERE push-down), so it globs
# the tool directories instead and those rows arrive as kind 'file'. Before D20 nothing
# checked what the classifier did with them, and the answer was nothing: aider installs
# as 'aider-chat' under uv while its state_dir is ~/.aider, so evidence and signature
# never met. 25-python-agents asserted row counts, which were correct the whole time.
check("a uv tool directory resolves by package name (aider-chat -> aider)",
      "aider" in found,
      "the tool dir names the package, which is the only identifier in the path")
check("a LiteLLM install is NOT an agent finding",
      not any(f["id"] == "litellm" for f in r["findings"]),
      "an LLM gateway an agent calls THROUGH. Detecting it says traffic may be proxied")
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

# --- agent tooling is not an agent ------------------------------------------------
# `mcp` was catalogued and is not any more, and the fixture rows STAY. Deleting them would
# have removed the evidence along with the signature, leaving nothing to distinguish "we
# correctly decided this is not an agent" from "the npm route silently stopped working".
#
# Two things were also learned while checking it, and both are recorded here because they
# outlived the entry. npm's `mcp` is Mintlify's package -- no repository, unrelated to the
# protocol SDK -- while PyPI's `mcp` is the official one from "Model Context Protocol a
# Series of LF Projects". Same token, different software, different registries. And
# kind='npm' was mapped to the pypi route as well, so a PyPI signature claimed npm rows
# regardless of what the npm route said; a kind='npm' row comes from npm_packages and is a
# node package by construction, so that mapping had nothing to legitimately match.
u = unmatched_ids(r)
check("npm `mcp` is not claimed", "mcp" in u)
check("a uv tool directory named mcp is not claimed",
      not any("uv/tools/mcp" in json.dumps(f) for f in r["findings"]))

# --- browser extensions ----------------------------------------------------------
# kind='ext' was emitted by browser.sql from the beginning and consumed by nothing, so
# every extension row was DROPPED -- not unmatched, dropped, invisible even under
# --show-unmatched. No test caught it because every assertion here was about agents that
# were found, and Claude WAS found, through its native messaging bridge. The last two
# checks are the guard: they assert on rows the classifier must decline to claim, which is
# the only shape of assertion that can tell "correctly rejected" from "never looked at".
check("the Claude Chrome extension is found by its id", "claude-in-chrome" in found,
      "read off a real install; the VM cannot force-install from the Web Store")
ext_ev = found.get("claude-in-chrome", {}).get("evidence", [])
check("every profile and version carrying it is separate evidence, not a deduped row",
      len(ext_ev) == 2,
      f"got {len(ext_ev)}; one machine legitimately reports the id once per profile")

check("an ordinary extension is NOT claimed (uBlock Origin)",
      "cjpalhdlnbpafiamejdnhcphjbkeiagm" in unmatched,
      "if this is missing, ext rows are being dropped rather than declined")
check("an id one character off the real one is NOT claimed",
      "fcoeoabgfenejglbffodgkkbkcdhcgfa" in unmatched,
      "exact match on the full 32 characters, never a prefix or a substring")

# --- a machine with none -------------------------------------------------------
r = run("no-agents.json")
check("an ordinary developer machine yields zero findings", r["findings"] == [],
      f"got {[f['id'] for f in r['findings']]}")

check("port 8080 held by java is not claimed as llama.cpp",
      not any(f["id"] == "llama-cpp" for f in r["findings"]),
      "a port alone is not a signature")

# --- container images -----------------------------------------------------------
# Rows captured from a real daemon (Docker 28.4.0, 27 images, five registries), plus the
# three forms a fixture has to invent: a fully-qualified docker.io/ pull, a fork, and a
# lookalike. An image name is the one identifier here chosen by whoever ran `docker tag`
# rather than by a vendor, so over-matching is easier and matters more.
r = run("container-images.json")
found = {f["id"] for f in r["findings"]}
unmatched = {row["id"] for row in r["unmatched"]}

check("a LiteLLM image is NOT claimed as an agent",
      "litellm" not in found and "ghcr.io/berriai/litellm:main-latest" in unmatched,
      f"got {sorted(found)}; a gateway image is not an agent, and it must be visibly "
      f"declined rather than dropped")
check("the registry host is part of the identifier", "llama-cpp" in found,
      "ghcr.io/ggml-org/llama.cpp, not ggerganov and not a bare llama.cpp")
check("a docker.io/ prefix is stripped (docker.io/ollama/ollama -> ollama)",
      "ollama" in found,
      "Docker Hub is implicit in what a row reports, but a pull can name it explicitly")

# A multi-tag row is ONE row with the tags comma-joined -- measured, not assumed. THE ROW
# MUST CARRY AN AGENT ON ONE OF ITS TAGS, or the assertion is vacuous: an earlier version
# used alpine+localbuild, where neither tag is an agent, so a matcher that never split the
# field passed it just as happily. Verified by mutation.
MULTI = "ghcr.io/ggml-org/llama.cpp:probe,ghcr.io/ggml-org/llama.cpp:server"
check("a multi-tag row is split, and an agent on ANY tag is found",
      "llama-cpp" in found and MULTI not in unmatched,
      f"found {sorted(found)}; unsplit, this row matches nothing")
check("a multi-tag row of non-agents stays unmatched",
      "alpine:3.20,localbuild-probe:latest" in unmatched)

check("a fork is NOT claimed (myorg/ollama-fork)", "myorg/ollama-fork:latest" in unmatched,
      "exact on the normalised repository, never a substring")
check("a lookalike is NOT claimed (not-ollama)", "not-ollama:latest" in unmatched)
check("ordinary infrastructure images are left alone",
      {"authzed/spicedb:latest",
       "public.ecr.aws/docker/library/python:3.12.8-slim-bookworm"} <= unmatched,
      "the ECR path contains 'library/', which must NOT be stripped the way Docker Hub's is")
# A local model runs on the HOST or in a CONTAINER and both are install paths. This row
# was captured from a real docker_images row after side-loading the vendor's own image
# (lmstudio namespace, "Headless LM Studio Docker Image"); there is no lmstudio/lmstudio.
check("LM Studio's container path resolves (lmstudio/llmster-preview)",
      "lm-studio" in found,
      "the same product the 10-desktop-apps cask covers on the host")

check("exactly three agents, no more", found == {"llama-cpp", "ollama", "lm-studio"},
      f"got {sorted(found)}")

# --- scan rows: provenance, gaps, and staleness -----------------------------------
# All pure bin/classify behaviour, so it lives in the fast suite. test/docker_states.sh
# proves the daemon states that PRODUCE these rows; this proves what is done with them.
import subprocess as _sp, tempfile as _tf, time as _time


def classify_rows(rows, *extra):
    with _tf.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(rows, fh)
    out = _sp.run([sys.executable, str(ROOT / "bin" / "classify"), fh.name, *extra],
                  capture_output=True, text=True, check=True).stdout
    return out


def scan_row(extra, age=0):
    return {"kind": "scan", "id": "containers", "ver": str(int(_time.time()) - age),
            "loc": "/var/run/docker.sock", "extra": extra, "perms": ""}


r = json.loads(classify_rows([scan_row("ok")], "--json"))
check("a dated success is provenance, not a gap",
      "gaps" not in r and r.get("scans", [{}])[0].get("id") == "containers",
      f"got {r}")
check("...and is not reported stale when fresh", not r["scans"][0]["stale"])

r = json.loads(classify_rows([scan_row("ok", age=4 * 86400)], "--json"))
check("a four-day-old scan is flagged stale", r["scans"][0]["stale"],
      "a writer that stopped must not read as a current scan")
check("...and says so in the text output",
      "STALE:" in classify_rows([scan_row("ok", age=4 * 86400)]))

# Every non-ok outcome must reach the reader as a gap, with its own wording: an operator
# fixes a wedged daemon differently from a Mac that has no Docker, and differently again
# from a writer that was never installed.
for extra, needle in (("absent", "no Docker socket"),
                      ("no-cache", "never run"),
                      ("unhealthy:500", "answered 500"),
                      ("timeout:6", "stalled")):
    text = classify_rows([scan_row(extra)])
    check(f"{extra!r} reports COULD NOT LOOK, distinctly",
          "COULD NOT LOOK" in text and needle in text, f"got: {text.splitlines()[:1]}")

check("a gap is never silently an empty finding set",
      "No AI agents found." not in classify_rows([scan_row("timeout:6")]),
      "'no agents' under an unread branch is the lie this whole marker exists to stop")

print()
if failures:
    print(f"matcher: FAIL ({len(failures)})")
    sys.exit(1)
print("matcher: PASS")
