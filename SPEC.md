# Open Agent Detection Format

Version 0.1.0. Draft.

The Open Agent Detection Format describes how to tell whether an AI agent is installed or
running on a computer. It defines what a catalog of agents contains, what evidence a collector
reports, and how a matcher pairs the two. Its goal is that a catalog, a collector and a matcher
written by different people give the same answer about the same machine.

## 1. Introduction

Existing agent standards describe agents that someone chose to register, such as A2A Agent
Cards, the Open Agentic Schema Framework and the CSA Agent Registry. Others describe what an
agent is built from, such as CycloneDX AI-BOM and SPDX AI. Neither kind answers the question an
endpoint inventory asks: is this software on this machine? The agents an inventory most needs to
find are the ones nobody registered.

This format answers that question from evidence the machine already holds: an application's
bundle identifier, a package in a package manager's database, a browser extension's id, a
directory an agent creates when it first runs. A catalog lists those identifiers for each agent
and says how each one is matched. A collector, called a binding, reports what it found as rows.
A matcher pairs the rows with the catalog.

Two properties shape everything else:

1. **An empty result is never ambiguous.** A binding that could not read a source says so, so
   "nothing found" and "nothing looked at" are different answers (§5.2).
2. **Every identifier carries its proof.** An identifier enters a catalog only after an
   installation of the real software produced it, and the catalog records which installation
   (§7).

## 2. Conventions

The key words MUST, MUST NOT, REQUIRED, SHOULD, SHOULD NOT, MAY and OPTIONAL are to be
interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in capitals.

| term | meaning |
|---|---|
| agent | software that acts on a user's behalf (§3) |
| catalog | a document listing agents and how to recognise them (§4) |
| route | one way an agent's identity reaches a binding, such as a package name in npm's global packages |
| identifier | a value on a route, such as `@anthropic-ai/claude-code` on an `npm` route |
| binding | a way of collecting evidence for routes, such as osquery (§8) |
| evidence row | one thing a binding observed (§5.1) |
| scan marker | an evidence row that reports on a source rather than on what the source contains (§5.2) |
| matcher | software that pairs evidence rows with a catalog's identifiers (§6) |
| finding | one agent a matcher found, with the rows that prove it (§6.6) |

## 3. Scope: what counts as an agent

An agent is software that acts on the user's behalf. That is the whole test. A conforming catalog
MUST NOT list software that fails it, however easy that software is to detect, because counting
it among the agents found on a machine overstates the finding.

These classes fail the test:

| class | why it is not an agent |
|---|---|
| a library an agent is built with | detecting it says a developer imported a protocol |
| a gateway an agent calls through | detecting it says traffic may be proxied |
| a container or language runtime | it is how a binding looks, not what it looks for |
| a model runner | it serves models; an agent is what drives one |
| a completion engine | it suggests, and the user accepts |

A catalog declares its own classification vocabulary, with a definition for each term (§4.2).
This version does not fix that vocabulary.

## 4. Catalog

A catalog is a JSON document that validates against `schema/catalog.schema.json`. A consumer
MUST reject a catalog that does not.

### 4.1 Document

| member | |
|---|---|
| `format` | REQUIRED. `ai-detection-spec/<major>.<minor>`; this version is `ai-detection-spec/0.1` |
| `platforms` | REQUIRED. The platform names a route may use: `darwin`, `linux`, `windows` |
| `platform_groups` | REQUIRED. A name for a set of platforms. `posix` is `darwin` and `linux` |
| `classifications` | REQUIRED. §4.2 |
| `routes` | REQUIRED. §4.3 |
| `agents` | REQUIRED. §4.4 |
| `removed` | OPTIONAL. Software the catalog once listed and removed for failing §3, as `{id, what_it_is}`, so that the reason survives the entry |
| `source` | OPTIONAL. Where the document was produced from, for a reader who needs to trace it |

### 4.2 Classifications

A list of `{name, definition}`. Names MUST be unique. Every agent's `classification` MUST be one
of the names.

### 4.3 Routes

`routes` maps a route name to:

| member | |
|---|---|
| `kind` | REQUIRED. The evidence row kind that carries the route (§5.1) |
| `match` | REQUIRED. How an identifier is compared with a row (§6.4) |
| `platform` | REQUIRED. A platform or platform group. Where the route's evidence is collected; it does not filter matching (§6.2) |
| `bindings` | REQUIRED. At least one binding's fields for this route (§8). A route no binding feeds can match nothing |
| `values_from` | OPTIONAL. Another route whose identifiers this route matches, instead of its own (§6.3) |
| `live` | OPTIONAL. `true` when a row of this route says the agent is running, not only installed (§6.6) |
| `retired` | OPTIONAL. `true` when the route identifies nothing. Its kind stays registered, because evidence of that kind is still collected (§6.1) |
| `value_pattern` | OPTIONAL. A regular expression every identifier on the route MUST match in full |

### 4.4 Agents and identifiers

An agent is `{id, name, classification, platforms, identifiers}`. `id` is lowercase, with
hyphens. `platforms` lists the platforms the agent can be found on. `identifiers` is a non-empty
list of `{route, value, status}`, with the optional members described in §7.

A conforming catalog MUST meet all of these:

1. An identifier's `route` exists, and is not a route with `values_from`: an identifier sits
   on the route that owns it.
2. No identifier sits on a retired route.
3. Each of the agent's routes is available on at least one of its platforms, and each of its
   platforms has at least one of its routes.
4. A value on a `home-dir` or `home-prefix` route starts with `~/`.
5. A value on an `exact-normalised` route is already in normalised form (§6.4.3).
6. **No two agents claim the same row.** No value of one agent may match a row that a value of
   another agent matches on a route of the same kind. This covers equal values, and also
   containment: a `prefix` value that another agent's value starts with, or a `home-prefix`
   value that another agent's path sits under. Because of this rule, the order in which a
   matcher tries identifiers (§6.5) can never decide which agent a row belongs to.

## 5. Evidence

### 5.1 Evidence rows

A binding reports a JSON array of objects that validates against
`schema/evidence.schema.json`. Each object is one row:

| member | |
|---|---|
| `kind` | REQUIRED. What sort of thing was observed, matching some route's `kind` |
| `id` | REQUIRED. The identifier, in the form that route compares |
| `loc` | Where it lives, usually a path |
| `ver` | Its version, where the source records one |
| `extra` | Kind-specific detail |
| `perms` | Kind-specific capabilities, such as a browser extension's permissions |

A member that is not present reads as the empty string. Every value is a string. A binding MAY
add members, and a matcher MUST ignore members it does not know.

### 5.2 Scan markers

A row of kind `scan` reports on a source rather than on what the source contains. Its `id` names
the source, such as a query or a container daemon. `ver` is the time the source was read, in
unix seconds. `loc` MAY say where the source was looked for. `extra` is the outcome:

| outcome | meaning |
|---|---|
| `ok` | the source was read, and its rows are in the payload |
| `absent` | the binding read the machine, and nothing of the source's kind is there |
| `error` | reading the source failed |
| `no-cache` | a cached payload was asked for and none existed |
| `unreadable:<runtime>` | the source exists in a form the binding does not read, named |
| `unhealthy:<code>` | the source answered with a failure status |
| `timeout:<seconds>` | reading was stopped after the given bound |

1. **A binding MUST NOT report a source it could not read as a source with nothing in it.** When
   reading fails, it MUST emit a scan marker whose outcome is neither `ok` nor `absent`.
2. A binding SHOULD emit an `ok` marker for each source it read.
3. A binding MUST use `absent` only when it read the machine and found nothing of the source's
   kind. A source that is present and that it did not read is `unreadable:<runtime>`. Declining
   to look and finding nothing MUST NOT share a word.
4. The vocabulary above is closed in this version. `schema/evidence.schema.json` declares it, and
   adding an outcome is a change to the format (§10).
5. A binding does not judge staleness. A reader computes a marker's age from `ver` and applies
   its own threshold.

## 6. Matching

A matcher takes a catalog and a list of evidence rows. It reports findings, unmatched rows,
dropped rows, and the scan markers sorted into three groups (§6.7).

### 6.1 Rows and kinds

A row is compared only with routes of its own kind.

- A row of kind `scan` is a scan marker (§5.2). It is never evidence for an agent.
- A row whose kind no route in the catalog declares is **dropped**. A matcher MUST count dropped
  rows and SHOULD report the count. A kind missing from a catalog otherwise makes evidence
  vanish without a trace.
- A row whose kind is declared, but that no identifier matches, is **unmatched**. A matcher
  SHOULD be able to list unmatched rows on request.

Retired routes still declare their kind, so rows of that kind are unmatched rather than
dropped.

### 6.2 Platform does not filter

A route's `platform` says where its evidence is collected. A matcher MUST NOT discard a row
because of the platform it came from. Rows from several platforms may be matched in one run.

### 6.3 Routes that read another route's values

A route with `values_from: R` matches the identifiers that sit on `R`, and has none of its own.
An identifier matched this way keeps the status it has on `R`.

### 6.4 Match modes

Every comparison is case-sensitive.

#### 6.4.1 `exact`

The row's `id` equals the identifier.

#### 6.4.2 `prefix`

The row's `id` starts with the identifier.

#### 6.4.3 `exact-normalised`

For container image repositories. The row's `id` is a comma-separated list of image references.
Each item is trimmed of surrounding whitespace, empty items are dropped, and each remaining
item is normalised. The identifier matches if it equals any normalised item. To normalise a
reference:

1. Remove leading and trailing whitespace.
2. Remove the tag: everything from the last `:` onwards, if that `:` comes after the last `/`.
   A `:` before the last `/` belongs to a registry port.
3. Remove the first of these prefixes that is present: `docker.io/`, `index.docker.io/`,
   `registry-1.docker.io/`.
4. If what remains is `library/` followed by a name with no further `/`, remove `library/`.

A catalog writes these identifiers already normalised (§4.4). This version does not define
digest references (`@sha256:…`), so they do not match.

#### 6.4.4 `home-dir`

The identifier is `~/` followed by a path `P`. It matches a row whose `id` or `loc` is `H` + `P`,
or `H` + `P` + `/`, for any home root `H` (§6.4.7). It does not match anything below `P`, or a
name that only starts with `P`.

#### 6.4.5 `home-prefix`

The identifier is `~/` followed by a path `P`. It matches a row whose `id` or `loc` is `H` + `P`,
or starts with `H` + `P` + `/`. When `P` ends with `/`, it matches anything that starts with
`H` + `P`. It does not match a name that only starts with `P`: `~/.local/bin/tool` does not
match `~/.local/bin/tool-helper`.

#### 6.4.6 `tool-dir`

For packages installed by pipx or uv, which give each tool a directory named after its
distribution. A row of the route's kind whose `id` or `loc` is `H` + `.local/pipx/venvs/<name>`
or `H` + `.local/share/uv/tools/<name>`, optionally followed by `/`, yields `<name>`. The route
matches when `<name>` equals one of its identifiers.

#### 6.4.7 Home roots

The home roots are `/Users/<segment>/`, `/home/<segment>/` and `/root/`, where `<segment>` is
one or more characters other than `/`. A matcher MUST try all three for every row, whatever
platform the row came from.

#### 6.4.8 Unknown modes

A matcher MUST stop with an error when a catalog declares a match mode it does not implement.
Skipping the route would match nothing, silently.

### 6.5 Evaluation order

For each row that is not a scan marker:

1. If the row's kind is the kind of a `tool-dir` route and its `id` or `loc` is a tool directory
   (§6.4.6), its name is looked up on the `tool-dir` routes. A match ends the search.
2. Otherwise, the row is tried on each `exact-normalised` route of its kind.
3. Otherwise, it is tried on each remaining route of its kind, in the catalog's route order. For
   each route, the `exact` identifiers are tried first, then `prefix`, then `home-dir` and
   `home-prefix`, each in the order the agents appear.

The first identifier that matches assigns the row to that identifier's agent. A row belongs to
at most one agent. In a conforming catalog, the order decides only which identifier is
credited, never which agent (§4.4, rule 6).

### 6.6 Findings

For each agent with at least one matched row, a matcher reports a finding with:

- the agent's `id`, `name` and `classification`;
- `evidence`: the matched rows, unchanged and in input order;
- `running: true`, when any evidence row has the kind of a `live` route;
- `superseded`: the `id`s of the evidence rows matched by a superseded identifier, and
  `only_superseded: true` when every evidence row was. Both appear only when at least one row
  was matched by a superseded identifier.

Findings are reported in order of agent `id`. A superseded identifier still produces a finding:
a matcher MUST NOT withhold or downgrade it (§7.1). A matcher MAY add members.

### 6.7 Scans, absences and gaps

A matcher sorts scan markers into three groups and reports each one:

| group | outcomes | what it means for the findings |
|---|---|---|
| scans | `ok` | the source was read; its age comes from `ver` |
| absences | `absent` | the source was read, and nothing was there |
| gaps | anything else | the source was not read; the findings are incomplete |

A matcher MUST NOT present findings as complete while a gap is open.

## 7. Provenance

### 7.1 Status

Every identifier has a status:

| status | meaning |
|---|---|
| `current` | installing the software today produces this identifier |
| `superseded` | an installation once produced it, and the release installed today no longer does |

An identifier that no installation of the real software has produced MUST NOT be in a catalog.
There is no third status. A superseded identifier stays in the catalog and keeps matching,
because machines that have not updated still carry it, and those are the machines an inventory
most needs to name.

### 7.2 Proof

An identifier MAY carry `proof`: the observations that produced it. Each one is:

| member | |
|---|---|
| `binding` | REQUIRED. The binding whose rows produced the identifier |
| `scenario` | REQUIRED. The installation procedure that produced it |
| `platform` | REQUIRED. The platform it ran on |
| `run` | REQUIRED. The identifier of that execution |
| `os`, `arch` | The operating system release and architecture, as the machine reported them |
| `agent_version` | The software's version, where the row carried one |

A superseded identifier carries `superseded`: `{last_version, last_proved, by, run}`. These name
the last release that produced it, the date of that proof, and the procedure and execution that
proved it.

A catalog distributed for others to use MUST give every `current` identifier at least one proof.

### 7.3 Proof belongs to a binding

A proof holds only for the binding that produced it. An identifier proved by one binding is not
proved for another, which may read a different source.

### 7.4 Consistency

A superseded identifier MUST NOT be produced by a current proof. If an installation still
produces it, it is current.

### 7.5 What is not proved

A `running` finding says that a route marked `live` matched. This version does not record proof
that a given identifier appears in a live route's rows.

## 8. Bindings

A binding collects evidence rows for the routes it binds. A conforming binding:

1. emits rows as described in §5.1, of the kinds of the routes it binds;
2. emits scan markers as described in §5.2;
3. declares, under `bindings.<name>` on each route it binds, the fields it needs;
4. proves identifiers as described in §7, from its own rows and from installations of the real
   software.

### 8.1 osquery

The binding named `osquery` declares two fields on each route:

| field | |
|---|---|
| `table` | The osquery table the route's evidence comes from |
| `min_osquery` | The lowest osquery version whose `table` provides what the route needs |

## 9. Conformance

- **A catalog conforms** when it validates against `schema/catalog.schema.json` and meets every
  requirement in §3, §4 and §7.
- **A matcher conforms** when it meets §6 and produces the expected result for every vector in
  `conformance/vectors.json`.
- **A binding conforms** when its output validates against `schema/evidence.schema.json` and it
  meets §8.

Each vector names the section it tests. It carries a catalog, a list of rows and the expected
result:

- which agent each row belongs to, if any;
- which rows are unmatched or dropped;
- how the scan markers are grouped;
- the `running` and `superseded` members of the findings.

Every match mode has at least one row that must match and one that must not.

## 10. Versioning

The `format` member carries the major and minor version. This document is version 0.1.0.

- A change that alters what a conforming matcher reports for an existing catalog and rows, or
  that removes or renames a member, increases the major version.
- An addition that leaves every existing result unchanged increases the minor version.
- A clarification that changes no requirement increases the patch version.

A consumer MUST reject a document whose major version it does not support. While the major
version is 0, a minor version may also contain breaking changes.
