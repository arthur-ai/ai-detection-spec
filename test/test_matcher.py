#!/usr/bin/env python3
"""Regression tests for bin/classify.

Assertions are on which agents are found and which rows are deliberately NOT claimed.
The second half matters as much: a signature that over-matches produces confident
wrong findings across a fleet, and nothing errors.
"""
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "test" / "fixtures"
# Every classify below runs as a subprocess and inherits this. A test run is not a use;
# test/test_telemetry.py is the file that exercises the sending path deliberately.
os.environ.setdefault("AI_DISCOVERY_TELEMETRY", "0")
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
check("finds it across all three of its routes",
      len(found.get("openclaw", {}).get("evidence", [])) == 3,
      f"got {len(found.get('openclaw', {}).get('evidence', []))}")

# THE ONLY EVIDENCE THAT CAN EXIST FOR THIS ONE. com.openai.chat is what ChatGPT Desktop
# carried before the Codex rename, and no fresh install produces it any more -- every
# variation of the current cask serves one 26.x build. A real install found it exactly
# once, on the macos-14 runner of 33511815638, whose Homebrew was stale enough to still
# resolve 1.2026.160; that is not repeatable and will stop happening when the image
# updates. So the fixture row is the standing proof, and it is here to stop a tidy-up
# dropping the alias that machines in the field still depend on.
check("the retired com.openai.chat alias still resolves to ChatGPT Desktop",
      any(e["id"] == "com.openai.chat"
          for e in found.get("chatgpt-desktop", {}).get("evidence", [])))
check("com.openai.chat is NOT claimed by Codex CLI",
      not any(e["id"] == "com.openai.chat"
              for e in found.get("codex-cli", {}).get("evidence", [])),
      "one vendor prefix, two products -- the confusion this catalog documents")
check("an Ollama install is NOT an agent finding",
      "ollama" not in found,
      "a model runner serves language models; an agent is what drives one. Its rows stay "
      "in the fixture so this asserts DECLINED rather than absent")
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
# npm's `aider` is a static-site component by an unrelated maintainer, not the AI pair
# programmer -- which ships on PyPI as aider-chat and has no npm distribution. It was
# catalogued anyway, with a comment explaining the discrepancy rather than questioning it.
check("npm's `aider` is NOT claimed as the coding agent",
      "aider" in unmatched,
      "the row must arrive and be declined; absent is also what a dropped kind looks like")
check("ordinary software is left alone", {"cmake", "com.apple.Safari"} <= unmatched)

# --- one agent, three registries, and none of them agrees on the name -------------
# Hermes Agent is `hermes` on PATH, `hermes-agent` in Homebrew and `hermes-agent` on PyPI.
# Four rows, four routes, one finding: the formula token, the uv tool directory named for
# the package, the command uv writes beside it, and HERMES_HOME.
hermes_ev = found.get("hermes", {}).get("evidence", [])
check("finds Hermes Agent", "hermes" in found)
check("finds it across all four of its routes", len(hermes_ev) == 4,
      f"got {len(hermes_ev)}: {[e['id'] for e in hermes_ev]}")
check("the Homebrew row is the formula token, not the command it installs",
      any(e["kind"] == "brew" and e["id"] == "hermes-agent" for e in hermes_ev),
      "the formula writes hermes, hermes-agent and hermes-acp; homebrew_packages renders "
      "the formula name, and only an install settles which")

# THE npm-`mcp` SHAPE, AND THE REASON KIND_ROUTES MAPS npm TO npm ALONE. `hermes-agent` is a
# real name on npm and a real name on PyPI, and they are not published by the same people:
# npm's is an "Unofficial npm bridge" from a third-party maintainer, catalogued nowhere here,
# while the PyPI package's own wheel metadata reads Author: Nous Research. If the pypi route
# were reachable from a kind='npm' row -- as it was when npm's `mcp` was reported as the MCP
# SDK -- this row would be claimed on the strength of a signature written for another
# registry. It must arrive and be DECLINED, which is a different fact from never appearing.
check("npm's `hermes-agent` is NOT claimed by the PyPI signature of the same name",
      "hermes-agent" in unmatched
      and not any(e["kind"] == "npm" and e["id"] == "hermes-agent" for e in hermes_ev),
      "same token, two registries, two publishers -- exactly the npm `mcp` failure")
# React Native's JavaScript engine, on every machine that has ever built an RN app. Exact
# matching is the only thing standing between it and a confident wrong finding, and this is
# the row that proves the matching is exact -- the `libxdmcp` of this entry.
check("npm's `hermes-engine` is NOT claimed as the agent", "hermes-engine" in unmatched,
      "a JavaScript engine for React Native, and a prefix match claims it")

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

# --- JetBrains plugins -----------------------------------------------------------
# A new kind is dropped, not unmatched, until catalog/routes.yaml registers it, and lint
# does not catch that direction. The declined row is the guard, as for `ext` above.
check("Cline is found through its JetBrains plugin directory",
      any(e["kind"] == "jbplugin" and e["id"] == "cline"
          for e in found.get("cline", {}).get("evidence", [])))
check("an ordinary JetBrains plugin is NOT claimed (AWS Toolkit)",
      "aws-toolkit-jetbrains-standalone" in unmatched,
      "if this is missing, jbplugin rows are being dropped rather than declined")

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
check("the registry host is still parsed, and the image is declined",
      "llama-cpp" not in found and "ghcr.io/ggml-org/llama.cpp:server" in unmatched,
      "a model runner is out of scope, and its image must be visibly unclaimed")
# The images route now rests entirely on aider, so the normalisation rules need a live
# subject. This row was captured from a real docker_images row after side-loading the
# image, the same method the catalog header records.
check("a two-segment Docker Hub image resolves (paulgauthier/aider -> aider)",
      "aider" in found, f"got {sorted(found)}")

# A multi-tag row is ONE row with the tags comma-joined -- measured, not assumed. THE ROW
# MUST CARRY AN AGENT ON ONE OF ITS TAGS, or the assertion is vacuous: an earlier version
# used alpine+localbuild, where neither tag is an agent, so a matcher that never split the
# field passed it just as happily. Verified by mutation.
# THE AGENT IS THE SECOND TAG, deliberately. A matcher that compared the comma-joined
# field whole would miss it, and every real multi-tag row in this fixture now carries no
# catalogued agent -- so they pass whether the field is split or not, and only this row
# can fail. Synthetic, like the fork and the lookalike beside it.
check("a multi-tag row is split, and an agent on ANY tag is found",
      "aider" in found
      and "localbuild-probe:latest,paulgauthier/aider:pinned" not in unmatched,
      "unsplit, this row matches nothing")
check("a multi-tag row of non-agents stays whole and unmatched",
      "ghcr.io/ggml-org/llama.cpp:probe,ghcr.io/ggml-org/llama.cpp:server" in unmatched,
      "declined, and reported by the id the row actually carried")
check("a multi-tag row of non-agents stays unmatched",
      "alpine:3.20,localbuild-probe:latest" in unmatched)

check("a fork is NOT claimed (myorg/ollama-fork)", "myorg/ollama-fork:latest" in unmatched,
      "exact on the normalised repository, never a substring")
check("a lookalike is NOT claimed (not-ollama)", "not-ollama:latest" in unmatched)
check("the LM Studio image is out of scope too", "lm-studio" not in found)
check("ordinary infrastructure images are left alone",
      {"authzed/spicedb:latest",
       "public.ecr.aws/docker/library/python:3.12.8-slim-bookworm"} <= unmatched,
      "the ECR path contains 'library/', which must NOT be stripped the way Docker Hub's is")
# A local model runs on the HOST or in a CONTAINER and both are install paths. This row
# was captured from a real docker_images row after side-loading the vendor's own image
# (lmstudio namespace, "Headless LM Studio Docker Image"); there is no lmstudio/lmstudio.
check("exactly one agent, no more", found == {"aider"},
      f"got {sorted(found)}; every model runner and gateway in this fixture must be declined")

# --- scan rows: provenance, gaps, and staleness -----------------------------------
# All pure bin/classify behaviour, so it lives in the fast suite. osquery/test/docker_states.sh
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
# fixes a wedged daemon differently from a machine that has no Docker, and differently
# again from a writer that was never installed.
#
# `error` IS IN THIS LIST NOW, and it is the one that was missing. osquery/bin/discover emits it
# for every non-container branch that ran and failed, and the renderer had no case for
# it, so it fell through to a generic sentence that substituted "the socket" as the
# place -- naming a socket that had nothing to do with a failed `apps` query.
for extra, needle in (("no-cache", "never run"),
                      ("error", "ran and failed"),
                      ("unhealthy:500", "answered 500"),
                      ("timeout:6", "stalled"),
                      ("unreadable:podman", "podman runtime is installed")):
    text = classify_rows([scan_row(extra)])
    check(f"{extra!r} reports COULD NOT LOOK, distinctly",
          "COULD NOT LOOK" in text and needle in text, f"got: {text.splitlines()[:1]}")

# A marker whose branch writes no `loc` must not have a place invented for it. This is
# the assertion the old generic branch would have failed: `apps` never touched a socket.
_no_loc = classify_rows([{"kind": "scan", "id": "apps", "ver": str(int(_time.time())),
                          "loc": "", "extra": "error", "perms": ""}])
check("a marker with no loc names no place",
      "COULD NOT LOOK: apps" in _no_loc and "socket" not in _no_loc,
      f"got: {_no_loc.splitlines()[:1]}")

# bin/classify reads payloads a fleet collector may have merged from several hosts, so it
# is not entitled to say which platform anything is. "no Docker socket on this Mac" was
# the wording that made that claim.
for extra in ("absent", "error", "timeout:6", "unreadable:podman"):
    check(f"{extra!r} claims no platform",
          "this Mac" not in classify_rows([scan_row(extra)]),
          "a matcher over a mixed-platform payload cannot know the platform")

check("a gap is never silently an empty finding set",
      "No AI agents found." not in classify_rows([scan_row("timeout:6")]),
      "'no agents' under an unread branch is the lie this whole marker exists to stop")

# THE DISTINCTION `unreadable:` WAS ADDED FOR, asserted as a DIFFERENCE rather than as a
# string. A host running Podman and a host running no containers at all both reach this
# renderer with no Docker socket behind them; if they read the same, the state an operator
# has to act on is being reported as the one that needs nothing.
#
# WHAT IT CATCHES, checked by mutation rather than assumed: a renderer that gives the two
# reasons the same sentence -- which is what "simplifying" this band into one branch would
# do. It CANNOT see a producer that stops emitting the term, because the rows here are
# written by hand; osquery/test/docker_states.sh owns that half and fails on it.
check("a runtime we cannot read does not read as a machine with none",
      classify_rows([scan_row("unreadable:podman")]) != classify_rows([scan_row("absent")]),
      "`absent` and `unreadable:podman` rendered identically, which is the bug itself")
check("...and it is not folded into an empty finding set either",
      "No AI agents found." not in classify_rows([scan_row("unreadable:podman")]),
      "uncounted containers reported as no agents is the same lie one hop later")

# A DROPPED ROW HEDGES THE HEADLINE, and is said above it. A payload of a kind no route
# declares -- the `ext` bug -- printed an unhedged "No AI agents found." first and named the
# drop only at the foot of the report.
_drop = [{"kind": "zzz", "id": "x", "ver": "", "loc": "", "extra": "", "perms": ""}]
_dt = classify_rows(_drop)
check("a dropped row does not read as a clean machine",
      "No AI agents found." not in _dt and -1 < _dt.find("DROPPED: 1 row(s)")
      < _dt.find("No AI agents found"), _dt)
check("...and the JSON counts it", json.loads(classify_rows(_drop, "--json")).get("dropped") == 1)

# --- home roots and anchors: the two halves of one fix -----------------------------
#
# There were three hand-written copies of `/Users/[^/]+/` -- this matcher's path globs,
# its TOOL_DIR bridge, and tools/agent_status.py's replay, whose comment claimed the two
# "cannot disagree" while being a copy. They are one HOME_ROOTS alternation now, and it
# covers every platform at once because a fleet payload can carry rows from several.

def classify_json(rows, *extra):
    """classify() over an inline row list, as JSON. The sibling of classify_rows()."""
    return json.loads(subprocess.run(
        [sys.executable, str(ROOT / "bin" / "classify"), "--json", "--show-unmatched",
         *extra],
        input=json.dumps(rows), capture_output=True, text=True, check=True).stdout)


def _rows(*paths):
    return [{"kind": "file", "id": p, "ver": "", "loc": p, "extra": "", "perms": ""}
            for p in paths]

def _ids(rows):
    r = json.loads(subprocess.run(
        [sys.executable, str(ROOT / "bin" / "classify"), "--json", "--show-unmatched"],
        input=json.dumps(rows), capture_output=True, text=True, check=True).stdout)
    return {f["id"] for f in r["findings"]}

# `matches` NAMES THE IDENTIFIER BEHIND EACH EVIDENCE ROW, in evidence order and on the route
# that holds it: a container row is credited to `images`, whose values container_images
# borrows, and a uv directory to `pypi`.
_mf = classify_json([{"kind": k, "id": i, "ver": "", "loc": i if k == "file" else "",
                      "extra": "", "perms": ""}
                     for k, i in (("container", "paulgauthier/aider:latest"), ("brew", "aider"),
                                  ("file", "/home/dana/.local/share/uv/tools/aider-chat/"),
                                  ("file", "/home/dana/.aider"))])["findings"]
check("--json names the identifier behind each evidence row, on the route that holds it",
      [(f["id"], f.get("matches")) for f in _mf] == [("aider", [
          {"route": "images", "value": "paulgauthier/aider"},
          {"route": "homebrew", "value": "aider"},
          {"route": "pypi", "value": "aider-chat"},
          {"route": "state_dirs", "value": "~/.aider"}])], json.dumps(_mf)[:400])

# THE NEAR MISS. `~/.claude` was front-anchored only, so it also matched `.claudefoo` --
# and that is not hypothetical: `/home/%/.%/` on a real Linux box returns `.claude/` and
# `.claudefoo/` side by side. `home-dir` anchors both ends.
check("a state dir matches, with and without the trailing slash",
      _ids(_rows("/Users/dana/.claude/")) == {"claude-code"}
      and _ids(_rows("/home/dana/.claude")) == {"claude-code"})
for near in ("/Users/dana/.claudefoo/", "/home/dana/.claudefoo/", "/root/.claude-backup/"):
    check(f"a near miss is NOT claimed ({near})",
          _ids(_rows(near)) == set(),
          "front-anchored only, this matched -- the bug the home-dir anchor closes")

# THE OTHER HALF: `binaries` names a command, never a prefix of one. One `uv tool install
# hermes-agent` writes hermes, hermes-acp and hermes-agent, so hermes alone finds the
# install, and a prefix would claim any tool that shares the name -- `claude-monitor`, a
# third-party usage monitor installed with uv, is not Claude Code.
check("the command is claimed, wherever the home is",
      _ids(_rows("/Users/alice/.local/bin/hermes")) == {"hermes"}
      and _ids(_rows("/root/.local/bin/hermes")) == {"hermes"})
for cmd in ("/home/alice/.local/bin/hermes-acp", "/root/.local/bin/hermes-agent",
            "/home/alice/.local/bin/claude-monitor"):
    check(f"a name that merely starts with a value is not claimed ({cmd})",
          _ids(_rows(cmd)) == set(), "a prefix match claims other vendors' tools")

# PI'S LOOKALIKES, which a Python host carries for free: ~/.pipx starts with Pi's ~/.pi.
check("~/.pi is Pi and ~/.pipx is not",
      _ids(_rows("/home/dana/.pi/")) == {"pi"}
      and _ids(_rows("/home/dana/.pipx/", "/Users/dana/.pip/")) == set())
# Pi's own libraries and the unscoped placeholder share its name and are not the agent.
# Current OpenClaw depends on @earendil-works/pi-tui, and a bun global hoists it into a row.
_pi = classify_json([{"kind": "npm", "id": n, "ver": "1.0", "loc": "/x", "extra": "",
                      "perms": ""}
                     for n in ("@earendil-works/pi-coding-agent", "@earendil-works/pi-tui",
                               "@earendil-works/pi-ai", "pi-coding-agent", "pi-acp")])
check("only the coding-agent package is evidence for Pi",
      {e["id"] for f in _pi["findings"] for e in f["evidence"]}
      == {"@earendil-works/pi-coding-agent"},
      f"got {[(f['id'], [e['id'] for e in f['evidence']]) for f in _pi['findings']]}")

# Every home root, on the routes that use them, including root's -- which is not under
# /home and cannot be reached by a `[^/]+` component.
check("Linux and root home roots resolve on the path routes",
      _ids(_rows("/home/dana/.openclaw/")) == {"openclaw"}
      and _ids(_rows("/root/.codex/")) == {"codex-cli"}
      and _ids(_rows("/root/.local/bin/claude")) == {"claude-code"})

# The TOOL_DIR bridge under Linux roots. aider installs as `aider-chat` under uv while
# its state dir is `~/.aider`; without the bridge the evidence says aider and the
# classifier says nothing.
check("the pipx/uv tool-dir bridge works under every home root",
      _ids(_rows("/home/alice/.local/share/uv/tools/aider-chat/")) == {"aider"}
      and _ids(_rows("/root/.local/pipx/venvs/aider-chat/")) == {"aider"})

# A path that is NOT under any home root must not match, or the alternation is really a
# substring search.
check("a path outside every home root is not claimed",
      _ids(_rows("/opt/dana/.claude/", "/srv/home/dana/.claude/")) == set())


# --- the Linux package routes, and the lookalikes the base OS ships ----------------
#
# THE POINT: a stock Ubuntu carries `libxcursor1` and `libwayland-cursor0`, both real deb
# packages whose names contain `cursor`. This is `libxdmcp` versus `mcp` again, except it
# arrives for free on every Linux box rather than having to be constructed -- so the
# assertion is cheap and the failure it guards is common.
def _deb(*names):
    return [{"kind": "deb", "id": n, "ver": "1.0", "loc": "", "extra": "amd64",
             "perms": ""} for n in names]

_r = classify_json(_deb("cursor", "libxcursor1", "libwayland-cursor0", "bash", "coreutils"))
_found = {f["id"] for f in _r["findings"]}
check("a real deb identifier is found", _found == {"cursor"},
      f"got {sorted(_found)}")
_evidence = {e["id"] for f in _r["findings"] for e in f["evidence"]}
check("the base OS lookalikes are NOT evidence for it",
      _evidence == {"cursor"},
      "libxcursor1 and libwayland-cursor0 contain the identifier as a substring -- an "
      "exact route must decline both, and this is what tells declined from never-looked-at")
check("...and they are reported unmatched rather than dropped",
      {"libxcursor1", "libwayland-cursor0"} <= set(unmatched_ids(_r)),
      "a kind absent from the registry is DROPPED, not unmatched -- the `ext` bug")

# THE WRONG GUESS FOR KIRO, ASSERTED AS WRONG. `dev.kiro.desktop` was read off
# Kiro.app/Contents/Info.plist in the shipped dmg, but the cask's zap stanza names
# `~/Library/Preferences/dev.kiro.cli.plist` -- so `dev.kiro.cli` is the value a reader
# transcribing vendor metadata would write, and it belongs to a DIFFERENT product (Kiro
# CLI, whose app ships com.amazon.codewhisperer). This is the bot.molt.mac shape exactly,
# and the only way to keep it fixed is to assert that the wrong value does not match.
#
# The helper sub-bundle is the second half: an app bundle ships nested helpers whose ids
# extend the parent's, so `com.google.antigravity.helper.renderer` tests that bundle_ids is
# really exact and not a prefix. If it ever became a prefix route, one install would report
# as several.
def _app(*ids):
    return [{"kind": "app", "id": i, "ver": "1.0", "loc": f"/Applications/{i}.app",
             "extra": "", "perms": ""} for i in ids]

_r = classify_json(_app("dev.kiro.desktop", "dev.kiro.cli",
                        "com.google.antigravity", "com.google.antigravity.helper.renderer"))
_found = {f["id"] for f in _r["findings"]}
check("the agentic IDE forks are found by their real bundle ids",
      _found == {"kiro", "antigravity"}, f"got {sorted(_found)}")
_evidence = {e["id"] for f in _r["findings"] for e in f["evidence"]}
check("the vendor-metadata guess is NOT evidence for kiro",
      "dev.kiro.cli" not in _evidence,
      "dev.kiro.cli is the CLI's preference domain, not this app's bundle id -- if it "
      "matches, the catalog has been written from the zap stanza rather than the artifact")
check("a nested helper bundle is NOT evidence for antigravity",
      "com.google.antigravity.helper.renderer" not in _evidence,
      "bundle_ids is an exact route; as a prefix it would report one install as several")
check("...and both are reported unmatched rather than dropped",
      {"dev.kiro.cli", "com.google.antigravity.helper.renderer"} <= set(unmatched_ids(_r)),
      "a kind absent from the registry is DROPPED, not unmatched -- the `ext` bug")

# rpm carries the same value on a different route, and the two must not be confused: the
# uniqueness check is keyed on (route, value), so `cursor` is legitimately both.
_rpm = [{"kind": "rpm", "id": "cursor", "ver": "3.19.7", "loc": "",
         "extra": "Cursor", "perms": ""}]
check("the rpm route resolves the same identifier",
      {f["id"] for f in classify_json(_rpm)["findings"]} == {"cursor"})

# desktop_ids is the only route that can see an AppImage install, and one install writes
# more than one entry -- so an exact match must take the catalogued one and leave the rest.
_desk = [{"kind": "desktop", "id": n, "ver": "", "loc": f"/usr/share/applications/{n}",
          "extra": "", "perms": ""}
         for n in ("cursor.desktop", "cursor-url-handler.desktop",
                   "com.google.Chrome.desktop", "python3.12.desktop")]
_rd = classify_json(_desk)
check("a desktop entry resolves the agent",
      {f["id"] for f in _rd["findings"]} == {"cursor"})
check("a SECOND entry from the same install is not a second finding",
      {e["id"] for f in _rd["findings"] for e in f["evidence"]} == {"cursor.desktop"},
      "cursor-url-handler.desktop is one install's second file, not a second install")

# The systemd marker carries two values that are easy to read as one thing, and the query
# is where the difference is decided: a host WITH systemd has hundreds of units, so
# zero-with-a-socket is `unhealthy:no-units` and never a clean machine. No socket file at
# all is `absent` -- no systemd, so there are no units to miss.
# This is the branch a container exercises and a CI runner never will.
def _systemd(extra):
    return classify_rows([{"kind": "scan", "id": "systemd",
                           "ver": str(int(_time.time())),
                           "loc": "/run/dbus/system_bus_socket",
                           "extra": extra, "perms": ""}])


_txt = _systemd("unhealthy:no-units")
check("an unreadable systemd unit list is a gap, not silence",
      "COULD NOT LOOK: systemd" in _txt
      and "No AI agents found in the parts that could be read." in _txt,
      "zero units with no bus is indistinguishable from a clean host without this")

_txt = _systemd("absent")
check("...but no systemd at all is an absence, and does not hedge the report",
      "NOTHING TO LOOK AT: systemd" in _txt
      and "No AI agents found." in _txt
      and "No AI agents found in the parts that could be read." not in _txt,
      "hedging here withholds the clean answer from every machine without systemd")

# A systemd unit is EVIDENCE AND NOT A SIGNATURE, and this assertion is why.
#
# The obvious catalog entry is `systemd_prefixes: [ai.openclaw.]`, mirroring the macOS
# launchd prefix. It would be a guess: those launchd labels were read off a live install
# and no Linux unit name has been. So the route is registered -- which keeps kind='unit'
# rows unmatched rather than DROPPED -- and carries no values.
#
# This is the test that caught the guess when it was written, and it is what will fail if
# someone adds the prefix without reading it off an install.
_unit = [{"kind": "unit", "id": "ai.openclaw.gateway.service", "ver": "",
          "loc": "/etc/systemd/system/ai.openclaw.gateway.service",
          "extra": "disabled", "perms": ""}]
_ru = classify_json(_unit)
check("a unit name alone does NOT identify an agent",
      not _ru["findings"],
      "no agent's systemd unit name has been read off a real install, so matching one "
      "would be a guess wearing a finding's clothes")
check("...and the unit is still reported, as unmatched evidence",
      "ai.openclaw.gateway.service" in unmatched_ids(_ru),
      "an unregistered kind is dropped, not unmatched -- the `ext` bug")

# A VS Code extension id is `publisher.name`, which is what the row's `name` column already
# holds. The wrong expression -- publisher_id || '.' || name -- yields a GUID-prefixed
# string, and this asserts the catalog carries the right shape.
_vsc = [{"kind": "vscodeext", "id": n, "ver": "4.1.17",
         "loc": "/home/dana/.vscode/extensions/x", "extra": "vscode", "perms": ""}
        for n in ("saoudrizwan.claude-dev", "continue.continue",
                  "6f42e67d-d7ea-4a53-8704-2ae8bf2d86f3.saoudrizwan.claude-dev")]
_rv = classify_json(_vsc)
check("a VS Code extension resolves on publisher.name",
      "cline" in {f["id"] for f in _rv["findings"]})
check("a GUID-prefixed id is NOT claimed",
      "6f42e67d-d7ea-4a53-8704-2ae8bf2d86f3.saoudrizwan.claude-dev"
      in unmatched_ids(_rv),
      "publisher_id is a GUID, so the obvious expression produces this -- it must not "
      "match, or a wrong query would look correct")
# BOTH AGENTS ON THIS ROUTE, AND SEPARATELY. Continue used to be installed by
# 78-linux-vscode and deliberately left out of the catalog, with this assertion checking it
# stayed unmatched. It is catalogued now -- its own manifest calls it an agent and it
# contributes applyCodeFromChat, acceptDiff and focusEdit, so it writes to your files --
# and the assertion inverts. What matters is that the two resolve to DIFFERENT agents:
# they are the same shape, so a matcher that collapsed them would look like it worked.
check("a second agent on the same route resolves separately",
      {f["id"] for f in _rv["findings"]} == {"cline", "continue"},
      f"got {sorted(f['id'] for f in _rv['findings'])}")
check("...and neither claims the other's identifier",
      all({e["id"] for e in f["evidence"]} ==
          {"saoudrizwan.claude-dev" if f["id"] == "cline" else "continue.continue"}
          for f in _rv["findings"]),
      "two extensions of the same shape on one route is exactly where a prefix or "
      "substring match would silently merge two findings into one")


# --- running: a proc row resolves through another route's values ---------------------
# running_apps and running_npm carry no values of their own. They read bundle_ids and npm,
# so a running agent needs no second signature, and a finding with a proc row says the
# agent is running rather than only installed.
_proc = [
    {"kind": "proc", "id": "ai.openclaw.mac", "ver": "", "loc": "/Applications/OpenClaw.app",
     "extra": "", "perms": ""},
    {"kind": "proc", "id": "@openai/codex", "ver": "",
     "loc": "/opt/homebrew/lib/node_modules/@openai/codex/vendor/codex", "extra": "", "perms": ""},
    {"kind": "npm", "id": "@google/gemini-cli", "ver": "0.63.0",
     "loc": "/usr/local/lib/node_modules/@google/gemini-cli/package.json", "extra": "", "perms": ""},
    {"kind": "proc", "id": "com.apple.finder", "ver": "",
     "loc": "/System/Library/CoreServices/Finder.app", "extra": "", "perms": ""},
]
_rp = classify_json(_proc)
_running = {f["id"]: f.get("running") for f in _rp["findings"]}
check("a running app resolves through bundle_ids and is marked running",
      _running.get("openclaw") is True, f"got {_running}")
check("a running npm package resolves through npm and is marked running",
      _running.get("codex-cli") is True, f"got {_running}")
check("an installed agent with no proc row is NOT marked running",
      "gemini-cli" in _running and _running["gemini-cli"] is None, f"got {_running}")
_rc = classify_json([{"kind": "proc", "id": "/home/dana/.local/share/claude/versions/2.1.292",
                      "ver": "", "loc": "/home/dana/.local/share/claude/versions/2.1.292",
                      "extra": "", "perms": ""}])
check("a native Claude Code process resolves through process_paths and is marked running",
      [(f["id"], f.get("running")) for f in _rc["findings"]] == [("claude-code", True)],
      f"got {[(f['id'], f.get('running')) for f in _rc['findings']]}")
check("an unclaimed process is unmatched, not dropped",
      "com.apple.finder" in unmatched_ids(_rp),
      "a kind absent from the registry is DROPPED, not unmatched -- the `ext` bug")


# --- version skew: warn and match, never refuse ------------------------------------
#
# catalog/agents.yaml carried `version:` unread for its whole life, so nothing could ever
# disagree with it. It is checked now, and the BEHAVIOUR is the assertion: a downloaded
# bin/classify meeting a newer catalog must warn on stderr and match what it recognises.
# Refusing would turn version skew into "no agents found" -- which reads downstream as a
# clean fleet, and is the one error this repo exists to avoid.
import tempfile as _tf3, yaml as _yaml3

_cat = _yaml3.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
_cat["version"] = 99
with _tf3.NamedTemporaryFile("w", suffix=".yaml", delete=False) as _fh:
    _yaml3.safe_dump(_cat, _fh)
    _newer = _fh.name
_rows_j = json.dumps(_deb("cursor"))
_proc = subprocess.run(
    [sys.executable, str(ROOT / "bin" / "classify"), "--json", "--catalog", _newer],
    input=_rows_j, capture_output=True, text=True)
check("a newer catalog still produces findings",
      _proc.returncode == 0
      and {f["id"] for f in json.loads(_proc.stdout)["findings"]} == {"cursor"},
      f"rc={_proc.returncode} err={_proc.stderr.strip()[:120]}")
check("...and says so on stderr rather than silently",
      "version 99" in _proc.stderr and "matcher understands" in _proc.stderr,
      f"got {_proc.stderr.strip()[:160]!r}")

# The current catalog must NOT warn, or the warning is noise everyone learns to ignore.
_proc2 = subprocess.run(
    [sys.executable, str(ROOT / "bin" / "classify"), "--json"],
    input=_rows_j, capture_output=True, text=True)
check("the shipped catalog produces no version warning",
      "matcher understands" not in _proc2.stderr,
      f"got {_proc2.stderr.strip()[:160]!r}")


# --- the coverage recorder must credit the route that actually matched ------------
# tools/agent_status.py --record replays a run and writes which identifiers it proved.
# It used to credit the whole glob GROUP for any kind='file' match, so a row for
# ~/.local/share/uv/tools/aider-chat/ recorded `state_dirs: ~/.aider` as observed in a
# real install -- an identifier that appeared nowhere in that run. A measuring tool
# reporting a plausible wrong answer is the exact failure this repo is built around, so
# it is asserted here rather than trusted.
import importlib.util as _ilu, importlib.machinery as _ilm, tempfile as _tf2

_spec = _ilu.spec_from_loader("agent_status",
    _ilm.SourceFileLoader("agent_status", str(ROOT / "tools" / "agent_status.py")))
_st = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_st)

_rows = [{"kind": "file", "id": "/Users/x/.local/share/uv/tools/aider-chat/", "ver": "",
          "loc": "/Users/x/.local/share/uv/tools/aider-chat/", "extra": "", "perms": ""}]
with _tf2.NamedTemporaryFile("w", suffix=".json", delete=False) as _fh:
    json.dump(_rows, _fh)
with _tf2.TemporaryDirectory() as _d:
    _st.record(_fh.name, _d)
    _rec = json.loads((pathlib.Path(_d) / "observed.json").read_text())["identifiers"]
_got = {(r["route"], r["value"]) for r in _rec}

check("recording credits the route that matched (pypi, from the tool dir)",
      ("pypi", "aider-chat") in _got, f"got {sorted(_got)}")
check("recording does NOT credit a state dir the run never produced",
      not any(r == "state_dirs" for r, _ in _got),
      "~/.aider appears in no row here; crediting it would report the strongest evidence "
      "for a path no machine produced")

# --- an observation names the run that produced it --------------------------------
#
# THE FIELD THAT LETS PROOF OUTLIVE THE RUN. Without it, an observation from a CI runner
# and one from a maintainer's Mac are the same record, so "this identifier was once proved
# by CI" cannot be established after CI stops reproducing it -- which is the whole basis of
# a superseded record.
#
# Asserted in BOTH directions. A run id that appears when none was supplied would be
# manufactured provenance, which is worse than none: it would make a local run look like a
# CI run, and the catalog entry standing on it would cite a run that never happened.
with _tf2.TemporaryDirectory() as _d:
    _st.record(_fh.name, _d, os_version="24.04", arch="arm64", platform="linux",
               run_id="33702118455")
    _with_run = json.loads((pathlib.Path(_d) / "observed.json").read_text())["identifiers"]
with _tf2.TemporaryDirectory() as _d:
    _st.record(_fh.name, _d)
    _no_run = json.loads((pathlib.Path(_d) / "observed.json").read_text())["identifiers"]

check("an observation records the run that produced it",
      _with_run and all(r.get("run") == "33702118455" for r in _with_run),
      f"got {[r.get('run') for r in _with_run]}")
check("a local run records NO run id rather than inventing one",
      _no_run and not any("run" in r for r in _no_run),
      f"got {[r.get('run') for r in _no_run]}")

# --- a superseded record must be backed by an archived observation -----------------
#
# `superseded:` ships with NO records -- nothing in the catalog qualifies yet -- so every
# branch of its validator is unexercised code until the first real rename. That is exactly
# when you least want to discover it is wrong, so it is driven here with a synthetic
# record instead.
#
# The check that matters is the last one: a record whose cited observation is not in the
# tree is a guess wearing provenance-shaped fields, which is worse than a guess because it
# reads as evidence. The old `retired:` list had no such check at all, which is how two
# values naming a release that was never published stayed exempt from the coverage gate.
_vspec = _ilu.spec_from_loader("validate_catalog",
    _ilm.SourceFileLoader("validate_catalog", str(ROOT / "tools" / "validate_catalog.py")))
_vc = _ilu.module_from_spec(_vspec)
_vspec.loader.exec_module(_vc)

_REC = {"route": "bundle_ids", "value": "com.example.old", "last_version": "1.2.3",
        "last_proved": "2026-08-20", "by": "zz-probe", "run": "33511815638"}

with _tf2.TemporaryDirectory() as _d:
    _fake = pathlib.Path(_d)
    (_fake / "test" / "scenarios" / "zz-probe").mkdir(parents=True)
    _obs = _fake / "test" / "scenarios" / "zz-probe" / "observed.json"
    _saved_root = _vc.ROOT
    _vc.ROOT = _fake
    try:
        _obs.write_text(json.dumps({"scenario": "zz-probe", "identifiers": []}))
        _no_archive = _vc.archived_match("probe-agent", _REC)

        _obs.write_text(json.dumps({"scenario": "zz-probe", "identifiers": [], "archived": [
            {"agent": "probe-agent", "route": "bundle_ids", "value": "com.example.old",
             "agent_version": "1.2.3", "run": "33511815638"}]}))
        _matched = _vc.archived_match("probe-agent", _REC)

        # Same record, different run: the observation exists but is not the one cited.
        _obs.write_text(json.dumps({"scenario": "zz-probe", "identifiers": [], "archived": [
            {"agent": "probe-agent", "route": "bundle_ids", "value": "com.example.old",
             "agent_version": "1.2.3", "run": "99999999999"}]}))
        _wrong_run = _vc.archived_match("probe-agent", _REC)
    finally:
        _vc.ROOT = _saved_root

check("a superseded record with no archived observation is refused", not _no_archive)
check("a superseded record matching an archived observation is accepted", _matched)
check("a superseded record citing the WRONG run is refused", not _wrong_run,
      "the observation exists but did not come from the run the record names")

# The register superseded: replaced must not come back unread. Both directions: the live
# catalog carries only keys a tool reads, and `unverified:` at the top level is refused.
_tle = _vc.top_level_errors
check("the live catalog's top-level keys are all ones a tool reads",
      _tle(_yaml3.safe_load((ROOT / "catalog" / "agents.yaml").read_text())) == [],
      "add the key to TOP_LEVEL only if a tool reads it")
check("a top-level unverified: block is refused",
      any("['unverified']" in e for e in _tle({"agents": [], "unverified": [{"value": "x"}]})),
      "it passed the validator before, and nothing reads it")
_empty = _tle({"agents": [], "untested": None})
check("an EMPTY untested: is refused too, once, by its own message",
      len(_empty) == 1 and "`untested:`" in _empty[0], f"got {_empty}")

# --- the classifier LABELS a superseded match, and never withholds it --------------
#
# The catalog carries no superseded records, so every branch of the label is unexercised
# until the first real rename -- which is the worst moment to discover it drops findings
# instead of marking them. Driven here with a synthetic catalog instead.
#
# The assertion that matters is the first: the agent is STILL FOUND. A superseded
# identifier exists for the machines nothing else will match, so a label that filtered
# would produce an empty result on exactly the fleet the record was kept for.
_sup_cat = _yaml3.safe_load((ROOT / "catalog" / "agents.yaml").read_text())
for _a in _sup_cat["agents"]:
    if _a["id"] == "openclaw":
        _a["superseded"] = [{"route": "npm", "value": "moltbot", "last_version": "0.1.0",
                             "last_proved": "2026-09-02", "by": "56-openclaw-retired-names",
                             "run": "33702118455"}]
with _tf3.NamedTemporaryFile("w", suffix=".yaml", delete=False) as _fh2:
    _yaml3.safe_dump(_sup_cat, _fh2)

_sup_rows = [{"kind": "npm", "id": "moltbot", "ver": "0.1.0", "loc": "/x", "extra": "", "perms": ""},
             {"kind": "npm", "id": "openclaw", "ver": "2026.9.1", "loc": "/y", "extra": "", "perms": ""}]
with _tf3.NamedTemporaryFile("w", suffix=".json", delete=False) as _fh3:
    json.dump(_sup_rows, _fh3)

_out = subprocess.run([sys.executable, str(ROOT / "bin" / "classify"), _fh3.name,
                       "--json", "--catalog", _fh2.name],
                      capture_output=True, text=True, check=True)
_sup_found = {f["id"]: f for f in json.loads(_out.stdout)["findings"]}
_oc = _sup_found.get("openclaw", {})

check("a superseded match is still a FINDING, not filtered out", "openclaw" in _sup_found,
      "the machines a superseded identifier exists for are the ones nothing else matches")
check("both generations are still reported as evidence",
      {e["id"] for e in _oc.get("evidence", [])} == {"moltbot", "openclaw"},
      f"got {sorted(e['id'] for e in _oc.get('evidence', []))}")
check("the superseded identifier is named", _oc.get("superseded") == ["moltbot"],
      f"got {_oc.get('superseded')}")
check("a finding with a current match is NOT only_superseded",
      _oc.get("only_superseded") is False, f"got {_oc.get('only_superseded')}")
check("--json speaks with the current generation, though the replaced one came first",
      _oc.get("primary") == 1 and _oc.get("version") == "2026.9.1",
      f"got primary={_oc.get('primary')} version={_oc.get('version')}")

# The same catalog, a payload carrying ONLY the superseded generation.
with _tf3.NamedTemporaryFile("w", suffix=".json", delete=False) as _fh4:
    json.dump([_sup_rows[0]], _fh4)
_only = subprocess.run([sys.executable, str(ROOT / "bin" / "classify"), _fh4.name,
                        "--json", "--catalog", _fh2.name],
                       capture_output=True, text=True, check=True)
_oc_only = {f["id"]: f for f in json.loads(_only.stdout)["findings"]}.get("openclaw", {})
check("a machine matched only on an earlier release says so",
      _oc_only.get("only_superseded") is True, f"got {_oc_only.get('only_superseded')}")

_txt = subprocess.run([sys.executable, str(ROOT / "bin" / "classify"), _fh4.name,
                       "--catalog", _fh2.name], capture_output=True, text=True, check=True)
check("...and the human-readable output says it too",
      "has not updated" in _txt.stdout and "earlier release" in _txt.stdout,
      _txt.stdout.strip()[-120:])
check("an unsuperseded finding carries no label at all",
      "superseded" not in {k for f in json.loads(_out.stdout)["findings"]
                           if f["id"] != "openclaw" for k in f},
      "the key is omitted rather than emitted false, so its absence is not a claim")

# --- the collect job's merge, which used to be unreachable ------------------------
#
# This was ~45 lines of Python inside a YAML heredoc: check_workflows saw a string, no test
# could reach it, and it is the step that decides what the committed record says. Two bugs
# were sitting in it, neither observable anywhere but main after a full matrix run.
_mspec = _ilu.spec_from_loader("merge_observations",
    _ilm.SourceFileLoader("merge_observations", str(ROOT / "tools" / "merge_observations.py")))
_mo = _ilu.module_from_spec(_mspec)
_mspec.loader.exec_module(_mo)


def _artifact(root, scen, os_ver, recs):
    d = pathlib.Path(root) / f"observed-{scen}--{os_ver}"
    d.mkdir(parents=True)
    (d / "observed.json").write_text(json.dumps({"scenario": scen, "identifiers": recs}))


def _rec(value, os_ver, run="1"):
    return {"agent": "openclaw", "route": "npm", "value": value, "agent_version": "1.0",
            "platform": "darwin", "os": os_ver, "arch": "arm64", "run": run}


# THE HARNESS JOBS UPLOAD ONE ARTIFACT PER IMAGE, holding an observed-<scenario>--<label>/
# observed.json for every scenario that passed, so those documents sit one directory
# deeper than a matrix cell's. Both shapes must be read, or a whole image's evidence
# vanishes from the merge and from the reported list while the run looks green.
with _tf2.TemporaryDirectory() as _d:
    _art = pathlib.Path(_d) / "art"
    _artifact(_art, "zz-merge", "15.7.9", [_rec("openclaw", "15.7.9")])
    _artifact(_art / "observed-debian-12", "zz-nested", "debian-12", [_rec("openclaw", "debian-12")])
    _seen = _mo.seen_scenarios(_art)
check("a harness job's nested observed.json files are read beside the matrix cells'",
      _seen == {"zz-merge", "zz-nested"}, f"got {sorted(_seen)}")


with _tf2.TemporaryDirectory() as _d:
    _art, _scen = pathlib.Path(_d) / "art", pathlib.Path(_d) / "scen"
    (_scen / "zz-merge").mkdir(parents=True)
    _committed = _scen / "zz-merge" / "observed.json"

    # A committed file carrying one live record and one ARCHIVED record.
    _committed.write_text(json.dumps({
        "scenario": "zz-merge",
        "identifiers": [_rec("openclaw", "15.7.9")],
        "archived": [_rec("moltbot", "14.8.9")]}, indent=2))

    # Two runners upload. macos-14 still carries the archived record verbatim, because
    # record()'s `kept` copies every other platform key's records into each job's upload --
    # which is exactly how a resurrection happens.
    _artifact(_art, "zz-merge", "15.7.9", [_rec("openclaw", "15.7.9")])
    _artifact(_art, "zz-merge", "14.8.9", [_rec("openclaw", "15.7.9"), _rec("moltbot", "14.8.9")])

    _mo.merge(_art, _scen)
    _after = json.loads(_committed.read_text())

_live = {r["value"] for r in _after.get("identifiers", [])}
_arch = {r["value"] for r in _after.get("archived", [])}

check("the merge carries the archived list through",
      _arch == {"moltbot"},
      "it rebuilt the document from scratch, so an archive survived until the next main run")
check("...and does NOT resurrect an archived record from another runner's upload",
      "moltbot" not in _live,
      "record()'s `kept` re-uploads other platforms' records verbatim, and the union "
      "handed them straight back to identifiers")
check("a live record still merges normally", _live == {"openclaw"}, f"got {sorted(_live)}")

# The 26.0 artifact sorts LAST and carries a stale copy of the 15.7.9 record, as every
# upload does for the other runner's keys. The 15.7.9 runner's own record must win.
with _tf2.TemporaryDirectory() as _d:
    _art, _scen = pathlib.Path(_d) / "art", pathlib.Path(_d) / "scen"
    (_scen / "zz-merge").mkdir(parents=True)
    _committed = _scen / "zz-merge" / "observed.json"
    _committed.write_text(json.dumps({
        "scenario": "zz-merge", "identifiers": [_rec("openclaw", "15.7.9", run="100")]}))
    _artifact(_art, "zz-merge", "15.7.9", [_rec("openclaw", "15.7.9", run="200")])
    _artifact(_art, "zz-merge", "26.0", [_rec("openclaw", "15.7.9", run="100"),
                                         _rec("openclaw", "26.0", run="200")])
    _mo.merge(_art, _scen)
    _runs = {r["os"]: r["run"] for r in json.loads(_committed.read_text())["identifiers"]}

check("a runner's fresh record beats the stale copy in an upload that sorts after it",
      _runs == {"15.7.9": "200", "26.0": "200"},
      f"got {_runs}: the last artifact won every key, so the other runner's record froze")

# THE COMMITTED FILE IS THE BASE. collect re-merges onto the current main after a rejected
# push, and by then main may hold what this run's uploads do not: a key a later collect
# added, or a newer run of a key these uploads carry an older copy of -- a VM record with
# no run id is the first shape, and the second is any parallel run that finished first.
# Built from uploads alone, the merge erased the first and regressed the second, and the
# only thing that had kept that from happening was the push being rejected.
with _tf2.TemporaryDirectory() as _d:
    _art, _scen = pathlib.Path(_d) / "art", pathlib.Path(_d) / "scen"
    (_scen / "zz-merge").mkdir(parents=True)
    _committed = _scen / "zz-merge" / "observed.json"
    _vm = dict(_rec("openclaw", "debian-12"), platform="linux", arch="x86_64"); del _vm["run"]
    _committed.write_text(json.dumps({
        "scenario": "zz-merge",
        "identifiers": [_rec("openclaw", "15.7.9", run="300"), _vm]}))
    _artifact(_art, "zz-merge", "15.7.9", [_rec("openclaw", "15.7.9", run="200"),
                                           _rec("openclaw", "26.0", run="200")])
    _mo.merge(_art, _scen)
    _got = {(r["os"], r.get("run")) for r in json.loads(_committed.read_text())["identifiers"]}

check("a re-merge keeps a committed record the uploads never carried",
      ("debian-12", None) in _got, f"got {sorted(_got, key=str)}: the VM record was erased")
check("...and keeps the committed copy when it is the newer run",
      ("15.7.9", "300") in _got and ("15.7.9", "200") not in _got,
      f"got {sorted(_got, key=str)}: an older upload regressed a newer committed record")
check("...while still adding what the uploads bring",
      ("26.0", "200") in _got, f"got {sorted(_got, key=str)}")

# --- the coverage shrink guard is scoped per (platform, os, arch) -----------------
#
# THIS TEST EXISTS BECAUSE I MISREAD THE GUARD AND BLAMED IT. A CI job refused to record
# with `lost aider state_dirs:~/.aider` against a committed file whose records were all
# `arch=aarch64`, on a runner reporting `x86_64` -- so the filtered set looked like it had
# to be empty and the guard looked wrong.
#
# It was right. A `pull_request` job checks out the MERGE of the branch into main, not the
# branch, and MAIN's copy of that file already carried x86_64 records from an earlier run
# on main. The guard filtered to x86_64, found them, and correctly reported that the run
# proved one fewer. What was wrong was the forensics: comparing against `git show
# <branch>:...` when CI never read that file.
#
# The semantics are asserted here rather than reasoned about, because reasoning about them
# is exactly what failed. Both directions, and the two-key file is the real shape that
# caused the confusion.
import contextlib as _ctx, io as _io, shutil as _sh

def _observed(*recs):
    return {"scenario": "zz-fixture",
            "identifiers": [{"agent": a, "route": r, "value": v,
                             "platform": "linux", "os": "24.04", "arch": ar}
                            for a, r, v, ar in recs]}

# A payload that proves aider's pypi route and NOTHING else -- no ~/.aider.
_pypi_only = [{"kind": "file", "id": "/home/dana/.local/share/uv/tools/aider-chat/",
               "ver": "", "loc": "/home/dana/.local/share/uv/tools/aider-chat/",
               "extra": "", "perms": ""}]

def _try_record(arch, committed):
    """Run record() against a committed file, in a fake scenarios root."""
    tmp = pathlib.Path(_tf2.mkdtemp())
    try:
        scen = tmp / "scenarios" / "zz-fixture"
        scen.mkdir(parents=True)
        (scen / "observed.json").write_text(json.dumps(committed))
        art = tmp / "art.json"
        art.write_text(json.dumps(_pypi_only))
        old_root, _st.SCENARIOS = _st.SCENARIOS, tmp / "scenarios"
        out, rc = _io.StringIO(), 0
        try:
            with _ctx.redirect_stdout(out):
                _st.record(str(art), str(scen), "24.04", arch, "linux")
        except SystemExit as e:
            rc = e.code or 0
        finally:
            _st.SCENARIOS = old_root
        after = json.loads((scen / "observed.json").read_text())["identifiers"]
        return rc, out.getvalue(), after
    finally:
        _sh.rmtree(tmp, ignore_errors=True)

# The two-key file: the same identifiers proved on two architectures.
_two_key = _observed(
    ("aider", "pypi", "aider-chat", "aarch64"),
    ("aider", "state_dirs", "~/.aider", "aarch64"),
    ("aider", "pypi", "aider-chat", "x86_64"),
    ("aider", "state_dirs", "~/.aider", "x86_64"))

_rc, _out, _after = _try_record("x86_64", _two_key)
check("a run proving less on ITS OWN key is refused",
      _rc == 1 and "aider state_dirs:~/.aider" in _out,
      f"rc={_rc} out={_out.strip()[:160]!r}")
check("...and the refusal names the key it compared, and the file's keys",
      "'x86_64'" in _out and "keys in the committed file" in _out and "aarch64" in _out,
      "naming only WHAT was lost, and not which key it was compared against, is what sent "
      "me looking for a bug in the guard")

_rc, _out, _after = _try_record("riscv64", _two_key)
_keys = {(r.get("arch")) for r in _after}
check("a run on a DIFFERENT key is not judged against the others",
      _rc == 0, f"rc={_rc} out={_out.strip()[:160]!r}")
check("...and it leaves every other key's records alone",
      {"aarch64", "x86_64"} <= _keys,
      f"kept arches {sorted(k for k in _keys if k)} -- overwriting would let the last job "
      f"to finish decide what the scenario had ever proved")

# --- superseding MOVES the evidence; --allow-shrink destroys it -------------------
#
# The guard fires whenever a run proves less than the committed record, and until now the
# only way past it was to forget what was lost -- so the observation that proved an
# identifier was destroyed by the same step that kept the identifier, and a catalog entry
# retained "for the machines that still carry it" had nothing behind it but a comment.
#
# This is the transition, and it only ever runs on a real vendor rename, which may be
# months away. Driven synthetically so it is not first exercised on the day it matters.
def _supersede_run(committed):
    tmp = pathlib.Path(_tf2.mkdtemp())
    try:
        scen = tmp / "scenarios" / "zz-fixture"
        scen.mkdir(parents=True)
        (scen / "observed.json").write_text(json.dumps(committed))
        art = tmp / "art.json"
        art.write_text(json.dumps(_pypi_only))
        old_root, _st.SCENARIOS = _st.SCENARIOS, tmp / "scenarios"
        out = _io.StringIO()
        try:
            with _ctx.redirect_stdout(out):
                _st.record(str(art), str(scen), "24.04", "aarch64", "linux",
                           run_id="222", supersede=True)
        finally:
            _st.SCENARIOS = old_root
        return out.getvalue(), json.loads((scen / "observed.json").read_text())
    finally:
        _sh.rmtree(tmp, ignore_errors=True)


_one_key = _observed(("aider", "pypi", "aider-chat", "aarch64"),
                     ("aider", "state_dirs", "~/.aider", "aarch64"))
for _r in _one_key["identifiers"]:
    _r["run"], _r["agent_version"] = "111", "0.90"
_sup_out, _sup_after = _supersede_run(_one_key)
_sup_live = {r["value"] for r in _sup_after.get("identifiers", [])}
_sup_arch = {r["value"] for r in _sup_after.get("archived", [])}

check("superseding moves the lost record into `archived`", _sup_arch == {"~/.aider"},
      f"got {sorted(_sup_arch)}")
check("...and drops it from the live identifiers", "~/.aider" not in _sup_live,
      "an archived record that is also live would be handed back by the next merge")
check("...while what the run DID prove stays live", _sup_live == {"aider-chat"},
      f"got {sorted(_sup_live)}")
check("the archived record keeps the run that proved it",
      all(r.get("run") == "111" for r in _sup_after.get("archived", [])),
      "validate_catalog cross-checks the catalog record against exactly this field")
check("it prints the catalog block, with the value and its last version",
      "superseded:" in _sup_out and "value: ~/.aider" in _sup_out
      and "last_version: 0.90" in _sup_out,
      _sup_out.strip()[-200:])
check("...and says the value stays on its route",
      "never moves it" in _sup_out,
      "supersession marks a value; moving it off its route would stop it matching")

# A run that proves everything says so rather than silently writing an empty archive.
_full = _observed(("aider", "pypi", "aider-chat", "aarch64"))
for _r in _full["identifiers"]:
    _r["run"], _r["agent_version"] = "111", "0.90"
_noop_out, _noop_after = _supersede_run(_full)
check("--supersede on a run that lost nothing archives nothing",
      not _noop_after.get("archived") and "nothing to supersede" in _noop_out,
      _noop_out.strip()[:120])

# --- the other half of a rename: what arrived unclaimed ---------------------------
#
# Three guards fire when an identifier stops appearing and NOTHING fired when a new one
# arrived -- though a rename does both, in one run, on one machine, in one payload. The
# successor was computed on every scenario by assert.sh and thrown away.
_scspec = _ilu.spec_from_loader("successor_candidates",
    _ilm.SourceFileLoader("successor_candidates",
                          str(ROOT / "tools" / "successor_candidates.py")))
_sc = _ilu.module_from_spec(_scspec)
_scspec.loader.exec_module(_sc)

_sc_rows = [
    {"kind": "app", "id": "com.vendor.brandnew", "ver": "2.0",
     "loc": "/Applications/BrandNew.app", "extra": "", "perms": ""},
    {"kind": "app", "id": "com.apple.Safari", "ver": "18.0",
     "loc": "/Applications/Safari.app", "extra": "", "perms": ""},
    {"kind": "npm", "id": "unrelated-pkg", "ver": "1.0", "loc": "/x",
     "extra": "", "perms": ""},
]
# A bare machine shows Safari and nothing a scenario installed.
_sc_base = [_sc_rows[1]]

_cands = _sc.candidates(_sc_rows, {"app"})
check("candidates are narrowed to the lost route's kind",
      {c["id"] for c in _cands} == {"com.vendor.brandnew", "com.apple.Safari"},
      f"got {sorted(c['id'] for c in _cands)}")
check("...so a row of another kind is not offered as a successor",
      "unrelated-pkg" not in {c["id"] for c in _cands})

_narrowed = _sc.candidates(_sc_rows, {"app"}, baseline_rows=_sc_base)
check("subtracting the baseline removes the runner's own furniture",
      {c["id"] for c in _narrowed} == {"com.vendor.brandnew"},
      f"got {sorted(c['id'] for c in _narrowed)}")

check("the kind is resolved from the route, not typed",
      _sc.kinds_for(_st.ROUTES, {"bundle_ids"}) == {"app"},
      "routes.yaml already says which kind a route arrives on")

# AN EMPTY LIST IS A FINDING, not a blank. An AppImage replacing a .deb leaves no package
# record at all, so a lost value with no successor means the route went away.
check("no candidate says the route went away rather than printing nothing",
      "not a rename" in _sc.render([], "deb_packages:something"),
      _sc.render([], "x"))
check("a candidate list says an unclaimed row is not this agent's row",
      "not the same as this agent" in _sc.render(_narrowed, "bundle_ids:old"))

# And the guard itself reports both halves.
_g_committed = {"scenario": "zz-fixture", "identifiers": [
    {"agent": "chatgpt-desktop", "route": "bundle_ids", "value": "com.openai.chat",
     "agent_version": "1.2026.160", "platform": "linux", "os": "24.04",
     "arch": "aarch64", "run": "111"}]}
_tmp = pathlib.Path(_tf2.mkdtemp())
try:
    _s = _tmp / "scenarios" / "zz-fixture"
    _s.mkdir(parents=True)
    (_s / "observed.json").write_text(json.dumps(_g_committed))
    _a = _tmp / "art.json"
    _a.write_text(json.dumps(_sc_rows))
    _old_root, _st.SCENARIOS = _st.SCENARIOS, _tmp / "scenarios"
    _gout = _io.StringIO()
    try:
        with _ctx.redirect_stdout(_gout):
            _st.record(str(_a), str(_s), "24.04", "aarch64", "linux", run_id="222")
    except SystemExit:
        pass
    finally:
        _st.SCENARIOS = _old_root
    _gtext = _gout.getvalue()
finally:
    _sh.rmtree(_tmp, ignore_errors=True)

check("the shrink guard reports what arrived, not only what was lost",
      "com.vendor.brandnew" in _gtext and "Lost: bundle_ids:com.openai.chat" in _gtext,
      _gtext.strip()[-200:])
check("...and offers --supersede beside --allow-shrink",
      "--supersede" in _gtext and "--allow-shrink" in _gtext,
      "the two exits differ: one keeps the evidence, one destroys it")

# COVERAGE COUNTS ONLY WHAT COULD BE PUBLISHED AS PROOF. A record with no run id is a local
# --record, and counting it made an identifier covered that tools/export.py --strict refused.
_cov_key = ("aider", "pypi", "aider-chat")


def _cov_state(scenarios):
    old, _st.SCENARIOS = _st.SCENARIOS, scenarios
    try:
        data = _st.collect()
    finally:
        _st.SCENARIOS = old
    return next(i["state"] for a in data["agents"] if a["id"] == _cov_key[0]
                for i in a["identifiers"] if (i["route"], str(i["value"])) == _cov_key[1:])


_tmp = pathlib.Path(_tf2.mkdtemp())
try:
    _sh.copytree(_st.SCENARIOS, _tmp / "scenarios")
    _cov_before = _cov_state(_tmp / "scenarios")
    for _p in (_tmp / "scenarios").glob("*/observed.json"):
        _d = json.loads(_p.read_text())
        for _r in _d.get("identifiers", []):
            if (_r["agent"], _r["route"], str(_r["value"])) == _cov_key:
                _r.pop("run", None)
        _p.write_text(json.dumps(_d))
    _cov_after = _cov_state(_tmp / "scenarios")
finally:
    _sh.rmtree(_tmp, ignore_errors=True)
check("an identifier observed only without a run id is not covered by CI",
      _cov_before in _st.COVERED_STATES and _cov_after not in _st.COVERED_STATES,
      f"before {_cov_before}, after {_cov_after}")

# --- running containers and vendor labels ------------------------------------------
# The two routes added beside `images`, and the reason both exist: a tag is chosen by
# whoever ran `docker tag`, a label is written by the vendor, and a running container says
# something no other route in this repo can say about anything.
#
# Rows are shaped exactly as osquery/queries/containers.sql emits them, and every id below was
# read off a real daemon (Docker 28.4.0 / osquery 5.23.1, 2026-09-11) rather than invented.


def _container(image, state="running", command="", cid="c0ffee"):
    return {"kind": "container", "id": image, "ver": state, "loc": cid,
            "extra": command, "perms": ""}


def _ilabel(value, img="deadbeef"):
    return {"kind": "ilabel", "id": value, "ver": "", "loc": img,
            "extra": "org.opencontainers.image.source", "perms": ""}


r = classify_json([_container("ghcr.io/block/goose:latest", command="sleep 600")])
check("a running container from a catalogued image is found",
      {f["id"] for f in r["findings"]} == {"goose"},
      f"got {[f['id'] for f in r['findings']]}; the container route reads `images:` "
      f"through values_from, and an empty index here means that alias is broken")

# THE ALIAS IS THE LOAD-BEARING PART, so prove it reaches a value the agent declares only
# once. goose has no `container_images:` key of its own; if build_index stopped honouring
# values_from, this is the assertion that goes red.
r = classify_json([_container("ghcr.io/openhands/openhands:latest")])
check("...for every agent, not just the first one indexed",
      {f["id"] for f in r["findings"]} == {"openhands"},
      f"got {[f['id'] for f in r['findings']]}")

# MUST NOT MATCH, and it is the same near-miss 79-linux-image runs as a real container.
# A container route matching on a prefix would claim this, and every positive assertion
# above would still pass.
r = classify_json([_container("paulgauthier/aider-fork:latest")])
check("a near-miss image is NOT claimed through the container route",
      not r["findings"] and "paulgauthier/aider-fork:latest" in unmatched_ids(r),
      "exact on the normalised repository, and visibly declined rather than dropped")

# THE `ext` GUARD, for the two new kinds. A kind absent from catalog/routes.yaml falls off
# the end of classify()'s loop -- DROPPED, not unmatched, invisible even under
# --show-unmatched. That cost this repo months once, so each new kind gets the assertion.
r = classify_json([_container("postgres:15"), _ilabel("https://github.com/BerriAI/litellm")])
check("an unclaimed container row is UNMATCHED, not dropped",
      "postgres:15" in unmatched_ids(r), "the kind must be registered in routes.yaml")
check("an unclaimed label row is UNMATCHED, not dropped",
      "https://github.com/BerriAI/litellm" in unmatched_ids(r),
      "a gateway is not an agent, and its source URL must be visibly declined")

r = classify_json([_ilabel("https://github.com/OpenHands/OpenHands"),
                   _ilabel("https://github.com/block/goose")])
check("a vendor-set OCI source label identifies its agent",
      {f["id"] for f in r["findings"]} == {"openhands", "goose"},
      f"got {[f['id'] for f in r['findings']]}")

# THE LABEL TRAP, and it is why the query emits `source` and nothing else. Measured on
# sweagent/swe-agent, whose only labels are org.opencontainers.image.ref.name=ubuntu and
# version=22.04, both inherited from its base image. If anyone widens containers.sql to
# emit `title` or `ref.name`, these rows start arriving and must still claim nothing.
r = classify_json([_ilabel("ubuntu"), _ilabel("22.04"), _ilabel("wolfi-base")])
check("an inherited base-image label claims nothing",
      not r["findings"] and {"ubuntu", "22.04", "wolfi-base"} <= unmatched_ids(r),
      "a label route keyed on `title` would offer Ubuntu as an agent's identity")

# A container is a SECOND witness, not a replacement: the image row and the container row
# describe the same agent and must fold into one finding rather than two.
r = classify_json([{"kind": "image", "id": "ghcr.io/block/goose:latest", "ver": "",
                    "loc": "d85a724ee487", "extra": "455000000", "perms": ""},
                   _container("ghcr.io/block/goose:latest", command="sleep 600"),
                   _ilabel("https://github.com/block/goose")])
check("three routes agreeing produce ONE agent, with all three as evidence",
      [f["id"] for f in r["findings"]] == ["goose"]
      and {e["kind"] for e in r["findings"][0]["evidence"]}
      == {"image", "container", "ilabel"},
      f"got {r['findings']}")

# --- the agents read off ai_tools' leads, and the lookalike each one arrived with -------
# Every identifier here was produced by a real install on 2026-10-07, and so was every
# lookalike: they sat in the same payloads, and they are what a substring match, a guessed
# package name or a generic filename would claim.
def _kind(kind, *ids, extra=""):
    return [{"kind": kind, "id": i, "ver": "1.0", "loc": i, "extra": extra, "perms": ""}
            for i in ids]

def _claims(rows):
    r = classify_json(rows)
    return {e["id"]: f["id"] for f in r["findings"] for e in f["evidence"]}, unmatched_ids(r)

_c, _u = _claims(_kind("vscodeext", "rooveterinaryinc.roo-cline", "saoudrizwan.claude-dev",
                       "anthropic.claude-code", "openai.chatgpt", "openai.codex-audio",
                       extra="vscode"))
check("a Cline fork's id is NOT Cline's (rooveterinaryinc.roo-cline)",
      _c.get("rooveterinaryinc.roo-cline") == "roo-code"
      and _c.get("saoudrizwan.claude-dev") == "cline",
      f"got {_c}")
check("each vendor's editor extension lands on its own CLI's entry",
      _c.get("anthropic.claude-code") == "claude-code"
      and _c.get("openai.chatgpt") == "codex-cli", f"got {_c}")
check("Codex's companion extension claims nothing (openai.codex-audio)",
      "openai.codex-audio" in _u, "it installs beside openai.chatgpt and acts on nothing")

_c, _u = _claims(_kind("file", "/home/dana/.local/bin/cursor-agent",
                       "/home/dana/.local/bin/agent", "/home/dana/.local/bin/kiro-cli",
                       "/home/dana/.local/bin/kiro-cli-chat",
                       "/home/dana/.grok/", "/home/dana/.opencode/"))
check("the curl installers' paths resolve to their agents",
      _c == {"/home/dana/.local/bin/cursor-agent": "cursor",
             "/home/dana/.local/bin/kiro-cli": "kiro-cli",
             "/home/dana/.grok/": "grok", "/home/dana/.opencode/": "opencode"},
      f"got {_c}")
check("kiro-cli-chat, written beside kiro-cli, is evidence rather than a value",
      "/home/dana/.local/bin/kiro-cli-chat" in _u, f"got {_c}")
check("Cursor's generic ~/.local/bin/agent link claims nothing",
      "/home/dana/.local/bin/agent" in _u,
      "Cursor CLI and Grok Build both write an `agent`; a name that generic identifies nobody")

_c, _u = _claims(_kind("app", "com.amazon.codewhisperer", "dev.kiro.desktop",
                       "com.electron.goose", "com.electron.other"))
check("Kiro CLI and Kiro the IDE are told apart by their real bundle ids",
      _c.get("com.amazon.codewhisperer") == "kiro-cli"
      and _c.get("dev.kiro.desktop") == "kiro", f"got {_c}")
check("Electron's default id shape claims only goose's whole id",
      _c.get("com.electron.goose") == "goose" and "com.electron.other" in _u,
      "com.electron.<name> is the packager's pattern; a prefix match would claim every app")

_c, _u = _claims(_kind("npm", "@kilocode/cli", "kilocode", "opencode-ai"))
check("npm's unscoped `kilocode` is NOT Kilo Code",
      _c.get("@kilocode/cli") == "kilo-code" and "kilocode" in _u, f"got {_c}")

_c, _u = _claims(_kind("jbplugin", "gemini", "plugin-amazonq", "github-copilot-intellij",
                       "Sourcegraph", "sourcegraph", "aws-toolkit-jetbrains-standalone"))
check("the JetBrains plugin directories resolve to their agents",
      _c == {"gemini": "gemini-code-assist", "plugin-amazonq": "amazon-q",
             "github-copilot-intellij": "copilot-cli", "Sourcegraph": "cody"}
      and "aws-toolkit-jetbrains-standalone" in _u, f"got {_c}")
check("...and matched with the vendor's case (`sourcegraph` is not Cody's directory)",
      "sourcegraph" in _u, "exact means exact; a case-folded route would claim it")

# META'S TWO MUSE PRODUCTS, read off real installs on 2026-10-19 and told apart by route: a
# bundle id for the desktop agent, a ~/.local/bin launcher for the coding agent. The launcher
# fetches the binary beside it under a versioned name, and the launcher alone finds it.
_c, _u = _claims(_kind("file", "/Users/dana/.local/bin/muse",
                       "/home/dana/.local/bin/muse-bin-1.4.10-R6427.1",
                       "/home/dana/.local/bin/amuse", "/home/dana/.muse/",
                       "/home/dana/.local/bin/musescore",
                       "/home/dana/.local/bin/museum"))
check("Muse Code is its launcher; the versioned binary beside it is evidence, not a value",
      _c.get("/Users/dana/.local/bin/muse") == "muse-code"
      and "/home/dana/.local/bin/muse-bin-1.4.10-R6427.1" in _u, f"got {_c}")
check("the anchor is the front: `amuse` claims nothing, and ~/.muse is not a value",
      "/home/dana/.local/bin/amuse" in _u and "/home/dana/.muse/" in _u,
      "~/.muse appears on first run, which no scenario does, so it stays evidence")
# `binaries` names the path itself, so a MuseScore alias is not Muse Code.
check("...and neither a `musescore` alias nor a tool named `museum` is claimed",
      {"/home/dana/.local/bin/musescore", "/home/dana/.local/bin/museum"} <= set(_u),
      f"got {_c}")
_c, _u = _claims(_kind("app", "com.meta.endo", "org.sparkle-project.Sparkle.Updater"))
check("Muse for Mac is its bundle id and not the coding agent",
      _c == {"com.meta.endo": "muse-desktop"}, f"got {_c}")
check("the updater bundled inside it claims nothing",
      "org.sparkle-project.Sparkle.Updater" in _u,
      "Sparkle ships inside Muse.app; a nested bundle is not a second agent")

# --- provenance in `perms` is not a permission ---------------------------------------
# A consumer that splits `perms` on commas lists `sideloaded:<sha256>` as a permission.
# split_perms() is the one place the tokens are named, so it is held to the SQL that emits
# them: a token added to browser.sql and not here would read as a permission downstream.
_cspec = _ilu.spec_from_loader("classify",
    _ilm.SourceFileLoader("classify", str(ROOT / "bin" / "classify")))
_cl = _ilu.module_from_spec(_cspec)
_cspec.loader.exec_module(_cl)

check("split_perms keeps permissions and the <all_urls> flag",
      _cl.split_perms("tabs,storage,<all_urls>") == (("tabs", "storage", "<all_urls>"), ""))
check("...and splits off `unreferenced`",
      _cl.split_perms("tabs,unreferenced") == (("tabs",), "unreferenced"))
check("...but only `unreferenced` whole: a permission that merely begins with it stays one",
      _cl.split_perms("tabs,unreferenced-extra") == (("tabs", "unreferenced-extra"), ""))
check("...and `sideloaded:` with its hash",
      _cl.split_perms("tabs,<all_urls>,sideloaded:ab12") == (("tabs", "<all_urls>"), "sideloaded:ab12"))
check("...including when there is no permission before it",
      _cl.split_perms(",unreferenced") == ((), "unreferenced"))
check("...and an empty or missing `perms` is no permissions and no provenance",
      _cl.split_perms("") == ((), "") and _cl.split_perms(None) == ((), ""))

# That PERMS_PROVENANCE names exactly the tokens the osquery binding's browser.sql appends is
# checked in osquery/test/lint.sh: the binding reads the matcher, and not the other way round.

_ext = {"kind": "ext", "id": "fcoeoabgfenejglbffodgkkbkcdhcgfn", "ver": "1.0.94",
        "loc": "/Users/x/Library/Application Support/Google/Chrome/Default",
        "extra": "chrome", "perms": "tabs,unreferenced"}
with _tf2.NamedTemporaryFile("w", suffix=".json", delete=False) as _fh5:
    json.dump([_ext], _fh5)
_ptxt = subprocess.run([sys.executable, str(ROOT / "bin" / "classify"), _fh5.name],
                       capture_output=True, text=True, check=True).stdout
check("the text report marks an unreferenced extension on its row",
      "fcoeoabgfenejglbffodgkkbkcdhcgfn  1.0.94   <- unreferenced" in _ptxt, _ptxt)
# osquery's own spelling: chrome_extensions.permissions is joined with ", ", and
# browser.sql's tokens follow with "," -- read off a real Chrome profile, osquery 5.23.1.
check("split_perms strips the space osquery puts after each comma",
      _cl.split_perms("background, contextMenus, storage,<all_urls>,sideloaded:ab12")
      == (("background", "contextMenus", "storage", "<all_urls>"), "sideloaded:ab12"))

# --- a value under a route that borrows another's is never read ----------------------
_reg = _vc.load_routes()
_bre = _vc.borrowed_route_errors
check("validate_catalog refuses a value listed under a `values_from` route",
      any("bundle_ids" in e for e in _bre("probe", {"running_apps": ["com.x"]}, _reg)),
      str(_bre("probe", {"running_apps": ["com.x"]}, _reg)))
check("...and passes the same value under the route it borrows from",
      _bre("probe", {"bundle_ids": ["com.x"]}, _reg) == [])
check("...and refuses the key empty too: present, it says the route is declared here",
      any("bundle_ids" in e for e in _bre("probe", {"running_apps": []}, _reg)))

# --- the registry, made true: each rule refuses its case and passes its control -------
_rve = _vc.route_value_errors
check("validate_catalog refuses a bare string where a list belongs, which iterates by letter",
      any("non-empty list" in e for e in _rve("probe", {"npm": "openclaw"}, _reg)))
check("...and an empty list, a route that claims nothing",
      any("non-empty list" in e for e in _rve("probe", {"npm": []}, _reg)))
check("...and passes a list of strings", _rve("probe", {"npm": ["openclaw"]}, _reg) == [])
check("a retired route may carry no values",
      any("retired" in e for e in _rve("probe", {"ports": ["18789"]}, _reg)))
_ie = _vc.image_errors
check("an images value must be written as the matcher normalises it",
      any("normalises" in e for e in _ie("probe", {"images": ["docker.io/paulgauthier/aider"]},
                                         _cl.image_repo)))
check("...and the normalised form passes",
      _ie("probe", {"images": ["paulgauthier/aider"]}, _cl.image_repo) == [])
_oe = _vc.overlap_errors
check("a home-prefix value that claims another agent's path is refused",
      bool(_oe([{"id": "a", "binaries": ["~/.local/bin/kiro"]},
                {"id": "b", "binaries": ["~/.local/bin/kiro/x"]}], _reg)))
check("...but not a sibling name, which home-prefix does not claim",
      _oe([{"id": "a", "binaries": ["~/.local/bin/kiro"]},
           {"id": "b", "binaries": ["~/.local/bin/kiro-cli"]}], _reg) == [])
check("a launchd prefix covering another agent's label is refused",
      bool(_oe([{"id": "a", "launchd_prefixes": ["ai."]},
                {"id": "b", "launchd_prefixes": ["ai.openclaw."]}], _reg)))
check("...and within one agent it is allowed",
      _oe([{"id": "a", "launchd_prefixes": ["ai.", "ai.openclaw."]}], _reg) == [])
check("an exact value equal to another agent's on a different route of the same kind is refused",
      bool(_oe([{"id": "a", "bundle_ids": ["com.example.agent"]},
                {"id": "b", "npm": ["com.example.agent"]}], _reg)))
check("...and distinct exact values on those routes pass",
      _oe([{"id": "a", "bundle_ids": ["com.example.agent"]},
           {"id": "b", "npm": ["example-agent"]}], _reg) == [])
check("a path that claims another agent's pipx or uv directory is refused",
      bool(_oe([{"id": "a", "binaries": ["~/.local/share/uv/"]},
                {"id": "b", "pypi": ["agent-chat"]}], _reg)))
_lse = _vc.live_superseded_errors
check("a superseded value a run still observes is refused: it is current",
      bool(_lse("a", {"superseded": [{"route": "npm", "value": "x"}]},
                {("a", "npm", "x"): {"21-cli-agents-homebrew"}})))
check("...and one no run observes passes",
      _lse("a", {"superseded": [{"route": "npm", "value": "x"}]}, {}) == [])
_ve = _vc.version_errors
check("the catalog version must equal bin/classify's",
      bool(_ve({"version": 1}, 2)) and _ve({"version": 2}, 2) == [])
_vr = _vc.validate_registry
check("a route with no binding is refused: nothing would collect its rows",
      any("no binding" in e for e in _vr({"platforms": ["darwin"], "routes": {
          "x": {"platform": "darwin", "kind": "app", "match": "exact"}}})))
check("...and a binding missing a field",
      any("exactly" in e for e in _vr({"platforms": ["darwin"], "routes": {
          "x": {"platform": "darwin", "kind": "app", "match": "exact",
                "osquery": {"table": "apps"}}}})))
check("the real registry binds every route", _vr(_reg) == [], str(_vr(_reg)))
for _flag in ("live", "retired"):
    check(f"`{_flag}` must be a boolean: the string 'false' is true when read",
          any(f".{_flag} must be true or false" in e for e in _vr({"platforms": ["darwin"], "routes": {
              "x": {"platform": "darwin", "kind": "proc", "match": "exact", _flag: "false",
                    "osquery": {"table": "processes", "min_osquery": "5.10.0"}}}})))
_ce = _vc.classification_errors
check("a classification is a name AND a definition: a bare name is refused",
      bool(_ce({"classifications": ["Coding agent"]})))
check("...and one declared twice",
      bool(_ce({"classifications": [{"name": "A", "definition": "x"},
                                     {"name": "A", "definition": "y"}]})))
check("...and the real catalog's pass", _ce(_yaml3.safe_load(
      (ROOT / "catalog" / "agents.yaml").read_text())) == [])
check("a trailing `*` is refused: an exact route matches exactly",
      any("`*`" in e for e in _rve("probe", {"npm": ["@modelcontextprotocol/*"]}, _reg)))

# --- what the matcher takes from the registry rather than from itself ------------------
_mini = {"platforms": ["darwin"], "routes": {
    "a": {"platform": "darwin", "kind": "app", "match": "exact"},
    "b": {"platform": "darwin", "kind": "proc", "match": "exact", "live": True},
    "c": {"platform": "darwin", "kind": "file", "match": "tool-dir"}}}
check("live kinds are the kinds of routes marked `live`, and only those",
      _cl.Registry(_mini).live_kinds == {"proc"}, str(_cl.Registry(_mini).live_kinds))
check("the tool-dir bridge names the tool-dir routes and no npm route",
      _cl.Registry(_mini).bridged() == ["c"]
      and _cl.Registry(_reg).bridged() == ["pypi"], str(_cl.Registry(_reg).bridged()))

# --- the row that speaks for a finding ----------------------------------------------
# One rule for every consumer, so each one does not pick its own. Rows are the real shapes:
# dpkg's row off an apt install of Claude Code (Ubuntu 22.04), osquery's chrome_extensions
# rows, and a node process running an npm global.
_rank = _cl.kind_rank(_cl.load_routes())


def _r(kind, ident, ver="", loc="", perms=""):
    return {"kind": kind, "id": ident, "ver": ver, "loc": loc, "extra": "", "perms": perms}


_claude_deb = [_r("file", "/home/u/.claude/", loc="/home/u/.claude/"),
               _r("deb", "claude-code", "2.1.292-1")]
check("an install record speaks before a state directory declared ahead of it",
      _cl.describe(_claude_deb, _rank) == {"primary": 1, "version": "2.1.292-1"},
      str(_cl.describe(_claude_deb, _rank)))
check("...the order this rule overrides: `file` is declared ahead of `deb`",
      _rank["file"] < _rank["deb"], str(_rank))
_live = [_r("proc", "@openai/codex", loc="/usr/bin/node"),
         _r("npm", "@openai/codex", "0.150.1", "/usr/lib/node_modules/@openai/codex")]
check("presence speaks before liveness, and a running row's path is never the install's",
      _cl.describe(_live, _rank)
      == {"primary": 1, "version": "0.150.1", "path": "/usr/lib/node_modules/@openai/codex"},
      str(_cl.describe(_live, _rank)))
_native = [_r("proc", "/home/u/.local/share/claude/versions/2.1.292",
              loc="/home/u/.local/share/claude/versions/2.1.292"),
           _r("file", "/home/u/.local/bin/claude", loc="/home/u/.local/bin/claude")]
check("...and when neither carries a version and `proc` is declared ahead of `file`",
      _cl.primary(_native, _rank) == 1 and _rank["proc"] < _rank["file"], str(_rank))
_profile = "/Users/x/Library/Application Support/Google/Chrome/Default"
_exts = [_r("ext", "fcoeoabgfenejglbffodgkkbkcdhcgfn", "1.0.90", _profile, "tabs,unreferenced"),
         _r("ext", "fcoeoabgfenejglbffodgkkbkcdhcgfn", "1.0.94", _profile, "tabs")]
check("a loaded extension speaks before a leftover version directory",
      _cl.primary(_exts, _rank) == 1)
_brew = _r("brew", "claude", "1.2.3", "/opt/homebrew/Caskroom/claude")
_app = _r("app", "com.anthropic.claudefordesktop", "", "/Applications/Claude.app")
check("the KIND decides: a bundle that declares no version still speaks before its cask",
      _cl.describe([_brew, _app], _rank)
      == {"primary": 1, "path": "/Applications/Claude.app"},
      str(_cl.describe([_brew, _app], _rank)))
check("...and between two install records, kind_rank: the bundle id before the cask",
      _cl.primary([_brew, dict(_app, ver="1.2.3")], _rank) == 1 and _rank["app"] < _rank["brew"])
_loaded_blank = _r("ext", "fcoeoabgfenejglbffodgkkbkcdhcgfn", "", _profile, "tabs")
check("a loaded copy speaks before a leftover even when only the leftover has a version",
      _cl.primary([_exts[0], _loaded_blank], _rank) == 1)
_old_new = [_r("app", "com.clawdbot.mac", "2026.1.1", "/Applications/Clawdbot.app"),
            _r("app", "ai.openclaw.mac", "2026.7.1", "/Applications/OpenClaw.app")]
check("a current identifier speaks before one the vendor replaced",
      _cl.primary(_old_new, _rank, [True, False]) == 1
      and _cl.primary(_old_new, _rank) == 0)
check("...but a replaced identifier still speaks when it is the only install record",
      _cl.primary([_r("file", "/Users/u/.openclaw/"), _old_new[0]], _rank, [False, True]) == 1)
check("a container's state is never reported as a version",
      "version" not in _cl.describe([_r("container", "x/y:1", "running", "abc123")], _rank))
check("ties keep evidence order",
      _cl.primary([_r("file", "/home/u/.a/"), _r("file", "/home/u/.b/")], _rank) == 0)
check("every kind that carries a version or a path is a registered kind",
      (_cl.VERSION_KINDS | _cl.PATH_KINDS) <= set(_rank),
      str(sorted((_cl.VERSION_KINDS | _cl.PATH_KINDS) - set(_rank))))
with _tf2.NamedTemporaryFile("w", suffix=".json", delete=False) as _fh6:
    json.dump(_claude_deb, _fh6)
_pj = json.loads(subprocess.run(
    [sys.executable, str(ROOT / "bin" / "classify"), _fh6.name, "--json"],
    capture_output=True, text=True, check=True).stdout)
_pf = {f["id"]: f for f in _pj["findings"]}.get("claude-code", {})
check("--json names the primary row and carries its version",
      _pf.get("primary") == 1 and _pf.get("version") == "2.1.292-1" and "path" not in _pf,
      json.dumps(_pf))

print()
if failures:
    print(f"matcher: FAIL ({len(failures)})")
    sys.exit(1)
print("matcher: PASS")
