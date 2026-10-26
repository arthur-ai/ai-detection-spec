---
name: add-agent
description: Add an agent to catalog/agents.yaml, or a missing install route or identifier to an existing entry — decide it is an agent, read every value off a real install, prove it in a scenario that can tell it from a lookalike, record the observation, and regenerate osquery/dist/ and the docs. Use when asked to add, catalog or detect a new AI agent, tool, extension or app, or to cover another way an existing one installs.
---

# Adding an agent

The gates already refuse the mechanical mistakes: an agent no scenario installs, a value two
agents claim, a stale `osquery/dist/` or `docs/agents.md`, a scenario in no CI matrix. This skill is
for what they cannot see — whether it is an agent, whether every route is covered, whether each
value came off a real install, and whether the scenario can tell a match from a lookalike.

The rules live in `CONTRIBUTING.md` (**Adding an agent or an identifier**), the header of
`catalog/agents.yaml`, and the comment on each route in `catalog/routes.yaml`. Read those;
this is the order to apply them in.

## 1. Decide it is an agent

The test is whether it **acts on the user's behalf**: `SPEC.md` §3.

- **Check it has not been decided already.** `removed:` and the `CONSIDERED AND NEVER ADDED`
  block beneath it in `catalog/agents.yaml` both carry reasons. Do not re-litigate either
  without new evidence.
- **Judge a borderline extension or client by its package, not its listing**: what its commands
  or content scripts do. Sider and Merlin read as chat sidebars from their listings and were
  nearly left out; their bundles type into pages.
- **Something bundled with an editor** reports the editor, not a fleet's choice of agent.
  Copilot in VS Code is in `docs/blind-spots.yaml` for that reason.
- **Declined?** Add it to the considered block with the reason. `removed:` is only for entries
  the catalog once carried.
- `classification` is deployment shape, from the `classifications:` list. Not risk.

## 2. List every route before writing anything

One entry per tool, carrying **every** way it installs: cask or formula, npm, uv or pipx, the
vendor's curl installer, deb or rpm, a VS Code, JetBrains or Chrome extension, a desktop app, a
container image. A signature written for one route is blind to a fleet that used another.

- **Check whether the agent already exists**, by product name rather than id:
  `grep -n -i "<name>" catalog/agents.yaml`. A renamed product sits under its new id — Amazon Q
  Developer's CLI is `kiro-cli`, while `amazon-q` is its editor extension. A missing route on an
  existing entry is a common change, and a second entry for one tool is a duplicate.
- **Map each route to `catalog/routes.yaml`** and read that route's comment: it says which column
  the value is compared to and, where one has happened, the trap that cost an identifier
  (`vscode_extensions` is `name`, never `publisher_id`; `jetbrains_plugins` is the directory,
  not the plugin.xml id). Each route's `platform:` is there too, and the agent's `platforms:`
  must agree.
- **Not identifiers**: a generic name (Cursor writes `~/.local/bin/agent`, Grok
  `~/.grok/bin/agent`), a listening port, a package a third party publishes for the vendor's
  tool (npm `hermes-agent`). Leave them out and say why in the entry's comment, as `hermes`
  does.
- **No route reaches it** (a snap, an AppImage with no `.desktop` file): it goes in
  `docs/blind-spots.yaml`, not the catalog. A new route is a bigger change than this skill —
  `routes.yaml` plus a query — so read the `routes.yaml` header and `osquery/CLAUDE.md`'s
  *Traps* first.

## 3. Read each value off a real install

Never from vendor docs, Homebrew metadata or a store listing: the README's `bot.molt.mac` story
is why.

- The scenario in step 4 is the install. Read the value off its payload, or off `osqueryi` on a
  machine that has it, using the table the route names.
- **A command name is often not the package name.** `hermes` is `hermes-agent` on every registry;
  `aider` installs as `aider-chat`.
- **A `state_dirs` value usually needs the agent run**, not just installed. `hermes`'s comment
  records which install routes create its directory and which leave it for first run.
- **Comment each value with where it was read**: scenario, date, version and path, as the
  entries after `opencode` do. That comment is the provenance a reviewer checks.
- **If the local macOS guest cannot reach a download**, read the bundle id off the shipped
  dmg's `Info.plist` on the host, and leave what the local run could not prove for CI — then
  say so in the commit (step 6). A hang rather than an error is the usual sign: on 2026-10-07
  Tart guests on a maintainer's Mac reached IPv6 hosts only.

## 4. Prove it in a scenario

Add the agent to a scenario's `classified.must_find`. Extend an existing scenario when the route
and platform fit; start a new one when:

- **two routes install the same binary name.** They cannot share a host: npm opencode is in 71,
  its curl installer in 84.
- **the download is large.** 13 was split from 10 for Dia's download size, and a separate
  scenario is a separate CI job.
- **it is an older generation** of something another scenario installs current.

What makes the scenario prove the identifier rather than the agent:

- **The new value should be the only witness on that host.** If another route also names the
  agent there, `must_find` passes with the new value wrong. 84's `why` says this outright.
- **`classified.forbid` every agent the new rows could be mistaken for**, and the converse:
  85 forbids `cline` because `roo-cline` contains its id, and 78 forbids `claude-code` while
  installing Cline. `test/lib/assert.sh` reads the other keys (`must_contain`, `forbid_rows`,
  `forbid_evidence`).
- **Add a lookalike to `test/test_matcher.py`** and assert it is declined, where one exists — a
  generic sibling binary, an id another id contains.
- **Break it once.** Remove the value from the catalog and confirm the matcher check or the
  scenario goes red. If it stays green, it proves nothing.

Mechanics:

- `setup.sh` sources `test/lib/guest.sh` (macOS: `need_brew`, `need_node`) or
  `test/lib/guest-linux.sh` (`need_user`, `try_user`, `install_vscode_ext`,
  `install_jb_plugin`); both carry `retry`. Wrap every download and install in it; the
  helpers already do. Running out should `WARN` and continue, so the assertion names which agent is
  missing, or `exit 1` when nothing after it can run.
- `exit 3` is SKIP, for an environment that cannot host the scenario — a missing package
  family or architecture, never a failed download. Be slow to conclude even that (`CLAUDE.md`,
  *Testing*).
- **A new scenario goes in `.github/workflows/scenarios.yml`.** macOS goes in the `scenario`
  job, which runs it on both macOS labels. Linux goes in `scenario-linux` (Ubuntu) and
  `scenario-linux-container` (Debian, Rocky, Fedora, Amazon Linux); one that needs a package
  family exits 3 on the others, as 74 does off apt, and 77 is left out of the Ubuntu job
  because Ubuntu never has rpm. `tools/check_workflows.py` fails until it is listed.
- Run it: `test/run-linux.sh <name>` (Docker; `LINUX_IMAGE=quay.io/rockylinux/rockylinux:9`
  for the rpm family) or `test/run.sh <name>` (Tart). Both write `observed.json` on a pass.
  **Commit it** — `collect` only commits on `main`, so without it `docs/agents.md` reports the
  new values as uncovered until the merge.

## 5. Regenerate and run the gates

```console
$ python3 osquery/tools/build.py                  # osquery/dist/, and the rendered match files if PyYAML is present
$ python3 tools/agent_status.py --write   # docs/agents.md, docs/limits.md, README badge
$ tools/gates.sh
```

- **README's agent and identifier counts are prose**: `check_doc_numbers.py` names the line,
  and you edit it by hand.
- **Values only CI can produce show as pending**, not failed: lint runs the coverage gate with
  `--pending-ok`. That is not a pass: once the scenario has run, the coverage job re-checks
  the gate against the run's observations, merged across scenarios and platforms, and a
  value none of them produced fails there. The scenario itself fails only if the value is the
  sole witness or `must_contain` names it.
- `osquery/test/test_match_sql.py` needs `osqueryi` and SKIPs without it. CI runs it for real.

## 6. Commit

Subject in the log's style: `catalog: add <agent>`, or `catalog: read <agent> off its <route>`.
The body is what `.claude/skills/release` writes the notes from, so it says:

- where each value was read: scenario, date, version, or the shipped artifact
- which scenarios ran locally, and on what OS and image
- which identifiers are **pending CI**, and why they could not run here
- what was considered and left out, if the PR declined anything

## Don'ts

- Don't put an agent identifier in `osquery/queries/`. The endpoint enumerates; `check_no_catalog.py`
  fails the build.
- Don't write a `superseded:` record yourself. Paste the one `--supersede` prints;
  `validate_catalog.py` refuses a record no archived observation backs.
- Don't bring back `retired:`, `untested:` or `unverified:`. They are gone, and
  `validate_catalog.py` refuses all three, along with any other key no tool reads.
- Don't delete a removed entry's fixture rows. Invert the assertion to *must not match*.
- Don't write a count into a comment, a scenario header or `expected.json`'s prose. Nothing keeps
  it current.
