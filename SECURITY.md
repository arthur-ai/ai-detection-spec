# Security

## Reporting a vulnerability

Email **security@arthur.ai**. You will get an acknowledgement within five working days.

Please include what you found, how to reproduce it, and how you would like to be credited. We
will tell you when a fix ships and will not disclose your report before then without asking you.

## Reporting a detection gap or an evasion

This is a discovery tool, so a second class of report matters as much as a vulnerability: **an
AI agent it fails to find.**

- **An agent we simply do not know about** is not sensitive. Open a public issue using the
  *Detection gap* template. That is the ordinary way this catalog improves.
- **A technique that deliberately evades detection** is different. Email security@arthur.ai
  rather than opening an issue, and we will work out disclosure with you.

The distinction is between *"you missed this tool"* and *"here is how to hide any tool"*.

## What this project is not

It has **no runtime and no service**, and **nothing it puts on an endpoint makes a network
call**. What runs there is SQL that osquery executes, plus a catalog of identifiers. There is
no agent to compromise and no endpoint to attack.

One part does talk to the network, and it is not on the endpoint: `bin/classify` sends an
anonymous usage event per run from wherever an operator runs it. It carries counts and no
identifiers, `AI_DISCOVERY_TELEMETRY=0` disables it, and
[`docs/telemetry.md`](docs/telemetry.md) lists every field it can contain.

The realistic security question is therefore not "can this be exploited" but **"can this be made
to lie"**, and the answer shapes what we treat as severe:

| Concern | Severity |
|---|---|
| A signature that matches software it should not, creating false findings across a fleet | **High.** Wrong data people act on |
| A query that reads something outside its stated scope, such as file contents or credentials | **High.** Breaks the promise the README makes |
| A query that stalls long enough to be dropped by its caller, reporting nothing | **High.** Silence reads as a clean machine |
| Telemetry carrying anything beyond the counts `docs/telemetry.md` lists — a path, a hostname, an identifier, an exception message | **High.** That page is the promise, and `test/test_telemetry.py` is what keeps it |
| A missing signature for a known tool | Ordinary issue, not a vulnerability |

That third row is the one people underrate. A scan that times out and a scan that finds nothing
look identical to whatever consumes the output, so a performance regression here is a
correctness bug.

## Supported versions

The latest tagged release. Signatures change weekly, so pin a version and update deliberately
rather than tracking `main`.
