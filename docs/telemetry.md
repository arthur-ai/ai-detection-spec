# Telemetry

`bin/classify` sends **one anonymous usage event per run** to Amplitude. Nothing else in this
repository sends anything.

```console
$ AI_DETECTION_SPEC_TELEMETRY=0 bin/classify      # off, per run or per shell
$ bin/classify --telemetry-check < payload        # print the exact event, send nothing
```

## Why there is any

The questions it answers, none of which needs to know who you are:

- Is anyone running a catalog months behind the current one?
- Does anyone turn on the deep container scan, and does it succeed?
- Which scan outcomes actually fire in the field, as opposed to the ones we imagined?
- Are rows being **dropped** on somebody's fleet, meaning a route is missing?

## What sends, and what does not

| | |
|---|---|
| `bin/classify` | **one event per run.** It runs off the endpoint, over a payload someone already chose to collect |
| `osquery/bin/discover`, `osquery/bin/container-scan`, everything in `osquery/dist/` | nothing |

That split is a rule, not a gap to fill later: the endpoint scripts run as root on machines
whose owners never chose this tool, and an outbound call from there would be a fleet-wide
beacon.

## Turning it off

| set this | effect |
|---|---|
| `AI_DETECTION_SPEC_TELEMETRY=0` (or `false`, `no`, `off`) | nothing is sent |
| `CI` (any value) | nothing is sent. Set by GitHub Actions, GitLab, CircleCI and Travis |
| no ingest key compiled in | nothing is sent |

`--telemetry-check` prints whether a run **would** send, **why not** if it would not, and the
exact event, then exits without sending or creating anything. The first run that does send says
so on stderr.

**Deploying across an organisation?** Set `AI_DETECTION_SPEC_TELEMETRY=0` wherever
`bin/classify` runs if you would rather not send. Nothing else about the tool changes.

## What is sent

Every value is a number, a boolean, or a word from a fixed vocabulary. A value that is unknown
is omitted rather than sent as zero.

### Envelope

| field | value |
|---|---|
| `device_id` | a random `uuid4`, made on first run and kept in `~/.config/ai-detection-spec/install-id`. **Never** derived from hostname, MAC or username |
| `ip` | `"$remote"`, which asks Amplitude to geolocate the request's source address. **This is personal data under GDPR.** It is how usage from different organisations is told apart; if you would rather not send it, turn telemetry off |
| `time`, `insert_id` | when the event was made, and a dedupe key |
| `os_name`, `os_version` | `host_os` and `host_os_release` below |

### Properties

`tools/check_doc_numbers.py` fails when this table and `bin/classify`'s `EVENT_FIELDS` differ.

| field | what it is |
|---|---|
| `catalog_sha` | first 12 hex of `sha256(catalog/agents.yaml)`, mapped to a release on the receiving side |
| `catalog_schema_version` | the authoring form's `version:` key; null for a catalog document, which states its version in `format` |
| `catalog_agents` | how many agents the catalog carries |
| `classify_sha` | first 12 hex of `sha256` of `bin/classify` itself |
| `rows_total` | rows in the payload |
| `findings_agents` | distinct agents matched |
| `findings_rows` | evidence rows across those agents |
| `unmatched_rows` | rows of a declared kind that no identifier matched |
| `dropped_rows` | rows whose `kind` no route declares. **Non-zero means a route is missing** |
| `gap_rows` | scan markers saying a source could not be read |
| `absence_rows` | scan markers reporting `absent`: the source was read and nothing was there |
| `scan_rows` | scan markers reporting `ok` |
| `payload_bytes` | the payload's size as read |
| `payload_packed_bytes` | the same after gzip -9 and base64, as `osquery/tools/measure_payload.py` computes: what a single-text-value channel pays. The 30KB budget it is judged against is this project's convention, not a platform limit |
| `kinds_seen` | the row kinds present, sorted. A kind outside the route vocabulary is `other` |
| `deep_scan` | whether the container branch was attempted, including when it failed |
| `gap_reasons` | the non-`ok` outcomes present, by their first word: `absent`, `no-cache`, `error`, `unhealthy`, `timeout`, `unreadable`, or `other`. Absences are included despite the name |
| `gap_unhealthy_code` | the HTTP code an unhealthy daemon answered with |
| `gap_timeout_seconds` | the bound a timed-out source gave up at |
| `stale_branches` | sources last read over 24 hours ago |
| `newest_scan_age_seconds` | age of the most recently read source |
| `host_os` | the OS **`bin/classify` ran on** |
| `host_os_release` | its major version only |
| `payload_platform` | the platform the **payload** came from: `darwin`, `linux`, `windows`, `mixed` or `unknown` |
| `python_version` | the interpreter running `bin/classify` |
| `output_mode` | `json` or `text` |
| `show_unmatched` | whether `--show-unmatched` was passed |
| `duration_ms` | how long the run took |
| `error_type` | on a crash: the exception class name |
| `error_site` | on a crash: `filename:lineno`, basename only |
| `phase` | on a crash: `args`, `read`, `catalog`, `classify` or `render`. `catalog` with `SystemExit` is a catalog refused, such as one whose version this `bin/classify` does not read |

## What is never sent

- No hostname, username or home directory, and no file path of any kind.
- Nothing from the payload's contents: no identifier, no row `id`, `loc` or `perms`.
- **No exception message**, because `FileNotFoundError`'s message is the path it could not find.

`test/test_telemetry.py` asserts this: it classifies a fixture full of real-shaped home
directories and agent identifiers, then searches what left the process for every string that
went in.

## Where it goes

Amplitude, US region (`api2.amplitude.com`). The ingest key is compiled into `bin/classify` and
is write-only, and like any key shipped to clients it is public, so events can be **forged**:
distrust volume, not the key.

**A wrong key is silent.** `telemetry_send` swallows every error, so a rotated or mistyped key
looks like a successful send, and `--telemetry-check` makes no network call. To check a key
without ingesting anything:

```console
$ curl -s https://api2.amplitude.com/2/httpapi -H 'Content-Type: application/json' \
    -d '{"api_key":"<key>","events":[]}'
{"code":200,...,"events_ingested":0}      # valid
{"code":400,"error":"Invalid API key: …"} # not
```

`AI_DETECTION_SPEC_AMPLITUDE_URL` redirects the endpoint so `test/test_telemetry.py` can use
`test/lib/fake_amplitude.py`. It is not a supported way to run a private collector.
