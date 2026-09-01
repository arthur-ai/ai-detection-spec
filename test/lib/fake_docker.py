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

ONLY /images/json IS SERVED. docker_containers needs a faithful per-container inspect
document -- osquery calls /containers/<id>/json?stream=false and reads it strictly,
failing on the first missing node with "No such node (Config.Entrypoint)" and returning
zero rows while printing to stderr, which a --json caller never sees. A hand-built
inspect that osquery merely ACCEPTS is worse than none: the first attempt here produced
rows with every field empty, which would let a broken query pass. If containers are
wanted later, capture a real inspect document rather than hand-writing one.
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
    {"Id": "sha256:846795f2a2b5787ce2155170fd33b9ae886fd925f26635424ee613d53ece2fa4",
     "RepoTags": ["paulgauthier/aider:latest"],
     "Id": "sha256:cd375f1ecbd1e0ac6752bba40de5f69f3b36b75cd3d24b2c41fcca502d054ad3", "Created": 1735689600, "Size": 1390000000,
     "Labels": None, "RepoDigests": []},
    {"RepoTags": ["ghcr.io/berriai/litellm:main-latest"],
     "Created": 1788060176, "Size": 1663809740},
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


def respond(conn, state, path=""):
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
    body = json.dumps(IMAGES).encode()
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
            req = conn.recv(8192).decode(errors="replace")
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
