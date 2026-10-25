#!/usr/bin/env python3
"""A fake Docker daemon on a unix socket, for testing every state it can be in.

    fake_docker.py <socket-path> <state>

States, and why each one exists:

  healthy    answers GET /images/json with images. The only state that should produce
             container findings.
  wedge      answers /_ping with 200 and then never answers /images/json. THE STATE A
             HEALTH CHECK CANNOT SEE. Every probe in the matrix passes here -- a connect,
             a `curl -s`, and a full round trip demanding 200 -- and the query then blocks
             on the read exactly as in `hang`. It is Docker Desktop with a live API and an
             engine that is not serving, which is the ordinary condition of a Mac that is
             starting Docker. `hang` proves a health check is NECESSARY; `wedge` proves it
             is not SUFFICIENT, and it is the only state that reaches the wall-clock bound
             in bin/container-scan. Without it that bound would ship untested, because the
             guard turns every other blocking state away before osqueryi is ever started.
  nap        silent for FAKE_DOCKER_NAP_SECONDS, then serves, as if the first request had
             woken it. Docker Desktop's default: Resource Saver stops the VM after five
             idle minutes and holds the first request while it resumes -- 2.6s measured.
             IT IS `hang` UNTIL IT IS NOT, which is the point: for those seconds the two
             are the same observation and only patience separates them. At the old 1s
             budget the guard called every napping Mac hung, having woken it itself.
  hang       accepts the connection and never replies. THE IMPORTANT ONE. connect()
             succeeds in 0.000s, so a liveness probe built on connect() reports the
             daemon up, and osquery then blocks on the READ. Measured: osquery does not
             give up at all, still running past 45s. Against real Docker the same state
             costs 10.4s, because Docker's own socket layer gives up first -- the table
             has no timeout of its own, so the ceiling belongs to whatever is listening.
  error      answers 500. Observed on a real half-started Docker Desktop, where
             /v1.51/version returned 500 from this socket. It matters because `curl -s`
             exits 0 on an HTTP 500, so the obvious guard passes here and the query then
             returns zero rows -- a silent "we looked and found nothing" when we did not
             look at all.
  refuse     socket file exists with nothing listening, i.e. a stale socket. connect()
             fails at once and osquery gives up fast.

Testing against a real Docker install cannot cover these deterministically: a hosted
macOS runner has no Docker, and a developer machine is in whichever state it happens to
be in. osquery's --docker_socket flag makes the whole matrix reproducible in about a
second per state.

CONTAINERS ARE SERVED NOW, AND THE OLD NOTE HERE WAS HALF RIGHT. It said osquery "will
not accept a hand-built copy" of a per-container inspect document and advised capturing a
real one instead. The advice was right and the reason was overstated: osquery accepts a
hand-built document perfectly well, it just reads it STRICTLY and fails on the first node
it wants and cannot find -- measured on 5.23.1, "No such node (State)" and then "No such
node (HostConfig.SecurityOpt)", one at a time, each aborting the whole statement.

`SecurityOpt` is the one that makes the point: the real daemon sends it as **null**, and
osquery still requires the KEY to be present. A node can be absent-as-in-missing or
absent-as-in-null and only the second is acceptable, which is not something anyone would
guess from the error text.

SO THESE ARE CAPTURED, NOT WRITTEN, exactly as the old note advised. `docker run -d
--entrypoint sleep paulgauthier/aider:latest` against real Docker 28.4.0 on 2026-09-13,
then GET /containers/json and /containers/<id>/json?stream=false straight off the socket.
Two edits were made and both are visible below: ImageID is remapped to the aider id this
file's own IMAGES fixture carries, so the fake is self-consistent, and Config.Env is
trimmed to two entries because the real one is nine and none of them is read by anything
this repo selects.

THE HAZARD THE OLD NOTE NAMED IS REAL AND IS GUARDED BY MEASUREMENT, not by trust: a
document osquery merely ACCEPTS while returning empty fields would let a broken query
pass. So the columns these fixtures produce were diffed against the same columns read
from the live daemon, and they agree. If you edit them, re-run that comparison rather
than checking that the suite still passes.

WHY IT IS WORTH SERVING AT ALL. queries/containers.sql grew two arms past docker_images,
and both of them turn out to change how a wedged osqueryi dies -- SIGTERM stops working
entirely. Without containers here, the whole of that behaviour would be exercised only by
79-linux-image, which needs a real daemon and does not run on macOS at all.
"""
import json
import os
import socket
import sys
import time

# CAPTURED FROM A REAL DAEMON, not hand-written, and every field is a real value read off
# GET /images/json on a developer Mac with Docker 28.4.0. The docstring below explains at
# length why a hand-built inspect document is worse than none; the same argument applies to
# an image list, and this one used to be invented.
#
# Each entry is here for a naming rule bin/classify has to get right:
#
#   ghcr.io/berriai/litellm:main-latest    NOT catalogued -- a gateway an agent calls
#                                          through, removed for that. Kept as a negative
#                                          control: it must be DECLINED, and absent is
#                                          also what a dropped kind looks like. Registry host
#                                         PART of the identifier off Docker Hub, and the
#                                         published tag is main-latest, not latest.
#   ghcr.io/ggml-org/llama.cpp:server      a second one, and the org is ggml-org today
#   alpine + localbuild-probe              ONE image, TWO tags, which osquery returns as a
#                                         single row whose tags column is comma-joined:
#                                         "alpine:3.20,localbuild-probe:latest". A matcher
#                                         comparing the whole field matches neither. Also
#                                         the local-build shape, which is indistinguishable
#                                         from a Docker Hub library image.
#   authzed/spicedb:latest                 Docker Hub org form, with NO docker.io/ prefix.
#                                         Created is genuinely 0 here -- real data is not
#                                         tidy, and a fixture that tidied it would hide it.
#   public.ecr.aws/.../library/python      contains 'library/' in a path where it must NOT
#                                         be stripped, unlike Docker Hub's implicit one.
#
# None of these is an AI agent except the first two, which is the point: the other three
# must come back UNMATCHED, and a matcher that claimed them would be caught here.
IMAGES = [
    # THE aider ENTRY CARRIED "Id" TWICE and the litellm entry below carried none, so the
    # second literal silently won and litellm's `loc` came back empty on every run. Both
    # ids are real and the orphan was simply on the wrong dict: 846795f2 is litellm's,
    # confirmed against a live daemon on 2026-09-13, and it is restored to it below.
    {"Id": "sha256:cd375f1ecbd1e0ac6752bba40de5f69f3b36b75cd3d24b2c41fcca502d054ad3",
     "RepoTags": ["paulgauthier/aider:latest"],
     "Created": 1735689600, "Size": 1390000000,
     # NO LABELS, AND THAT IS THE REAL VALUE. Verified against the published image on
     # 2026-09-13: docker_image_labels returns zero rows for aider. It is the reason the
     # catalog can only reach this agent through the forgeable tag.
     "Labels": None, "RepoDigests": []},
    {"Id": "sha256:846795f2a2b5787ce2155170fd33b9ae886fd925f26635424ee613d53ece2fa4",
     "RepoTags": ["ghcr.io/berriai/litellm:main-latest"],
     "Created": 1788060176, "Size": 1663809740,
     # REAL LABELS, READ OFF THE PUBLISHED IMAGE on 2026-09-13, and they carry the whole
     # argument for matching `source` and nothing else: `title` and `vendor` here describe
     # the CHAINGUARD BASE IMAGE, not LiteLLM, because that is what base-image labels do.
     # A route keyed on either would identify this as "wolfi-base".
     #
     # LiteLLM is a gateway and deliberately NOT an agent, so this row must come back
     # UNMATCHED -- which makes it the negative control for the label route as well as the
     # image route.
     "Labels": {
         "org.opencontainers.image.source": "https://github.com/BerriAI/litellm",
         "org.opencontainers.image.title": "wolfi-base",
         "org.opencontainers.image.vendor": "Chainguard",
     }},
    {"Id": "sha256:c3728b9ba0c4c427770eec092fdb1bab1e86e811d578b27440771b8b3207f2c7",
     "RepoTags": ["ghcr.io/ggml-org/llama.cpp:server"],
     "Created": 1788151466, "Size": 1182794759},
    {"Id": "sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc",
     "RepoTags": ["alpine:3.20", "localbuild-probe:latest"],
     "Created": 1776383604, "Size": 13580309},
    {"Id": "sha256:f2ba6c78b6c5bfc465d975ef5c0b8f7f4dce57049c3c02fd1f3155be819895f7",
     "RepoTags": ["authzed/spicedb:latest"],
     "Created": 0, "Size": 26908921},
    {"Id": "sha256:2199a62885a12290dc9c5be3ca0681d367576ab7bf037da120e564723292a2f0",
     "RepoTags": ["public.ecr.aws/docker/library/python:3.12.8-slim-bookworm"],
     "Created": 1737117353, "Size": 397377540},
]


# ONE RUNNING CONTAINER, CAPTURED not written -- see the module docstring for the command
# and the two edits. It runs the aider image, which the IMAGES fixture above also carries,
# so `image` and `container` rows describe one agent and the classifier must fold them into
# a single finding rather than two.
#
# `sleep 600` as the command is the capture as it happened and is also the honest shape: a
# probe, not an agent session. queries/containers.sql puts this in `extra` precisely so a
# reader can tell the two apart.
CONTAINERS = [
    {"Id": "cb0e6dc2f3ed3998bf2cee48800b9037a518c2dcb2ebf139ef19c3b8a94249e7",
     "Names": ["/cap-probe"],
     "Image": "paulgauthier/aider:latest",
     "ImageID": "sha256:cd375f1ecbd1e0ac6752bba40de5f69f3b36b75cd3d24b2c41fcca502d054ad3",
     "Command": "sleep 600", "Created": 1789274416,
     "State": "running", "Status": "Up 15 seconds",
     "Ports": [], "Labels": {}, "Mounts": [],
     "NetworkSettings": {"Networks": {}}},
]

# THE INSPECT DOCUMENT, and every node in it is here because osquery asked for it. It reads
# this strictly and aborts the statement on the first one it cannot find, so trimming is not
# free: `HostConfig.SecurityOpt` is **null** on a real daemon and osquery still requires the
# key to exist. Absent-as-missing fails; absent-as-null is fine.
CONTAINER_INSPECT = {
    "Id": "cb0e6dc2f3ed3998bf2cee48800b9037a518c2dcb2ebf139ef19c3b8a94249e7",
    "Created": "2026-09-13T04:40:16.607267167Z",
    "Path": "sleep", "Args": ["600"],
    "Name": "/cap-probe",
    "Image": "sha256:cd375f1ecbd1e0ac6752bba40de5f69f3b36b75cd3d24b2c41fcca502d054ad3",
    "State": {"Status": "running", "Running": True, "Paused": False, "Restarting": False,
              "OOMKilled": False, "Dead": False, "Pid": 695, "ExitCode": 0, "Error": "",
              "StartedAt": "2026-09-13T04:40:16.642829167Z",
              "FinishedAt": "0001-01-01T00:00:00Z"},
    # Trimmed from nine entries to two. Nothing this repo selects reads env_variables --
    # queries/containers.sql must never emit it, because it is where an agent container
    # keeps ANTHROPIC_API_KEY -- but the column exists, so leaving the node populated keeps
    # the fixture able to prove we decline to ship it.
    "Config": {"Image": "paulgauthier/aider:latest", "Entrypoint": ["sleep"],
               "Cmd": ["600"], "Hostname": "cb0e6dc2f3ed",
               "Env": ["PATH=/venv/bin:/usr/local/bin:/usr/bin:/bin",
                       "AIDER_DOCKER_IMAGE=paulgauthier/aider"],
               "Labels": {}},
    "HostConfig": {"Privileged": False, "ReadonlyRootfs": False, "SecurityOpt": None,
                   "CgroupParent": "", "Memory": 0, "CpuShares": 0},
    "Mounts": [], "NetworkSettings": {"Networks": {}},
}


def body_for(path):
    """Which fixture a path gets. The query string is stripped FIRST, and that matters:
    osquery asks for /containers/<id>/json?stream=false, and a matcher that tested
    endswith('/json') on the raw path fell through to the images list, which osquery then
    rejected with 'No such node (State)' -- an error that names the document rather than
    the routing, and cost an afternoon.
    """
    path = path.split("?", 1)[0]
    # THE LIST IS TESTED FIRST AND THE ORDER IS LOAD-BEARING. "/containers/json" satisfies
    # the inspect pattern too -- it starts with "/containers/" and ends with "/json" -- so
    # checking inspect first hands osquery a single inspect object where it expects a list.
    # It does not error on that: it returns ONE row with the inspect-derived columns filled
    # and image, state, command and status EMPTY. A test asserting only that rows came back
    # would pass. This is the failure the module docstring calls "accepted but empty", and
    # it was caught by diffing the columns against the live daemon rather than by the suite.
    if path.startswith("/containers/json"):
        return CONTAINERS
    if path.startswith("/containers/") and path.endswith("/json"):
        return CONTAINER_INSPECT
    return IMAGES


# 3s sits between the old 1s ping budget and today's 8s, so the assertion fails if the
# default goes back and fails if it is cut below the measured wake. Overridable: one test
# wants a nap longer than the budget.
NAP_SECONDS = float(os.environ.get("FAKE_DOCKER_NAP_SECONDS", "3"))
# None until the first request triggers the resume -- idle parks the VM, a request wakes it.
WOKE_AT = None


def respond(conn, state, path=""):
    # A paused engine, resuming. Falls through to `healthy` rather than returning, because a
    # woken daemon is an ordinary one. The loop is serial, so holding here holds every later
    # request too -- which is what the real daemon does while the VM comes back.
    if state == "nap":
        global WOKE_AT
        if WOKE_AT is None:
            time.sleep(NAP_SECONDS)
            WOKE_AT = time.time()
        state = "healthy"
    # Before the hang check, because wedge IS hang for everything except /_ping.
    if state == "wedge":
        if path.startswith("/_ping"):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                         b"Content-Length: 2\r\n\r\nOK")
            return
        time.sleep(300)
        return
    if state == "hang":
        time.sleep(300)
        return
    if state == "error":
        body = b'{"message":"server error"}'
        conn.sendall(b"HTTP/1.1 500 Internal Server Error\r\n"
                     b"Content-Type: application/json\r\n"
                     b"Content-Length: %d\r\n\r\n" % len(body) + body)
        return
    # Real Docker answers /_ping with the two bytes "OK" and text/plain, not JSON. The
    # guard checks only the status code, but a fake that returned JSON here would leave a
    # stricter guard untested and quietly wrong.
    if path.startswith("/_ping"):
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                     b"Content-Length: 2\r\n\r\nOK")
        return
    # Routed by path now, rather than answering every endpoint with the image list. That
    # shortcut worked while docker_images was the only table queried and stopped working
    # the moment docker_containers joined it: osquery got images where it expected a
    # container document and aborted the WHOLE statement, taking the image rows with it.
    body = json.dumps(body_for(path)).encode()
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                 b"Content-Length: %d\r\n\r\n" % len(body) + body)


def main():
    path, state = sys.argv[1], sys.argv[2]
    if os.path.exists(path):
        os.unlink(path)

    if state == "refuse":
        # A stale socket FILE with nothing listening. A real socket object that is then
        # closed would leave no file at all, which is the 'absent' state instead.
        open(path, "w").close()
        print(f"fake-docker: {state} on {path}", flush=True)
        time.sleep(300)
        return

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(16)
    os.chmod(path, 0o666)
    print(f"fake-docker: {state} on {path}", flush=True)
    while True:
        conn, _ = srv.accept()
        try:
            # TO THE END OF THE REQUEST LINE, not one recv(): a stream may deliver it in
            # pieces, and a partial line parses as an empty path, which is served the images
            # list -- osquery's "No such node (State)" again, against a healthy fake.
            raw = b""
            while b"\r\n" not in raw and len(raw) < 8192:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                raw += chunk
            req = raw.decode(errors="replace")
            # A local name: `path` is the socket path and rebinding it here would quietly
            # take that away from anything added to this loop later.
            req_path = req.split(" ")[1] if req.count(" ") >= 2 else ""
            respond(conn, state, req_path)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()
