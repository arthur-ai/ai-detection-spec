# Security

## Reporting a vulnerability

Email **security@arthur.ai**. You will get an acknowledgement within five working days.

Please include what you found, how to reproduce it, and how you would like to be credited. We
will tell you when a fix ships and will not disclose your report before then without asking you.

## Reporting a detection gap or an evasion

This project exists to find agents, so a second class of report matters as much as a
vulnerability: **an AI agent it fails to find.**

- **An agent we do not know about, or one we know and miss**, is not sensitive. Open a public
  issue with the *New AI agent* or the *Detection gap* template.
- **A technique that deliberately evades detection** is different. Email security@arthur.ai
  rather than opening an issue, and we will work out disclosure with you.

The distinction is between *"you missed this tool"* and *"here is how to hide any tool"*.

## What this project is not

It has **no runtime and no service**. What it puts on an endpoint is the osquery binding: SQL
that osquery executes and the bash scripts that run it, none of which makes a network call.
There is no agent to compromise and no endpoint to attack.

One part does talk to the network, off the endpoint: `bin/classify` sends one anonymous usage
event per run. [`docs/telemetry.md`](docs/telemetry.md) lists every field and how to turn it
off.

The realistic security question is therefore not "can this be exploited" but **"can this be made
to lie"**, and the answer shapes what we treat as severe:

| Concern | Severity |
|---|---|
| An identifier that matches software it should not, creating false findings across a fleet | **High.** Wrong data people act on |
| A query that reads something outside its stated scope, such as file contents or credentials | **High.** Breaks the promise [osquery/README.md](osquery/README.md#what-it-collects-and-what-it-does-not) makes |
| A query that stalls long enough to be dropped by its caller, reporting nothing | **High.** Silence reads as a clean machine |
| Telemetry carrying anything beyond the counts `docs/telemetry.md` lists — a path, a hostname, an identifier, an exception message | **High.** That page is the promise, and `test/test_telemetry.py` is what keeps it |
| A missing identifier for a known agent | Ordinary issue, not a vulnerability |

The third row is the one people underrate: to whatever consumes the output, a scan that timed
out and one that found nothing look identical, so a performance regression is a correctness bug.

## Supported versions

The latest tagged release. Identifiers change weekly, so pin a version and update deliberately
rather than tracking `main`.
