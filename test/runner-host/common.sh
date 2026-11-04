# Sourced by host-setup.sh, bake.sh and slot.sh: the names, paths and GitHub calls they
# share. These run on a runner HOST, a Mac that boots one fresh VM per macOS scenario job;
# never in CI and never in a guest. docs/macos-runners.md is the runbook.
#
# bash 3.2, because /bin/bash is 3.2 on every Mac and a host promises nothing newer: no
# associative arrays, and no "${a[@]}" of an empty array under `set -u`.
# shellcheck disable=SC2034  # the names below are read by the scripts that source this

ORG=arthur-ai
REPO=ai-detection-spec
API=https://api.github.com

RH_CONF="${RH_CONF:-$HOME/.config/arthur-runner}"   # app.env, app.pem, slots
RH_STATE="$HOME/.arthur-runner"                      # runner/ cache, slots/<slot>/ work
RH_LOGS="$HOME/Library/Logs/arthur-runner"
# The VM size. GitHub's hosted M1 runner is 3 CPU and 7 GB; two 7 GB guests would leave a
# 16 GB host 2 GB, so a guest gets 6.
: "${RH_CPUS:=3}" "${RH_MEM:=6144}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FAIL: $*" >&2; exit 1; }

# One image per macOS label, so the label a job asked for is the OS it boots.
image_for_label() {
  [[ "$1" =~ ^macos-([0-9]+)$ ]] || return 1
  echo "arthur-runner-${BASH_REMATCH[1]}"
}

# gh_call METHOD PATH OUT [JSON]: one REST call. The body goes to OUT and the HTTP status
# to stdout, "000" when nothing answered. The Authorization header is read from the file
# $RH_AUTH, so no token ever sits in a process's argv; an empty file calls anonymously.
gh_call() {
  local data=""
  [ $# -ge 4 ] && data="$4"
  curl -sS -m 30 -o "$3" -w '%{http_code}' -X "$1" -H @"$RH_AUTH" \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    ${data:+--data "$data"} "$API$2" 2>/dev/null || true
}

# gh_json METHOD PATH [JSON]: the body on a 2xx; otherwise the status is logged and the
# call fails.
gh_json() {
  local out code
  out=$(mktemp "$RH_TMP/gh.XXXXXX")
  code=$(gh_call "$1" "$2" "$out" "${3:-}")
  case "$code" in
    2??) cat "$out"; rm -f "$out"; return 0 ;;
  esac
  log "GitHub $1 $2 answered $code: $(head -c 300 "$out" | tr '\n' ' ')" >&2
  rm -f "$out"
  return 1
}

# app_token: an installation token for the GitHub App named in $RH_CONF/app.env, written
# into $RH_AUTH, and its time in TOKEN_AT. The JWT is signed with the openssl macOS ships,
# so a host needs no client library. The JWT lives ten minutes and the token an hour.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
app_token() {
  local now iss hdr pay sig tok
  now=$(date +%s)
  # A numeric App ID is a JSON number and a client ID is a string; GitHub takes either.
  case "$APP_ID" in
    ''|*[!0-9]*) iss="\"$APP_ID\"" ;;
    *) iss="$APP_ID" ;;
  esac
  hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  pay=$(printf '{"iat":%d,"exp":%d,"iss":%s}' $((now - 60)) $((now + 540)) "$iss" | b64url)
  sig=$(printf '%s.%s' "$hdr" "$pay" \
        | openssl dgst -sha256 -binary -sign "$RH_CONF/app.pem" | b64url) || return 1
  printf 'Authorization: Bearer %s.%s.%s\n' "$hdr" "$pay" "$sig" > "$RH_AUTH"
  tok=$(gh_json POST "/app/installations/$INSTALLATION_ID/access_tokens" | jq -r '.token // empty') \
    || return 1
  [ -n "$tok" ] || { log "the App answered with no token" >&2; return 1; }
  printf 'Authorization: Bearer %s\n' "$tok" > "$RH_AUTH"
  TOKEN_AT=$now
}

# refresh_runner_cache: the newest actions/runner release for osx-arm64 at
# $RH_STATE/runner/actions-runner.tar.gz, checked against the SHA-256 its release notes
# publish. Every guest installs from it before its job, so no job waits on a runner
# updating itself. At most once a day. KEEPS THE OLD COPY ON ANY FAILURE: a stale runner
# still serves jobs, and an empty cache serves none.
refresh_runner_cache() {
  local dir="$RH_STATE/runner" rel tag ver sha tmp
  mkdir -p "$dir"
  if [ -s "$dir/actions-runner.tar.gz" ] && [ -f "$dir/VERSION" ] \
     && [ -z "$(find "$dir/VERSION" -mtime +0 2>/dev/null)" ]; then
    return 0
  fi
  rel=$(gh_json GET /repos/actions/runner/releases/latest) || return 1
  tag=$(printf '%s' "$rel" | jq -r .tag_name)
  ver=${tag#v}
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log "WARN: unreadable runner tag '$tag'"; return 1; }
  if [ -s "$dir/actions-runner.tar.gz" ] && [ "$(cat "$dir/VERSION" 2>/dev/null)" = "$ver" ]; then
    touch "$dir/VERSION"
    return 0
  fi
  # The marker format was read off v2.338.2's release notes on 2026-11-04.
  sha=$(printf '%s' "$rel" | jq -r .body \
        | sed -n 's/.*<!-- BEGIN SHA osx-arm64 -->\([0-9a-f]\{64\}\)<!-- END SHA osx-arm64 -->.*/\1/p' \
        | head -1)
  [ -n "$sha" ] || { log "WARN: runner $ver publishes no osx-arm64 SHA-256; keeping the cache"; return 1; }
  tmp=$(mktemp "$dir/.download.XXXXXX")
  if ! curl -fsSL --retry 3 -m 900 -o "$tmp" \
       "https://github.com/actions/runner/releases/download/v$ver/actions-runner-osx-arm64-$ver.tar.gz"; then
    rm -f "$tmp"; log "WARN: runner $ver did not download; keeping the cache"; return 1
  fi
  if [ "$(shasum -a 256 "$tmp" | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$tmp"; log "WARN: runner $ver failed its SHA-256; keeping the cache"; return 1
  fi
  # mv, not cp: a guest mid-copy keeps reading the inode it opened.
  mv -f "$tmp" "$dir/actions-runner.tar.gz"
  printf '%s\n' "$ver" > "$dir/VERSION"
  log "runner cache is now $ver"
}
