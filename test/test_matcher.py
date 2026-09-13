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
check("finds it across all four of its routes",
      len(found.get("openclaw", {}).get("evidence", [])) == 4,
      f"got {len(found.get('openclaw', {}).get('evidence', []))}")
check("the retired bot.molt.mac alias still resolves to OpenClaw",
      any(e["id"] == "bot.molt.mac" for e in found.get("openclaw", {}).get("evidence", [])))
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
# fixes a wedged daemon differently from a machine that has no Docker, and differently
# again from a writer that was never installed.
#
# `error` IS IN THIS LIST NOW, and it is the one that was missing. bin/discover emits it
# for every non-container branch that ran and failed, and the renderer had no case for
# it, so it fell through to a generic sentence that substituted "the socket" as the
# place -- naming a socket that had nothing to do with a failed `apps` query.
for extra, needle in (("absent", "no socket"),
                      ("no-cache", "never run"),
                      ("error", "ran and failed"),
                      ("unhealthy:500", "answered 500"),
                      ("timeout:6", "stalled")):
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
for extra in ("absent", "error", "timeout:6"):
    check(f"{extra!r} claims no platform",
          "this Mac" not in classify_rows([scan_row(extra)]),
          "a matcher over a mixed-platform payload cannot know the platform")

check("a gap is never silently an empty finding set",
      "No AI agents found." not in classify_rows([scan_row("timeout:6")]),
      "'no agents' under an unread branch is the lie this whole marker exists to stop")

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

# THE OTHER HALF, and the reason the `$` is not a blanket fix: `binaries` is
# front-anchored ON PURPOSE. One `uv tool install hermes-agent` writes hermes, hermes-acp
# and hermes-agent, and all three are the same install.
for cmd in ("/Users/alice/.local/bin/hermes", "/home/alice/.local/bin/hermes-acp",
            "/root/.local/bin/hermes-agent"):
    check(f"a sibling command still lands on the agent ({cmd})",
          _ids(_rows(cmd)) == {"hermes"},
          "anchoring home-prefix would lose two of the three commands")

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

# The systemd marker is a gap, not a finding, and an unreadable unit list must not read as
# a clean one. This is the branch a container exercises and a CI runner never will.
_scan = [{"kind": "scan", "id": "systemd", "ver": str(int(_time.time())),
          "loc": "/run/dbus/system_bus_socket", "extra": "absent", "perms": ""}]
_txt = classify_rows(_scan)
check("an unreadable systemd unit list is a gap, not silence",
      "COULD NOT LOOK: systemd" in _txt
      and "No AI agents found in the parts that could be read." in _txt,
      "zero units with no bus is indistinguishable from a clean host without this")

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

# --- running containers and vendor labels ------------------------------------------
# The two routes added beside `images`, and the reason both exist: a tag is chosen by
# whoever ran `docker tag`, a label is written by the vendor, and a running container says
# something no other route in this repo can say about anything.
#
# Rows are shaped exactly as queries/containers.sql emits them, and every id below was
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

print()
if failures:
    print(f"matcher: FAIL ({len(failures)})")
    sys.exit(1)
print("matcher: PASS")
