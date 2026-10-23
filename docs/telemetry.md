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
  `timeout`, `unreadable` — as opposed to which ones we imagined?
- Are rows being **dropped** on somebody's fleet, which is the `ext` bug happening again?

Each of those changes what gets built next. None of them needs to know who you are.

## What sends, and what does not

| | |
|---|---|
| `bin/classify` | **sends one event per run.** It runs off the endpoint, on a collector or an analyst's machine, over a payload someone already chose to collect |
| `osquery/bin/discover` | sends nothing |
| `osquery/bin/container-scan` | sends nothing |
| `osquery/dist/*.sql`, `osquery/dist/ai-discovery.conf` | sends nothing. They are SQL; osquery executes them and they have no network to reach |

That split is deliberate and is not an oversight to correct later. `osquery/bin/discover` runs as
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
| `device_id` | a random `uuid4`, made on first run and kept in `~/.config/ai-discovery/install-id`. **Never** derived from hostname, MAC or username — a pseudonym computed from a machine identifier is still a machine identifier |
| `ip` | `"$remote"`, which asks Amplitude to take the source address of the request and geolocate it. **This is personal data under GDPR.** It is how the project can tell one organisation's usage from another's; if you would rather not send it, turn telemetry off |
| `time`, `insert_id` | when the event was made, and a dedupe key |
| `os_name`, `os_version` | the same two values as `host_os` and `host_os_release` below |

### Properties

| field | what it is |
|---|---|
| `catalog_sha` | first 12 hex of `sha256(catalog/agents.yaml)`. Which catalog revision, without a version field anybody has to remember to bump. It means nothing until releases are hashed and mapped on the receiving side |
| `catalog_schema_version` | the catalog's own `version:` key |
| `catalog_agents` | how many agents the catalog carries |
| `catalog_skew` | whether the catalog is newer than this classifier understands |
| `classify_sha` | first 12 hex of `sha256` of `bin/classify` itself — a stale classifier is as interesting as a stale catalog |
| `rows_total` | rows in the payload |
| `findings_agents` | distinct agents matched |
| `findings_rows` | evidence rows across those agents |
| `unmatched_rows` | rows a route looked at and no signature claimed |
| `dropped_rows` | rows whose `kind` belongs to no route, and which the classifier therefore discards in silence. **Non-zero means a route is missing** |
| `gap_rows` | `kind=scan` markers reporting that a branch could not look |
| `absence_rows` | `kind=scan` markers reporting `absent` — the branch read the machine and there was nothing there. High here with `gap_rows` at zero is a fleet without containers, not a fleet whose container scan is failing |
| `payload_bytes` | size of the payload as read, in bytes |
| `payload_packed_bytes` | the same after gzip -9 and base64, matching `osquery/tools/measure_payload.py`. This is the figure a single-text-value channel actually pays. **The 30KB budget it is judged against is self-imposed** — a Jamf Extension Attribute convention this project keeps to, not a documented platform limit |
| `scan_rows` | `kind=scan` markers reporting a branch ran fine |
| `kinds_seen` | the row kinds present, comma-joined and sorted. Anything outside the route vocabulary is reported as `other` |
| `deep_scan` | whether the container branch was attempted — including when it failed, because asking and being refused is still use |
| `gap_reasons` | the gap vocabulary present: `absent`, `no-cache`, `error`, `unhealthy`, `timeout`, `unreadable`, or `other` |
| `gap_unhealthy_code` | the HTTP code an unhealthy daemon answered with |
| `gap_timeout_seconds` | the bound a timed-out branch gave up at |
| `stale_branches` | branches last scanned over 24h ago |
| `newest_scan_age_seconds` | age of the freshest branch in the payload |
| `host_os` | the OS **`bin/classify` ran on** |
| `host_os_release` | its major version only — `25`, not `25.6.0` |
| `payload_platform` | the platform the **payload** came from: `darwin`, `linux`, `mixed`, or `unknown`. Routinely a different machine from `host_os` |
| `python_version` | the interpreter running the classifier |
| `output_mode` | `json` or `text` |
| `show_unmatched` | whether `--show-unmatched` was passed |
| `duration_ms` | how long the run took |
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
