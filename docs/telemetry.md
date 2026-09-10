# Telemetry

`bin/classify` sends **one anonymous usage event per run** to Amplitude. Nothing else in
this repository sends anything.

```console
$ AI_DISCOVERY_TELEMETRY=0 bin/classify      # off, permanently, per run or per shell
$ bin/classify --telemetry-check < payload   # print the exact event, send nothing
```

## Why there is any at all

This project ships signatures that go stale, a deep container scan that is opt-in, and a
row-drop bug class that has already cost it months once. None of that is observable from
here. The questions this exists to answer are specific:

- Is anyone running a catalog months behind the current one?
- Does anyone turn the deep container scan on, and does it succeed when they do?
- Which gap reasons actually fire in the field — `absent`, `no-cache`, `unhealthy`,
  `timeout` — as opposed to which ones we imagined?
- Are rows being **dropped** on somebody's fleet, which is the `ext` bug happening again?

Each of those changes what gets built next. None of them needs to know who you are.

## What sends, and what does not

| | |
|---|---|
| `bin/classify` | **sends one event per run.** It runs off the endpoint, on a collector or an analyst's machine, over a payload someone already chose to collect |
| `bin/discover` | sends nothing |
| `bin/container-scan` | sends nothing |
| `dist/*.sql`, `dist/ai-discovery.conf` | sends nothing. They are SQL; osquery executes them and they have no network to reach |

That split is deliberate and is not an oversight to correct later. `bin/discover` runs as
root on employee endpoints under MDM. An outbound call from there would be a fleet-wide
beacon on machines whose owners never chose this tool, and no analytics question is worth
that.

## Turning it off

| set this | effect |
|---|---|
| `AI_DISCOVERY_TELEMETRY=0` (or `false`, `no`, `off`) | nothing is sent |
| `CI` (any value) | nothing is sent. Set by GitHub Actions, GitLab, CircleCI and Travis |
| no ingest key compiled in | nothing is sent |

`bin/classify --telemetry-check` prints whether a run **would** send, **why not** if it
would not, and the exact event — then exits without sending and without creating anything.
The first run that does send prints one line to stderr saying so.

## What is sent

Every value below is a number, a boolean, or a word from a fixed vocabulary this file and
`bin/classify` both declare. A key whose value is unknown is omitted rather than sent as
zero, because "no timeout happened" and "a timeout of zero seconds" are different facts.

### Envelope

| field | value |
|---|---|
| `device_id` | a random `uuid4`, made on first run and kept in `~/.config/ai-discovery/install-id`. **Never** derived from hostname, MAC or username — a pseudonym computed from a machine identifier is still a machine identifier. Amplitude requires an id of some kind; this is the least it can be |
| `ip` | `"$remote"`, which asks Amplitude to take the source address of the request and geolocate it. **This is personal data under GDPR.** It is how the project can tell one organisation's usage from another's; if you would rather not send it, turn telemetry off |
| `time` | when the event was made |
| `insert_id` | a random dedupe token, so a proxy retry cannot double-count. Carries no information about you |

### Properties

Nine on a successful run, twelve on a crash. **Every one of them answers a question
somebody asked for**, and the list is deliberately short: telemetry that grows by what the
author finds interesting is how a counter turns into a profile. An earlier draft of this
carried eighteen more fields — row totals, per-kind counts, a dropped-row counter, the
payload's platform, how long the run took. Each was defensible alone; none had been asked
for; all were removed. Anything wanted later gets added on purpose, here and in
`EVENT_FIELDS`, which this page is gated against.

| field | what it is |
|---|---|
| `catalog_sha` | first 12 hex of `sha256(catalog/agents.yaml)`. Which catalog revision, without a version field anybody has to remember to bump. It means nothing until releases are hashed and mapped on the receiving side |
| `catalog_schema_version` | the catalog's own `version:` key |
| `kinds_seen` | the row kinds present, comma-joined and sorted. Anything outside the route vocabulary is reported as `other`, never forwarded verbatim |
| `deep_scan` | whether the container branch was attempted — including when it failed, because asking and being refused is still use |
| `gap_reasons` | the gap vocabulary present: `absent`, `no-cache`, `error`, `unhealthy`, `timeout`, or `other`. The reason only — not the HTTP code, not the timeout in seconds |
| `findings_agents` | how many distinct agents were matched |
| `unmatched_rows` | how many rows a route looked at and no signature claimed |
| `host_os` | the OS `bin/classify` ran on — `Darwin` or `Linux`. The name only, no release number |
| `python_version` | the interpreter running the classifier |
| `error_type` | on a crash: the exception class name |
| `error_site` | on a crash: `filename:lineno`, the basename only |
| `phase` | on a crash: `args`, `read`, `classify` or `render` |

## What is never sent

- No hostname, username, or home directory.
- No file path of any kind, including the input payload's.
- No agent identifier, no row `id`, no row `loc`, no row `perms` — nothing from the
  payload's contents. The event is counts, and a count cannot name a person.
- **No exception message.** `FileNotFoundError`'s message *is* the path it could not find,
  which on a developer machine names the user; the exception type and line number carry
  the same diagnostic value and none of that.

`test/test_telemetry.py` asserts this rather than asking you to believe it: it classifies a
fixture full of real-shaped home directories and agent identifiers, then searches what
actually left the process for every string that went in.

## Where it goes

Amplitude, US region (`api2.amplitude.com`). The ingest key is compiled into
`bin/classify` and is write-only; like every Amplitude key shipped in a web page it is
public, which means events can be **forged**. That is a reason to distrust volume in the
dashboard, not a reason to treat the key as a secret.

**A wrong key is silent.** `telemetry_send` swallows every error, so a rotated or mistyped
key looks exactly like a successful send — the same failure mode this project exists to
avoid, in the one place where being loud would cost the operator something they did not ask
for. `--telemetry-check` cannot see it either, because it deliberately makes no network
call. To check a key, authenticate without ingesting anything:

```console
$ curl -s https://api2.amplitude.com/2/httpapi -H 'Content-Type: application/json' \
    -d '{"api_key":"<key>","events":[]}'
{"code":200,...,"events_ingested":0}      # valid
{"code":400,"error":"Invalid API key: …"} # not
```

`AI_DISCOVERY_AMPLITUDE_URL` redirects the endpoint. It exists so `test/test_telemetry.py`
can point at `test/lib/fake_amplitude.py`; it is not a supported way to run a private
collector.

## If you are deploying this across an organisation

Set `AI_DISCOVERY_TELEMETRY=0` wherever `bin/classify` runs. One event per run from a
collector is small, but the decision to send it is yours to make rather than ours to
assume, and nothing about the tool's behaviour changes when it is off.
